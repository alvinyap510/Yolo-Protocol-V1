pragma solidity ^0.8.28;

/*---------- IMPORT LIBRARIES ----------*/
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@BoringSolidity/RebaseLibrary.sol";
/*---------- IMPORT INTERFACES ----------*/
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@yolo/contracts/interfaces/IYoloBox.sol";
import "@yolo/contracts/interfaces/IOracle.sol";
import "@yolo/contracts/interfaces/ISwapperV2.sol";
/*---------- IMPORT BASE CONTRACTS ----------*/
import "@openzeppelin/contracts/access/Ownable.sol";
import "@BoringSolidity/interfaces/IMasterContract.sol";

contract YoloVault is Ownable, IMasterContract {
    // ***************** //
    // *** LIBRARIES *** //
    // ***************** //
    using SafeERC20 for IERC20;
    using RebaseLibrary for Rebase;

    // ***************** //
    // *** DATATYPES *** //
    // ***************** //

    struct BorrowCap {
        uint128 total;
        uint128 borrowPartPerAddress;
    }

    struct AccrueInfo {
        uint64 lastAccrued; // Timestamp of the last time interest was accrued
        uint128 feesEarned; // Total fees accumulated from interest and borrow fees
        uint64 INTEREST_PER_SECOND; // Interest rate per second (in a fixed-point format)
    }

    struct CookStatus {
        bool needsSolvencyCheck;
        bool hasAccrued;
    }

    // ******************************** //
    // *** CONSTANTS AND IMMUTABLES *** //
    // ******************************** //

    // CONSTANTS
    uint256 internal constant EXCHANGE_RATE_PRECISION = 1e18; // The precision of the exchange rate

    uint256 internal constant COLLATERIZATION_RATE_PRECISION = 1e5; // Must be less than EXCHANGE_RATE_PRECISION (due to optimization in math)

    uint256 internal constant BORROW_OPENING_FEE_PRECISION = 1e5; // Precision of the borrow opening fee

    uint256 internal constant LIQUIDATION_MULTIPLIER_PRECISION = 1e5; // Precision of the borrow opening fee

    uint256 internal constant DISTRIBUTION_PART = 10; // The part of the liquidation bonus that is distributed to sSpell holders

    uint256 internal constant DISTRIBUTION_PRECISION = 100; // The precision of the distribution

    // IMMUTABLES
    IYoloBox public immutable yoloBox;

    YoloVault public immutable masterContract;

    IERC20 public immutable yoloUsd;

    // ***************************//
    // *** CONTRACT VARIABLES *** //
    // ************************** //

    /*---------- MASTER CONTRACT VARIABLES ----------*/

    mapping(address => bool) public blacklistedCallees; // Disallow calling to blacklisted calless

    /*---------- CLONE CONTRACT VARIABLES ----------*/

    address public feeTo; // The address that receives fees accrued in this vault

    uint256 public COLLATERIZATION_RATE; // The loan-to-value ratio of the collateral

    uint256 public LIQUIDATION_MULTIPLIER; // Determines the liquidation penalty of the vault

    uint256 public BORROW_OPENING_FEE; // The fee charged when opening a new borrow

    IERC20 public collateral; // The collateral accepted by the vault

    IOracle public oracle; // Oracle of the collateral

    bytes public oracleData; // Data used to fetch the exchange rate of the collateral

    BorrowCap public borrowLimit; // The borrow limit of the vault

    AccrueInfo public accrueInfo; // Tracks accrue information and interests over time

    uint256 public exchangeRate; // Cached exchangeRate of the collateral / YoloUSD

    uint256 public totalCollateralShare; // Total collateral supplied

    Rebase public totalBorrow; // elastic = Total token amount to be repayed by borrowers, base = Total parts of the debt held by borrowers

    mapping(address => uint256) public userCollateralShare; // Keep track of user's collateral share

    mapping(address => uint256) public userBorrowPart; // Keep track of user's borrow

    // ************** //
    // *** EVENTS *** //
    // ************** //

    event LogAccrue(uint128 accruedAmount); // Log when interest is accrued

    event LogExchangeRate(uint256 rate); // Log when exchange rate is updated

    event LogAddCollateral(address indexed from, address indexed receiver, uint256 share); // Log when collateral is added

    event LogRemoveCollateral(address indexed from, address indexed receiver, uint256 share); // Log when collateral is removed

    event LogBorrow(address indexed from, address indexed receiver, uint256 amount, uint256 part); // Log when a user borrows

    event LogRepay(address indexed from, address indexed to, uint256 amount, uint256 part); // Log when debt was repaid

    event LogLiquidation(
        address indexed from,
        address indexed user,
        address indexed to,
        uint256 collateralShare,
        uint256 borrowAmount,
        uint256 borrowPart
    ); // Log when a liquidation occurs

    event LogInterestChange(uint64 oldInterestRate, uint64 newInterestRate); // Log when interest rate changes

    event LogChangeBorrowLimit(uint128 newLimit, uint128 perAddressPart); // Log when borrow limit changes

    event LogChangeBlacklistedCallee(address indexed account, bool blacklisted); // Log when a blacklisted callee changes

    event LogLiquidationMultiplierChanged(uint256 previous, uint256 current); // Log when liquidation multiplier changes

    event LogBorrowOpeningFeeChanged(uint256 previous, uint256 current); // Log when borrow opening fee changes

    event LogCollateralizationRateChanged(uint256 previous, uint256 current); // Log when collateralization rate changes

    event LogFeeTo(address indexed newFeeTo); // Log when feeTo address changes

    event LogWithdrawFees(address indexed feeTo, uint256 feesEarnedFraction); // Log when fees are withdrawn

    // ************** //
    // *** ERRORS *** //
    // ************** //
    error ErrorNotMasterContractOwner(); // Error when trying to call a function on the master contract

    error ErrorNotClone(); // Error when trying to call a function on the master contract

    error ErrorUserInsolvent(); // Error when the user is insolvent

    error ErrorBorrowLimitReacehed(); // Error when the borrow limit is reached

    error ErrorParamsLengthMismatch(); // Error when the length of the params are not equal

    error ErrorVaultAlreadyInitialized(); // Error when trying to initialize the vault more than once

    error ErrorWrongInitParams(); // Error when the init params are wrong

    error ErrorSkimTooMuch(); // Error when trying to skim more than the user has

    error ErrorCannotBlacklistCallee(); // Error when trying to blacklist YoloBox or this contract

    error ErrorNoLiquidationHappened(); // Error when no liquidation happened in liquidate()

    error ErrorCookRate(); // Error when the rate is not updated as expected in cook()

    error ErrorBlacklistedCallee(); // Error when trying to call a blacklisted callee

    error ErrorExternalCallFailed(); // Error when an external call fails

    // ******************** //
    // *** COOK ACTIONS *** //
    // ******************** //

    // Functions that need accrue to be called
    uint8 internal constant ACTION_REPAY = 2;
    uint8 internal constant ACTION_REMOVE_COLLATERAL = 4;
    uint8 internal constant ACTION_BORROW = 5;
    uint8 internal constant ACTION_GET_REPAY_SHARE = 6;
    uint8 internal constant ACTION_GET_REPAY_PART = 7;
    uint8 internal constant ACTION_ACCRUE = 8;

    // Functions that don't need accrue to be called
    uint8 internal constant ACTION_ADD_COLLATERAL = 10;
    uint8 internal constant ACTION_UPDATE_EXCHANGE_RATE = 11;

    // Function on BentoBox
    uint8 internal constant ACTION_BENTO_DEPOSIT = 20;
    uint8 internal constant ACTION_BENTO_WITHDRAW = 21;
    uint8 internal constant ACTION_BENTO_TRANSFER = 22;
    uint8 internal constant ACTION_BENTO_TRANSFER_MULTIPLE = 23;
    uint8 internal constant ACTION_BENTO_SETAPPROVAL = 24;

    // Any external call (except to BentoBox)
    uint8 internal constant ACTION_CALL = 30;
    uint8 internal constant ACTION_LIQUIDATE = 31;

    // Custom cook actions
    uint8 internal constant ACTION_CUSTOM_START_INDEX = 100;

    int256 internal constant USE_VALUE1 = -1;
    int256 internal constant USE_VALUE2 = -2;

    // ***************** //
    // *** MODIFIERS *** //
    // ***************** //

    /**
     *  @notice Modifier to make functions only callable by master contract's owner
     */
    modifier onlyMasterContractOwner() {
        if (msg.sender != masterContract.owner()) revert ErrorNotMasterContractOwner();
        _;
    }

    /**
     *  @notice Modifier to make functions only callable on clone contracts.
     */
    modifier onlyClones() {
        if (address(this) == address(masterContract)) {
            revert ErrorNotClone();
        }
        _;
    }

    /**
     *  @notice Modifier to make functions only callable by solvent users.
     */
    modifier solvent() {
        _;
        (, uint256 _exchangeRate) = updateExchangeRate();
        if (!_isSolvent(msg.sender, _exchangeRate)) revert ErrorUserInsolvent();
    }

    // ******************* //
    // *** CONSTRUCTOR *** //
    // ******************* //

    /**
     *  @notice  Only used for the initialization of the master contract. Subsequent
     *           clones will be initialized through the `init()` function.
     *  @param   _yoloBox    The address of the YoloBox contract.
     *  @param   _yoloUsd    The address of the YoloUSD token.
     *  @param   _owner      The address of the owner of the contract.
     */
    constructor(IYoloBox _yoloBox, IERC20 _yoloUsd, address _owner) {
        yoloBox = _yoloBox;
        yoloUsd = _yoloUsd;
        masterContract = this;

        _transferOwnership(_owner);

        blacklistedCallees[address(yoloBox)] = true;
        blacklistedCallees[address(this)] = true;
        blacklistedCallees[_owner] = true;
    }

    /**
     *  @notice     Serves as the actual constructor for clones.
     *  @param      _data    The data needed to initialize the clone.
     *  @dev        Can only be called on clone contracts.
     *              The data is abi encoded in the format: (IERC20 collateral, IOracle oracle, bytes oracleData, uint64 interestPerSecond, uint256 liquidationMultiplier, uint256 collaterizationRate, uint256 borrowOpeningFee)
     */
    function init(bytes calldata _data) public payable virtual override onlyClones {
        // Guard clause: Prevent reinitialization
        if (address(collateral) != address(0)) revert ErrorVaultAlreadyInitialized();

        // Decode the data
        (
            collateral,
            oracle,
            oracleData,
            accrueInfo.INTEREST_PER_SECOND,
            LIQUIDATION_MULTIPLIER,
            COLLATERIZATION_RATE,
            BORROW_OPENING_FEE
        ) = abi.decode(_data, (IERC20, IOracle, bytes, uint64, uint256, uint256, uint256));

        // Guard clause: Ensure the collateral is not the zero address
        if (address(collateral) == address(0)) revert ErrorWrongInitParams();

        // Set the borrow limit
        borrowLimit = BorrowCap(type(uint128).max, type(uint128).max);

        // Approve YoloBox to spend YoloUSD
        yoloUsd.approve(address(yoloBox), type(uint256).max);

        // Setup blacklisted callee
        blacklistedCallees[address(yoloBox)] = true;
        blacklistedCallees[address(this)] = true;
        blacklistedCallees[owner()] = true;

        // Fetch the exchange rate of collateral / YoloUSD
        (, exchangeRate) = oracle.get(oracleData);

        // Set the last accrued time to the current block timestamp
        accrue();
    }

    // ************************ //
    // *** PUBLIC FUNCTIONS *** //
    // ************************ //

    /**
     *  @notice     Accrues the interest on the borrowed tokens and handles the accumulation of fees.
     *  @dev        Callable by anyone.
     */
    function accrue() public {
        // Retrive the accrue information
        AccrueInfo memory _accrueInfo = accrueInfo;

        // Calculate seconds passed since accrue was called
        uint256 elapsedTime = block.timestamp - _accrueInfo.lastAccrued;
        if (elapsedTime == 0) {
            return;
        }

        // Update the last accrued timestamp
        _accrueInfo.lastAccrued = uint64(block.timestamp);

        Rebase memory _totalBorrow = totalBorrow;
        if (_totalBorrow.base == 0) {
            accrueInfo = _accrueInfo;
            return;
        }

        // Accrue interest
        uint128 extraAmount =
            uint128(uint256(_totalBorrow.elastic) * _accrueInfo.INTEREST_PER_SECOND * elapsedTime / 1e18);
        _totalBorrow.elastic = _totalBorrow.elastic + extraAmount;

        _accrueInfo.feesEarned = _accrueInfo.feesEarned + extraAmount;
        totalBorrow = _totalBorrow;
        accrueInfo = _accrueInfo;

        emit LogAccrue(extraAmount);
    }

    /**
     *  @notice     Fetch the exchange rate of the collateral / YoloUSD.
     *  @dev        Invokable by anyone when needed.
     *  @return     _isUpdated  Boolean to be true if the exchange rate was updated.
     *  @return     _rate       The exchange rate.
     */
    function updateExchangeRate() public returns (bool _isUpdated, uint256 _rate) {
        (_isUpdated, _rate) = oracle.get(oracleData);

        if (_isUpdated) {
            exchangeRate = _rate;
            emit LogExchangeRate(_rate);
        } else {
            // Return the old rate if fetching wasn't successful
            _rate = exchangeRate;
        }
    }

    /**
     *  @notice     Withdraw the fees accumulated to feeTo address.
     *  @dev        Invokable by anyone when needed.
     */
    function withdrawFees() public {
        accrue();
        address _feeTo = feeTo;
        uint256 _feesEarned = accrueInfo.feesEarned;
        uint256 share = yoloBox.toShare(yoloUsd, _feesEarned, false);
        yoloBox.transfer(yoloUsd, address(this), _feeTo, share);
        accrueInfo.feesEarned = 0;

        emit LogWithdrawFees(_feeTo, _feesEarned);
    }

    /**
     *  @notice     Adds `collateral` from msg.sender to to the `_receiver`.
     *  @param      _receiver   The receiver of the tokens.
     *  @param      _skim       True if the amount should be skimmed from the deposit balance of msg.sender.
     *                          False if tokens from msg.sender in YoloBox should be transferred.
     *  @param      _share      The amount in shares to assign to the vault.
     */
    function addCollateral(address _receiver, bool _skim, uint256 _share) public virtual {
        userCollateralShare[_receiver] = userCollateralShare[_receiver] + _share;
        uint256 oldTotalCollateralShare = totalCollateralShare;
        totalCollateralShare = oldTotalCollateralShare + _share;
        _addTokens(collateral, _share, oldTotalCollateralShare, _skim);
        _afterAddCollateral(_receiver, _share);
        emit LogAddCollateral(_skim ? address(yoloBox) : msg.sender, _receiver, _share);
    }

    /**
     *  @notice     Removes `_share` amount of collateral and transfers it to `_receiver`.
     *  @dev        Only callable if user is solvent after the function call, else it will revert.
     *  @param      _receiver   The receiver of the tokens.
     *  @param      _share      The amount in shares to the withdrawn.
     */
    function removeCollateral(address _receiver, uint256 _share) public solvent {
        // accrue must be called because we check solvency
        accrue();
        _removeCollateral(_receiver, _share);
    }

    /**
     *  @notice     Sender borrows / mint `_amount` of YoloUSD and transfers it to `_receiver`.
     *  @dev        Only callable if user is solvent after the function call, else it will revert.
     *  @param      _receiver   The receiver of the YoloUSD.
     *  @param      _amount     The amount of YoloUSD to borrow.
     */
    function borrow(address _receiver, uint256 _amount) public solvent returns (uint256 _part, uint256 _share) {
        accrue();
        (_part, _share) = _borrow(_receiver, _amount);
    }

    /**
     *  @notice     Repays a portion of the caller’s borrowed YoloUSD debt.
     *  @param      _receiver   The address whose debt is being repaid.
     *  @param      _skim       True if the repayment is skimmed from the sender’s YoloBox balance, false if transferred.
     *  @param      _part       The portion of the debt to repay, tracked in `userBorrowPart`.
     *  @return     _amount     The amount of YoloUSD repaid.
     *  @dev        Public function callable by users. Ensures solvency post-repayment via `solvent` modifier.
     *              Calls `accrue` to update interest before repayment.
     */
    function repay(address _receiver, bool _skim, uint256 _part) public returns (uint256 _amount) {
        accrue();
        _amount = _repay(_receiver, _skim, _part);
    }

    function liquidate(
        address[] memory _users,
        uint256[] memory _maxBorrowParts,
        address _receiver,
        ISwapperV2 _swapper,
        bytes memory _swapperData
    ) public virtual {
        // Guard clause: Avoid params mismatch
        if (_users.length != _maxBorrowParts.length) revert ErrorParamsLengthMismatch();

        // Update the exchange rate to latest
        (, uint256 _exchangeRate) = updateExchangeRate();

        // Accrue interest
        accrue();

        uint256 allCollateralShare;
        uint256 allBorrowAmount;
        uint256 allBorrowPart;

        // Retrieve the rebase totals for the collateral from YoloBox
        Rebase memory yoloBoxTotals = yoloBox.totals(collateral);

        // Hook: Before multiple users getting liquidated
        _beforeUsersLiquidated(_users, _maxBorrowParts);

        // Iterate over the each users
        for (uint256 i = 0; i < _users.length; i++) {
            address user = _users[i];
            // Check if the user is solvent
            if (!_isSolvent(user, _exchangeRate)) {
                // Determine borrow amount to liquidate (in parts)
                // Compare user debt part and the liquidation part that liquidator want to liquidate, and take the
                // smaller amount to avoid over-liquidation
                uint256 borrowPart;
                uint256 availableBorrowPart = userBorrowPart[user];
                borrowPart = _maxBorrowParts[i] > availableBorrowPart ? availableBorrowPart : _maxBorrowParts[i];

                // Calculate debts parts to collateral amount
                uint256 borrowAmount = totalBorrow.toElastic(borrowPart, false);

                // Calculate how much collateral the liquidator will seize
                uint256 collateralShare = yoloBoxTotals.toBase(
                    borrowAmount * LIQUIDATION_MULTIPLIER * _exchangeRate
                        / (LIQUIDATION_MULTIPLIER_PRECISION * EXCHANGE_RATE_PRECISION),
                    false
                );

                // Hook: Before single user getting liquidated
                _beforeUserLiquidated(user, borrowPart, borrowAmount, collateralShare);

                // Reduce user part by the amount being liquidated
                userBorrowPart[user] = availableBorrowPart - borrowPart;

                // Reduce the calculated collateral share being seized from the user's amount
                userCollateralShare[user] = userCollateralShare[user] - collateralShare;

                // Hook: After single user getting liquidated
                _afterUserLiquidated(user, collateralShare);

                emit LogRemoveCollateral(user, _receiver, collateralShare);
                emit LogRepay(msg.sender, user, borrowAmount, borrowPart);
                emit LogLiquidation(msg.sender, user, _receiver, collateralShare, borrowAmount, borrowPart);

                // Keep totals
                allCollateralShare = allCollateralShare + collateralShare;
                allBorrowAmount = allBorrowAmount + borrowAmount;
                allBorrowPart = allBorrowPart + borrowPart;
            }
        }

        // Make sure that's atleast one liquidation happen
        if (allBorrowAmount == 0) revert ErrorNoLiquidationHappened();

        // Global state update
        // Decreate the total borrow amout by liquidated amount
        totalBorrow.elastic = totalBorrow.elastic - uint128(allBorrowAmount);
        // Decreate the total borrow part by liquidated parts
        totalBorrow.base = totalBorrow.base - uint128(allBorrowPart);
        // Decrease the total collateral share by liquidated collateral share
        totalCollateralShare = totalCollateralShare - allCollateralShare;

        // Distribute part of the liquidation fee to sSpell holders
        {
            // Calculate asset seized
            uint256 seizedAssetAmount = allBorrowAmount * LIQUIDATION_MULTIPLIER / LIQUIDATION_MULTIPLIER_PRECISION;
            // Calculate the bonus / penalty part
            uint256 liquidationBonusAmount = seizedAssetAmount - allBorrowAmount;
            // Calculate the distribution amount that will be earned by the protocol / sSpell stakers
            uint256 distributionAmount = liquidationBonusAmount * DISTRIBUTION_PART / DISTRIBUTION_PRECISION;
            // Update the amount that liquidator should repay
            allBorrowAmount = allBorrowAmount + distributionAmount;
            // Add the distribution amount to the fees earned
            accrueInfo.feesEarned = accrueInfo.feesEarned + uint128(distributionAmount);
        }
        // Convert borrow amount to share
        uint256 allBorrowShare = yoloBox.toShare(yoloUsd, allBorrowAmount, true);

        // Swap using a swapper freely chosen by the caller
        // Open (flash) liquidation: get proceeds first and provide the borrow after
        // Transfer the collateral to the liquidator
        yoloBox.transfer(collateral, address(this), _receiver, allCollateralShare);
        // If the swapper is set, swap the collateral for the borrow
        if (_swapper != ISwapperV2(address(0))) {
            _swapper.swap(
                address(collateral), address(yoloUsd), msg.sender, allBorrowShare, allCollateralShare, _swapperData
            );
        }

        // Ensures accuracy in case anything changed between the first calculation and now
        // It protects against potential manipulation of the share/amount ratio during the transaction

        allBorrowShare = yoloBox.toShare(yoloUsd, allBorrowAmount, true);

        // Transfer the YoloUSD from Liquidator to Protocol
        yoloBox.transfer(yoloUsd, msg.sender, address(this), allBorrowShare);
    }

    // ********************* //
    // *** CONFIGURATION *** //
    // ********************* //

    /**
     *  @notice     Updates the interest rate charged per second on borrowed amounts.
     *  @param      _newInterestRate   The new interest rate per second (in fixed-point format).
     *  @dev        Can only be called by the master contract owner. Accrues interest before updating.
     */
    function changeInterestRate(uint64 _newInterestRate) public onlyMasterContractOwner {
        accrue(); // Ensure interest is up-to-date before changing the rate
        emit LogInterestChange(accrueInfo.INTEREST_PER_SECOND, _newInterestRate);
        accrueInfo.INTEREST_PER_SECOND = _newInterestRate;
    }

    /**
     *  @notice     Modifies the borrowing limits for the vault, both total and per address.
     *  @param      _newBorrowLimit     The new total borrow limit
     *  @param      _perAddressPart     The new per-address borrow limit (in parts).
     *  @dev        Can only be called by the master contract owner.
     */
    function changeBorrowLimit(uint128 _newBorrowLimit, uint128 _perAddressPart) public onlyMasterContractOwner {
        borrowLimit = BorrowCap(_newBorrowLimit, _perAddressPart);
        emit LogChangeBorrowLimit(_newBorrowLimit, _perAddressPart);
    }

    /**
     *  @notice     Sets or unsets an address as a blacklisted callee for external calls.
     *  @param      _callee        The address to blacklist or unblacklist.
     *  @param      _blacklisted   True to blacklist, false to unblacklist.
     *  @dev        Can only be called by the master contract owner. Prevents blacklisting YoloBox or this contract.
     */
    function setBlacklistedCallee(address _callee, bool _blacklisted) public onlyMasterContractOwner {
        if (_callee == address(yoloBox) || _callee == address(this)) revert ErrorCannotBlacklistCallee();
        blacklistedCallees[_callee] = _blacklisted;
        emit LogChangeBlacklistedCallee(_callee, _blacklisted);
    }

    /**
     *  @notice     Updates the liquidation multiplier, which determines the penalty during liquidations.
     *  @param      _liquidationMultiplier   The new liquidation multiplier value.
     *  @dev        Can only be called by the master contract owner. To convert from bips: liquidationFeeBips * 1e1 + 1e5.
     */
    function setLiquidationMultiplier(uint256 _liquidationMultiplier) public onlyMasterContractOwner {
        emit LogLiquidationMultiplierChanged(LIQUIDATION_MULTIPLIER, _liquidationMultiplier);
        LIQUIDATION_MULTIPLIER = _liquidationMultiplier;
    }

    /**
     *  @notice     Updates the fee charged when opening a new borrow position.
     *  @param      _borrowOpeningFee   The new borrow opening fee value.
     *  @dev        Can only be called by the master contract owner. To convert from bips: borrowOpeningFeeBips * 1e1.
     */
    function setBorrowOpeningFee(uint256 _borrowOpeningFee) public onlyMasterContractOwner {
        emit LogBorrowOpeningFeeChanged(BORROW_OPENING_FEE, _borrowOpeningFee);
        BORROW_OPENING_FEE = _borrowOpeningFee;
    }

    /**
     *  @notice     Updates the collateralization rate (loan-to-value ratio) for the vault.
     *  @param      _collateralizationRate   The new collateralization rate value.
     *  @dev        Can only be called by the master contract owner. To convert from bips: collateralizationRateBips * 1e1.
     */
    function setCollateralizationRate(uint256 _collateralizationRate) public onlyMasterContractOwner {
        emit LogCollateralizationRateChanged(COLLATERIZATION_RATE, _collateralizationRate);
        COLLATERIZATION_RATE = _collateralizationRate;
    }

    /**
     *  @notice     Updates the feeTo address that will receive the fees.
     *  @param      _newFeeTo   The new address that will receive the fees accrued in this vault.
     */
    function setFeeTo(address _newFeeTo) public onlyMasterContractOwner {
        feeTo = _newFeeTo;
        emit LogFeeTo(feeTo);
    }

    /**
     *  @notice     Reduces the supply of YoloUSD by withdrawing it from the vault.
     *  @param      _amount     The amount of YoloUSD to withdraw and reduce from the supply.
     *  @dev        Can only be called by the master contract owner. Withdraws up to the available
     *              YoloUSD balance in the YoloBox, transferring it to the caller (master contract
     *              owner itself).
     */
    function reduceSupply(uint256 _amount) public onlyMasterContractOwner {
        uint256 maxAmount = yoloBox.toAmount(yoloUsd, yoloBox.balanceOf(yoloUsd, address(this)), false);
        _amount = maxAmount > _amount ? _amount : maxAmount;
        yoloBox.withdraw(yoloUsd, address(this), msg.sender, _amount, 0);
    }

    /**
     *  @notice     Executes a sequence of actions, enabling composable contract calls to external contracts.
     *  @param      _actions    Array of action codes to execute (refer to `ACTIONS` declaration).
     *  @param      _values     Array of ETH amounts to send with actions, mapped one-to-one with `_actions`.
     *                          Only applies to ACTION_CALL and ACTION_BENTO_DEPOSIT.
     *  @param      _datas      Array of ABI-encoded data for each action, mapped one-to-one with `_actions`.
     *  @return     _value1     First return value from the last executed action (if applicable).
     *  @return     _value2     Second return value from the last executed action (if it returns two values).
     *  @dev        Callable by anyone, payable for ETH deposits. Automatically accrues interest for actions < 10.
     *              Checks solvency after actions requiring it (e.g., borrow, remove collateral). Uses `_num` for flexible parameter substitution.
     */
    function cook(uint8[] calldata _actions, uint256[] calldata _values, bytes[] calldata _datas)
        external
        payable
        returns (uint256 _value1, uint256 _value2)
    {
        // A struct that tracks whether the user's solvency needs to be checked and if interest has been accrued
        CookStatus memory status;

        for (uint256 i = 0; i < _actions.length; i++) {
            uint8 action = _actions[i];
            // For actions below 10, accrue interest if it hasn't been done yet
            if (!status.hasAccrued && action < 10) {
                accrue();
                status.hasAccrued = true;
            }
            // Execute actions
            if (action == ACTION_ADD_COLLATERAL) {
                (int256 share, address to, bool skim) = abi.decode(_datas[i], (int256, address, bool));
                addCollateral(to, skim, _num(share, _value1, _value2));
            } else if (action == ACTION_REPAY) {
                (int256 part, address to, bool skim) = abi.decode(_datas[i], (int256, address, bool));
                _repay(to, skim, _num(part, _value1, _value2));
            } else if (action == ACTION_REMOVE_COLLATERAL) {
                (int256 share, address to) = abi.decode(_datas[i], (int256, address));
                _removeCollateral(to, _num(share, _value1, _value2));
                status.needsSolvencyCheck = true;
            } else if (action == ACTION_BORROW) {
                (int256 amount, address to) = abi.decode(_datas[i], (int256, address));
                (_value1, _value2) = _borrow(to, _num(amount, _value1, _value2));
                status.needsSolvencyCheck = true;
            } else if (action == ACTION_UPDATE_EXCHANGE_RATE) {
                (bool must_update, uint256 minRate, uint256 maxRate) = abi.decode(_datas[i], (bool, uint256, uint256));
                (bool updated, uint256 rate) = updateExchangeRate();
                // if must_update is true, the rate must be updated
                // if minRate is non-zero, the rate must be greater than minRate
                // if maxRate is non-zero, the rate must be less than maxRate
                if (must_update && !updated) revert ErrorCookRate();
                if (rate <= minRate) revert ErrorCookRate();
                if (maxRate != 0 && rate >= maxRate) revert ErrorCookRate();
            } else if (action == ACTION_BENTO_SETAPPROVAL) {
                (address user, address _masterContract, bool approved, uint8 v, bytes32 r, bytes32 s) =
                    abi.decode(_datas[i], (address, address, bool, uint8, bytes32, bytes32));
                yoloBox.setMasterContractApproval(user, _masterContract, approved, v, r, s);
            } else if (action == ACTION_BENTO_DEPOSIT) {
                (_value1, _value2) = _bentoDeposit(_datas[i], _values[i], _value1, _value2);
            } else if (action == ACTION_BENTO_WITHDRAW) {
                (_value1, _value2) = _bentoWithdraw(_datas[i], _value1, _value2);
            } else if (action == ACTION_BENTO_TRANSFER) {
                (IERC20 token, address to, int256 share) = abi.decode(_datas[i], (IERC20, address, int256));
                yoloBox.transfer(token, msg.sender, to, _num(share, _value1, _value2));
            } else if (action == ACTION_BENTO_TRANSFER_MULTIPLE) {
                (IERC20 token, address[] memory tos, uint256[] memory shares) =
                    abi.decode(_datas[i], (IERC20, address[], uint256[]));
                yoloBox.transferMultiple(token, msg.sender, tos, shares);
            } else if (action == ACTION_CALL) {
                (bytes memory returnData, uint8 returnValues) = _call(_values[i], _datas[i], _value1, _value2);

                if (returnValues == 1) {
                    (_value1) = abi.decode(returnData, (uint256));
                } else if (returnValues == 2) {
                    (_value1, _value2) = abi.decode(returnData, (uint256, uint256));
                }
            } else if (action == ACTION_GET_REPAY_SHARE) {
                int256 part = abi.decode(_datas[i], (int256));
                _value1 = yoloBox.toShare(yoloUsd, totalBorrow.toElastic(_num(part, _value1, _value2), true), true);
            } else if (action == ACTION_GET_REPAY_PART) {
                int256 amount = abi.decode(_datas[i], (int256));
                _value1 = totalBorrow.toBase(_num(amount, _value1, _value2), false);
            } else if (action == ACTION_LIQUIDATE) {
                _cookActionLiquidate(_datas[i]);
            } else {
                (bytes memory returnData, uint8 returnValues, CookStatus memory returnStatus) =
                    _additionalCookAction(action, status, _values[i], _datas[i], _value1, _value2);
                status = returnStatus;

                if (returnValues == 1) {
                    (_value1) = abi.decode(returnData, (uint256));
                } else if (returnValues == 2) {
                    (_value1, _value2) = abi.decode(returnData, (uint256, uint256));
                }
            }
        }

        if (status.needsSolvencyCheck) {
            (, uint256 _exchangeRate) = updateExchangeRate();
            require(_isSolvent(msg.sender, _exchangeRate), "Cauldron: user insolvent");
        }
    }

    // ***************************** //
    // *** PUBLIC VIEW FUNCTIONS *** //
    // ***************************** //

    /**
     *  @notice  Checks if a user's position is solvent based on their borrow and collateral values, using the cached exchange rate.
     *  @param   _user          The address of the user whose solvency is being checked.
     *  @return  bool           Returns true if the user is solvent, false otherwise.
     */
    function isSolvent(address _user) public view returns (bool) {
        return _isSolvent(_user, exchangeRate);
    }

    // ************************** //
    // *** INTERNAL FUNCTIONS *** //
    // ************************** //

    /**
     *  @notice  Helper functin that has dual usage:
     *           1. Transfer user's tokens in YoloBox to the vault.
     *           2. Checks if the requested share amount can be "skimmed" from the vault.
     *  @param   _token     The ERC-20 token.
     *  @param   _share     The amount in shares to assign to the vault.
     *  @param   _total     Grand total amount to deduct from this contract's balance. Only applicable if `skim` is True.
     *  @param   _skim      Boolean - whether to skim or not. If true, only does a balance check on this contract.
     *                      False if tokens from msg.sender in YoloBox should be transferred.
     */
    function _addTokens(IERC20 _token, uint256 _share, uint256 _total, bool _skim) internal {
        if (_skim) {
            if (_share > yoloBox.balanceOf(_token, address(this)) - _total) revert ErrorSkimTooMuch();
        } else {
            yoloBox.transfer(_token, msg.sender, address(this), _share);
        }
    }

    /**
     *  @notice     Removes a specified amount of collateral from the caller's balance and transfers it to a receiver.
     *  @param      _receiver   The address that will receive the withdrawn collateral shares.
     *  @param      _share      The amount of collateral shares to remove and transfer.
     *  @dev        Internal function called by `removeCollateral`. Assumes solvency is checked prior via the `solvent` modifier.
     *              Updates user and total collateral shares, triggers a hook, emits an event, and transfers shares via YoloBox.
     */
    function _removeCollateral(address _receiver, uint256 _share) internal virtual {
        userCollateralShare[msg.sender] = userCollateralShare[msg.sender] - _share;
        totalCollateralShare = totalCollateralShare - _share;
        _afterRemoveCollateral(msg.sender, _receiver, _share);
        emit LogRemoveCollateral(msg.sender, _receiver, _share);
        yoloBox.transfer(collateral, address(this), _receiver, _share);
    }

    /**
     *  @notice     Handles the borrowing of YoloUSD by adding debt and transferring tokens to a receiver.
     *  @param      _receiver   The address that will receive the borrowed YoloUSD.
     *  @param      _amount     The amount of YoloUSD to borrow.
     *  @return     _part       The portion of the total debt assigned to the borrower.
     *  @return     _share      The amount of YoloUSD shares transferred.
     *  @dev        Internal function called by `borrow`. Assumes `accrue` is called prior. Calculates borrow fee,
     *              updates debt tracking, enforces borrow limits, and mints/transfers YoloUSD via YoloBox.
     */
    function _borrow(address _receiver, uint256 _amount) internal returns (uint256 _part, uint256 _share) {
        uint256 feeAmount = _amount * BORROW_OPENING_FEE / BORROW_OPENING_FEE_PRECISION; // A flat % fee is charged for any borrow
        (totalBorrow, _part) = totalBorrow.add(_amount + feeAmount, true);

        BorrowCap memory cap = borrowLimit;

        if (totalBorrow.elastic > cap.total) revert ErrorBorrowLimitReacehed();

        accrueInfo.feesEarned = accrueInfo.feesEarned + uint128(feeAmount);

        uint256 newBorrowPart = userBorrowPart[msg.sender] + _part;
        if (newBorrowPart > cap.borrowPartPerAddress) revert ErrorBorrowLimitReacehed();

        _preBorrowAction(_receiver, _amount, newBorrowPart, _part);

        userBorrowPart[msg.sender] = newBorrowPart;

        // As long as there are tokens on this contract you can 'mint'... this enables limiting borrows
        _share = yoloBox.toShare(yoloUsd, _amount, false);
        yoloBox.transfer(yoloUsd, address(this), _receiver, _share);

        emit LogBorrow(msg.sender, _receiver, _amount + feeAmount, _part);
    }

    /**
     *  @notice     Handles the repayment of borrowed YoloUSD.
     *  @param      _receiver   The address whose debt is being repaid.
     *  @param      _skim       True if the repayment amount is skimmed from the sender’s YoloBox balance, false if transferred.
     *  @param      _part       The portion of the debt to repay, tracked in `userBorrowPart`.
     *  @return     _amount     The amount of YoloUSD repaid.
     *  @dev        Internal function called by `repay`. Assumes `accrue` is called prior. Updates debt tracking,
     *              calculates shares, and transfers YoloUSD via YoloBox. Emits a `LogRepay` event.
     */
    function _repay(address _receiver, bool _skim, uint256 _part) internal returns (uint256 _amount) {
        (totalBorrow, _amount) = totalBorrow.sub(_part, true);
        userBorrowPart[_receiver] = userBorrowPart[_receiver] - _part;

        uint256 share = yoloBox.toShare(yoloUsd, _amount, true);
        yoloBox.transfer(yoloUsd, _skim ? address(yoloBox) : msg.sender, address(this), share);
        emit LogRepay(_skim ? address(yoloBox) : msg.sender, _receiver, _amount, _part);
    }

    /**
     *  @notice     A versatile functions to assist in parameter substitution for flexible function calls in cook().
     *  @param      _inNum      Can either be a positive integer or USE_VALUE1 / USE_VALUE2.
     *  @param      _value1     The first value to use if _inNum is USE_VALUE1. Used in cook() to pass values between actions.
     *  @param      _value2     The second value to use if _inNum is USE_VALUE2. Used in cook() to pass values between actions.
     *  @dev        This helper function allows parameters to be specified either directly (using positive values)
     *              or by reference to previously computed values (using the special constants USE_VALUE1 and USE_VALUE2).
     *              This enables chained operations where the output of one action becomes input for the next.
     */
    function _num(int256 _inNum, uint256 _value1, uint256 _value2) internal pure returns (uint256 _outNum) {
        _outNum = _inNum >= 0 ? uint256(_inNum) : (_inNum == USE_VALUE1 ? _value1 : _value2);
    }

    /**
     * @notice      Helper function to assist in depositing tokens into YoloBox in cook()
     * @param       _data       Encoded parameters (token, recipient, amount, share)
     * @param       _value      ETH value to send if depositing ETH
     * @param       _value1     First value from previous cook action (can be referenced via USE_VALUE1)
     * @param       _value2     Second value from previous cook action (can be referenced via USE_VALUE2)
     * @return      (amount, share) The amount and share values returned from YoloBox deposit
     */
    function _bentoDeposit(bytes memory _data, uint256 _value, uint256 _value1, uint256 _value2)
        internal
        returns (uint256, uint256)
    {
        (IERC20 _token, address _to, int256 _amount, int256 _share) =
            abi.decode(_data, (IERC20, address, int256, int256));
        _amount = int256(_num(_amount, _value1, _value2)); // Done this way to avoid stack too deep errors
        _share = int256(_num(_share, _value1, _value2));
        return yoloBox.deposit{value: _value}(_token, msg.sender, _to, uint256(_amount), uint256(_share));
    }

    /**
     * @notice      Helper function to withdraw tokens from YoloBox in cook()
     * @param       _data       Encoded parameters (token, recipient, amount, share)
     * @param       _value1     First value from previous cook action (can be referenced via USE_VALUE1)
     * @param       _value2     Second value from previous cook action (can be referenced via USE_VALUE2)
     * @return      (amount, share) The amount and share values returned from YoloBox withdraw
     */
    function _bentoWithdraw(bytes memory _data, uint256 _value1, uint256 _value2) internal returns (uint256, uint256) {
        (IERC20 token, address to, int256 amount, int256 share) = abi.decode(_data, (IERC20, address, int256, int256));
        return yoloBox.withdraw(token, msg.sender, to, _num(amount, _value1, _value2), _num(share, _value1, _value2));
    }

    /**
     *  @notice     Executes an arbitrary external call as part of a `cook()` transaction sequence.
     *  @param      _value      The amount of ETH to send with the external call (relevant for payable functions).
     *  @param      _data       ABI-encoded data specifying the call details: (address callee, bytes callData, bool useValue1, bool useValue2, uint8 returnValues).
     *  @param      _value1     The first potential value passed from a previous `cook` action, used if `useValue1` flag in `_data` is true.
     *  @param      _value2     The second potential value passed from a previous `cook` action, used if `useValue2` flag in `_data` is true.
     *  @return     bytes memory The raw return data obtained from the external call.
     *  @return     uint8        The `returnValues` flag (originally from `_data`), indicating how `cook` should interpret the `returnData` (0, 1, or 2 expected uint256 values).
     *  @dev        Internal helper function for the `cook` method. It decodes the target `callee`, initial `callData`, and control flags from `_data`.
     *              If specified by the flags `useValue1` or `useValue2`, it appends the provided `_value1` and/or `_value2` to the `callData` using `abi.encodePacked`.
     *              This allows chaining results from previous `cook` actions into subsequent external calls.
     *              It checks that the `callee` is not blacklisted before executing the low-level `.call{value: _value}()`.
     *              Requires the external call to succeed and returns the results for potential processing in the main `cook` loop.
     */
    function _call(uint256 _value, bytes memory _data, uint256 _value1, uint256 _value2)
        internal
        returns (bytes memory, uint8)
    {
        (address callee, bytes memory callData, bool useValue1, bool useValue2, uint8 returnValues) =
            abi.decode(_data, (address, bytes, bool, bool, uint8));

        if (useValue1 && !useValue2) {
            callData = abi.encodePacked(callData, _value1);
        } else if (!useValue1 && useValue2) {
            callData = abi.encodePacked(callData, _value2);
        } else if (useValue1 && useValue2) {
            callData = abi.encodePacked(callData, _value1, _value2);
        }

        if (blacklistedCallees[callee]) revert ErrorBlacklistedCallee();

        (bool success, bytes memory returnData) = callee.call{value: _value}(callData);

        if (!success) revert ErrorExternalCallFailed();

        return (returnData, returnValues);
    }

    /**
     *  @notice     Internal helper function that initiates the liquidation process for one or more users
     *              as part of a `cook()` transaction sequence.
     *  @param      _data       ABI-encoded data containing the parameters required for the `liquidate()`.
     */
    function _cookActionLiquidate(bytes calldata _data) internal {
        (
            address[] memory users,
            uint256[] memory maxBorrowParts,
            address to,
            ISwapperV2 swapper,
            bytes memory swapperData
        ) = abi.decode(_data, (address[], uint256[], address, ISwapperV2, bytes));
        liquidate(users, maxBorrowParts, to, swapper, swapperData);
    }

    function _additionalCookAction(
        uint8 _action,
        CookStatus memory _cookStatus,
        uint256 _value,
        bytes memory _data,
        uint256 _value1,
        uint256 _value2
    ) internal virtual returns (bytes memory, uint8, CookStatus memory) {}

    // ******************************* //
    // *** INTERNAL VIEW FUNCTIONS *** //
    // ******************************* //

    /**
     *  @notice  Helper function that checks if a user's position is solvent based on their borrow and collateral values.
     *  @dev     This is an internal helper function that assumes `accrue()` has already been called.
     *  @param   _user          The address of the user whose solvency is being checked.
     *  @param   _exchangeRate  The cached exchange rate between collateral and the borrowed asset (e.g., MIM).
     *  @return  bool           Returns true if the user is solvent, false otherwise.
     */
    function _isSolvent(address _user, uint256 _exchangeRate) internal view virtual returns (bool) {
        // accure() must be called before this function

        // Retrieve the user's borrowing
        uint256 borrowPart = userBorrowPart[_user];

        // If no borrowing return true
        if (borrowPart == 0) return true;

        // Retrieve the user's collateral
        uint256 collateralShare = userCollateralShare[_user];

        // If no collateral at all return false
        if (collateralShare == 0) return false;

        // Retrieve the total borrow information
        Rebase memory _totalBorrow = totalBorrow;

        // Calculate users collateral value in the borrowed asset
        uint256 collateralValue = yoloBox.toAmount(
            collateral,
            collateralShare * (EXCHANGE_RATE_PRECISION / COLLATERIZATION_RATE_PRECISION) * COLLATERIZATION_RATE,
            false
        );

        // Calculate users debt value in the borrowed asset
        uint256 debtValue = borrowPart * _totalBorrow.elastic * _exchangeRate / _totalBorrow.base;

        return collateralValue >= debtValue;
    }

    // ************* //
    // *** HOOKS *** //
    // ************* //

    function _afterAddCollateral(address _user, uint256 _collateralShare) internal virtual {}

    function _afterRemoveCollateral(address _from, address _receiver, uint256 _collateralShare) internal virtual {}

    function _preBorrowAction(address to, uint256 amount, uint256 newBorrowPart, uint256 part) internal virtual {}

    function _beforeUsersLiquidated(address[] memory users, uint256[] memory maxBorrowPart) internal virtual {}

    function _beforeUserLiquidated(address user, uint256 borrowPart, uint256 borrowAmount, uint256 collateralShare)
        internal
        virtual
    {}

    function _afterUserLiquidated(address user, uint256 collateralShare) internal virtual {}
}
