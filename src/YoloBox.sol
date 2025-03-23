// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/*---------- IMPORT LIBRARIES ----------*/
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@BoringSolidity/RebaseLibrary.sol";
/*---------- IMPORT INTERFACES ----------*/
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@yolo/contracts/interfaces/IWETH.sol";
import "@yolo/contracts/interfaces/IFlashBorrower.sol";
import "@yolo/contracts/interfaces/IStrategy.sol";
/*---------- IMPORT BASE CONTRACTS ----------*/
import "@yolo/contracts/contract-manager/MasterContractManager.sol";
import {BoringBatchable} from "@BoringSolidity/BoringBatchable.sol";

/**
 * @title   YoloBox
 * @author  0xyolodev.eth
 * @notice  The YoloBox contract functions as a permissionless vault for tokens. Tokens can be deposited,
 *          withdrawn, and being used as flash loans. Idle tokens can also be used by strategies to generate
 *          yield, and it goes to all depositors.
 *          WARNING: Rebasing and non-conventoonal tokens are not supported.
 * @dev     Based on DegenBox: https://github.com/Abracadabra-money/abracadabra-money-contracts/blob/main/src/DegenBox.sol
 */
contract YoloBox is MasterContractManager, BoringBatchable {
    // ***************** //
    // *** LIBRARIES *** //
    // ***************** //
    using SafeERC20 for IERC20;
    using RebaseLibrary for Rebase;

    // ***************** //
    // *** DATATYPES *** //
    // ***************** //

    struct StrategyData {
        uint64 strategyStartDate;
        uint64 targetPercentage;
        uint128 balance; // the balance of the strategy that YoloBox keeps tracks
    }

    // ******************************** //
    // *** CONSTANTS AND IMMUTABLES *** //
    // ******************************** //

    // CONSTANTS
    uint256 public constant PRECISION_DIVISOR = 10000; // 100%
    uint256 public constant MAX_FLASH_LOAN_FEE = 100; // 1%
    uint256 public constant MINIMUM_SHARE_BALANCE = 1000; // To prevent the ratio going off
    uint256 public constant MAX_TARGET_PERCENTAGE = 9500; // 95%
    uint256 public constant STRATEGY_DELAY = 3 days; // Delay before a new strategy can be set

    // IMMUTABLES
    IWETH public immutable weth;

    // ***************************//
    // *** CONTRACT VARIABLES *** //
    // ************************** //
    uint256 public FLASH_LOAN_FEE = 9; // Fee of calling flash loan
    mapping(IERC20 => mapping(address => uint256)) public balanceOf;
    mapping(IERC20 => Rebase) public totals; // Keeps tracks of the token balance
    mapping(IERC20 => IStrategy) public strategy; // Keeps track of the current active strategy contract for each asset
    mapping(IERC20 => IStrategy) public pendingStrategy; // Keeps track of the pending strategy contract for each asset
    mapping(IERC20 => StrategyData) public strategyData; // Keeps track of the each current strategy data

    // ************** //
    // *** EVENTS *** //
    // ************** //
    event LogDeposit(
        IERC20 indexed token, address indexed from, address indexed receiver, uint256 amount, uint256 share
    );
    event LogWithdraw(
        IERC20 indexed token, address indexed from, address indexed receiver, uint256 amount, uint256 share
    );
    event LogTransfer(address token, address indexed from, address indexed receiver, uint256 share);
    event LogFlashLoan(
        address indexed borrower, address indexed receiver, IERC20 indexed token, uint256 amount, uint256 fee
    );
    event LogFlashLoanFeeUpdated(uint256 newFee, uint256 oldFee);
    event LogStrategyTargetPercentage(IERC20 indexed token, uint256 targetPercentage);
    event LogStrategyQueued(IERC20 indexed token, IStrategy indexed strategy);
    event LogStrategySet(IERC20 indexed token, IStrategy indexed strategy);
    event LogStrategyInvest(IERC20 indexed token, uint256 amount);
    event LogStrategyDivest(IERC20 indexed token, uint256 amount);
    event LogStrategyProfit(IERC20 indexed token, uint256 amount);
    event LogStrategyLoss(IERC20 indexed token, uint256 amount);

    // ************** //
    // *** ERRORS *** //
    // ************** //

    error ErrorEthTransferFailed();
    error ErrorMsgValueMismatch();
    error ErrorNoMasterContract();
    error ErrorTransferNotApproved();
    error ErrorParamsLengthMismatch();
    error ErrorDepositToZeroAddress();
    error ErrorDepositInvalidToken();
    error ErrorSkimTooMuch();
    error ErrorWithdrawToZeroAddress();
    error ErrorCannotEmpty();
    error ErrorTransferToZeroAddress();
    error ErrorAmountZero();
    error ErrorInsufficientShare();
    error ErrorWrongBalanceAfterFlashLoan();
    error ErrorSetFlashLoanFeeTooHigh();
    error ErrorStrategyTargetPercentageTooHigh();
    error ErrorStrategyZeroAddress();
    error ErrorStrategyDelayNotPassed();

    // ***************** //
    // *** MODIFIERS *** //
    // ***************** //

    /**
     * @dev     Modifier to check if the msg.sender is allowed to use the funds belonging to the 'from' address.
     *          If 'from' is msg.sender or the YoloVault itself, it's allowed.
     * @param   _from   Address whose funds will be spent on behalf of.
     */
    modifier allowed(address _from) {
        if (_from != msg.sender && _from != address(this)) {
            address masterContract = masterContractOf[msg.sender];
            // require(masterContract != address(0), "BentoBox: no masterContract");
            // require(masterContractApproved[masterContract][_from], "BentoBox: Transfer not approved");
            if (masterContract == address(0)) revert ErrorNoMasterContract();
            if (!masterContractApproved[masterContract][_from]) revert ErrorTransferNotApproved();
        }
        _;
    }

    // ******************* //
    // *** CONSTRUCTOR *** //
    // ******************* //

    /**
     *  @dev     Constructor
     *  @param   _weth   Address of the WETH contract
     */
    constructor(address _weth) {
        weth = IWETH(_weth);
        _configure();
    }

    // ************************ //
    // *** PUBLIC FUNCTIONS *** //
    // ************************ //

    /**
     *  @dev     Deposit an amount of "_token" either represented in "amount" or "share".
     *  @param   _token     Token to be deposited.
     *  @param   _from      Address of the sender.
     *  @param   _receiver  Address of the receiver.
     *  @param   _amount    Amount of the token to be deposited. Either one of "amount" or "share" needs to be supplied.
     *  @param   _share     Share of the token to be deposited. Either one of "amount" or "share" needs to be supplied. Share takes precedence.
     */
    function deposit(IERC20 _token, address _from, address _receiver, uint256 _amount, uint256 _share)
        public
        payable
        allowed(_from)
        returns (uint256 amountOut, uint256 shareOut)
    {
        // Guard clause: avoid burning funds due to accident
        if (_receiver == address(0)) revert ErrorDepositToZeroAddress();

        // If token is address(0), means it's using ETH
        IERC20 token;
        if (address(_token) == address(0)) {
            if (msg.value != _amount) revert ErrorMsgValueMismatch();
            token = IERC20(address(weth));
        } else {
            token = _token;
        }

        // Hook: before deposit
        _onBeforeDeposit(token, _from, _receiver, _amount, _share);

        // Retrieve the amount and share of the token
        Rebase memory total = totals[token];

        // Guard Clause: Ensure the token is valid, either it is an exisiting token or it is a legit new token that was first added
        if (total.elastic == 0 && token.totalSupply() == 0) revert ErrorDepositInvalidToken();

        // Handles the case where user did not specifies a share amount to be deposited
        if (_share == 0) {
            // value of the share may be lower than the amount due to rounding, that's ok
            _share = total.toBase(_amount, false);
            // Any deposit should lead to at least the minimum share balance, otherwise it's ignored (no amount taken)
            if (total.base + uint128(_share) < MINIMUM_SHARE_BALANCE) {
                return (0, 0);
            }
        } else {
            // amount may be lower than the value of share due to rounding, in that case, add 1 to amount (Always round up)
            _amount = total.toElastic(_share, true);
        }

        // In case of skimming, check that only the skimmable amount is taken
        if (
            _from == address(this) && address(_token) != address(0)
                && _amount > _tokenBalanceOf(address(token)) - total.elastic
        ) {
            revert ErrorSkimTooMuch();
        }

        // Update balance status
        balanceOf[token][_receiver] = balanceOf[token][_receiver] + _share;
        total.base = total.base + (uint128(_share));
        total.elastic = total.elastic + uint128(_amount);
        totals[token] = total;

        // Interactions
        if (address(_token) == address(0)) {
            weth.deposit{value: _amount}();
        } else if (_from != address(this)) {
            token.safeTransferFrom(_from, address(this), _amount);
        }
        emit LogDeposit(_token, _from, _receiver, _amount, _share);
        amountOut = _amount;
        shareOut = _share;
    }

    /**
     *  @dev     Withdraw an amount of "_token" either represented in "amount" or "share".
     *  @param   _token     Token to be withdrawn.
     *  @param   _from      Address of the withdrawer.
     *  @param   _receiver  Address of the receiver.
     *  @param   _amount    Amount of the token to be withdrawn. Either one of "amount" or "share" needs to be supplied.
     *  @param   _share     Share of the token to be withdrawn. Either one of "amount" or "share" needs to be supplied. Share takes precedence.
     */
    function withdraw(IERC20 _token, address _from, address _receiver, uint256 _amount, uint256 _share)
        public
        allowed(_from)
        returns (uint256 amountOut, uint256 shareOut)
    {
        // Guard clause: avoid burning funds due to accident
        if (_receiver == address(0)) revert ErrorWithdrawToZeroAddress();

        // If token is address(0), means it's using ETH
        IERC20 token;
        if (address(_token) == address(0)) {
            token = IERC20(address(weth));
        } else {
            token = _token;
        }

        // Retrieve the amount and share of the token
        Rebase memory total = totals[token];

        if (_share == 0) {
            // value of the share paid could be lower than the amount paid due to rounding, in that case, add a share (Always round up)
            _share = total.toBase(_amount, true);
        } else {
            // amount may be lower than the value of share due to rounding, that's ok
            _amount = total.toElastic(_share, false);
        }

        balanceOf[token][_from] = balanceOf[token][_from] - _share;
        total.elastic = total.elastic - uint128(_amount);
        total.base = total.base - uint128(_share);

        // There have to be at least 1000 shares left to prevent reseting the share/amount ratio (unless it's fully emptied)
        if (total.base < MINIMUM_SHARE_BALANCE && total.base != 0) revert ErrorCannotEmpty();
        totals[token] = total;

        // Interactions
        if (address(_token) == address(0)) {
            weth.withdraw(_amount);
            (bool success,) = _receiver.call{value: _amount}("");
            if (!success) revert ErrorEthTransferFailed();
        } else {
            token.safeTransfer(_receiver, _amount);
        }
        emit LogWithdraw(_token, _from, _receiver, _amount, _share);
        amountOut = _amount;
        shareOut = _share;
    }

    /**
     *  @dev     Transfer shares from a user account to another user.
     *  @param   _token     Address of the token to be transferred.
     *  @param   _from      Address of the sender.
     *  @param   _receiver  Address of the receiver.
     *  @param   _share     Share of the token to be transferred.
     */
    function transfer(address _token, address _from, address _receiver, uint256 _share) public allowed(_from) {
        IERC20 token = IERC20(_token);

        // Guard Clause: Avoid burning funds due to accident
        if (_receiver == address(0)) revert ErrorTransferToZeroAddress();
        if (balanceOf[token][_from] < _share) revert ErrorInsufficientShare();

        // Effects
        balanceOf[token][_from] = balanceOf[token][_from] - _share;
        balanceOf[token][_receiver] = balanceOf[token][_receiver] + _share;

        emit LogTransfer(_token, _from, _receiver, _share);
    }

    /**
     *  @dev     Transfer shares from a user account to multiple users.
     *  @param   _token     Address of the token to be transferred.
     *  @param   _from      Address of the sender.
     *  @param   _receivers Array of addresses of the receivers.
     *  @param   _shares    Array of share amounts of the token to be transferred.
     */
    function transferMultiple(address _token, address _from, address[] calldata _receivers, uint256[] calldata _shares)
        public
        allowed(_from)
    {
        // Guard Clause: Check params length
        if (_receivers.length != _shares.length) revert ErrorParamsLengthMismatch();

        // Effects
        for (uint256 i = 0; i < _receivers.length; i++) {
            transfer(_token, _from, _receivers[i], _shares[i]);
        }
    }

    // ****************** //
    // *** FLASHLOANS *** //
    // ****************** //

    /**
     *  @dev     Function to perform a flashloan for a single token, and pulls the principal + fee from the borrower.
     *  @param   _borrower  Address of the borrower contract that will also repay the loan.
     *  @param   _receiver  Address of the receiver contract.
     *  @param   _token     Address of the token to be flash loaned.
     *  @param   _amount    Amount of the token to be flash loaned.
     *  @param   _data      Data to be passed to the borrower contract.
     */
    function flashLoan(address _borrower, address _receiver, address _token, uint256 _amount, bytes calldata _data)
        public
    {
        // Guard Clause: Ensure amount is not zero
        if (_amount == 0) revert ErrorAmountZero();

        // Calculate Fee
        uint256 fee = _amount * FLASH_LOAN_FEE / PRECISION_DIVISOR;

        // Transfer token to receiver
        IERC20 token = IERC20(_token);
        token.safeTransfer(_receiver, _amount);

        // Execute flash loan callback
        IFlashBorrower(_borrower).onFlashLoan(msg.sender, _token, _amount, fee, _data);

        // Pull back the principal + fee from the borrower
        token.safeTransferFrom(_borrower, address(this), _amount + fee);

        // Ensures the balance of the token is correct after flash loan
        // if (_tokenBalanceOf(_token) < totals[token].addElastic(uint128(fee))) revert ErrorWrongBalanceAfterFlashLoan();

        // Distribute fee to all depositors
        totals[token].elastic = totals[token].elastic + (uint128(fee));

        // Emit flash loan event
        emit LogFlashLoan(_borrower, _receiver, token, _amount, fee);
    }

    /**
     * @dev     Function to perform a batch flash loan for multiple tokens, pulling principal + fees from the borrower.
     * @param   _borrower   Address of the borrower contract that will also repay the loan.
     * @param   _receivers  Array of addresses receiving the loaned amounts.
     * @param   _tokens     Array of token addresses to be flash loaned.
     * @param   _amounts    Array of amounts to be loaned for each token.
     * @param   _data       Data to be passed to the borrower contract during the callback.
     */
    function batchFlashLoan(
        address _borrower,
        address[] calldata _receivers,
        address[] calldata _tokens,
        uint256[] calldata _amounts,
        bytes calldata _data
    ) public {
        // Guard clause: Ensure array lengths are consistent
        if (_tokens.length != _receivers.length || _tokens.length != _amounts.length) {
            revert ErrorParamsLengthMismatch();
        }

        // Track cumulative amounts and fees per token, avoid underpaying flash loan fees
        // mapping(address => uint256) memory totalAmounts;
        // mapping(address => uint256) memory totalFees;
        uint256[] memory fees = new uint256[](_tokens.length);

        // Transfer tokens to receivers
        for (uint256 i = 0; i < _tokens.length; i++) {
            // Guard clause: Ensure amount is not zero
            if (_amounts[i] == 0) revert ErrorAmountZero();

            // Calculate fee for this token
            fees[i] = _amounts[i] * FLASH_LOAN_FEE / PRECISION_DIVISOR;

            // // Accumulate totals
            // totalAmounts[_tokens[i]] += _amounts[i];
            // totalFees[_tokens[i]] += fees[i];

            // Transfer token to receiver
            IERC20 token = IERC20(_tokens[i]);
            token.safeTransfer(_receivers[i], _amounts[i]);
        }

        // Execute batch flash loan callback
        IFlashBorrower(_borrower).onBatchFlashLoan(msg.sender, _tokens, _amounts, fees, _data);

        // Pull back the principal + fee from the borrower for each token
        // mapping(address => bool) memory processedTokens; // Track processed tokens
        for (uint256 i = 0; i < _tokens.length; i++) {
            // if (!processedTokens[_tokens[i]]) {
            IERC20 token = IERC20(_tokens[i]);
            token.safeTransferFrom(_borrower, address(this), _amounts[i] + fees[i]);

            // Ensures the balance of the token is correct after flash loan
            // if (_tokenBalanceOf(_tokens[i]) < totals[_tokens[i]].addElastic(uint128(totalFees[_tokens[i]]))) {
            //     revert ErrorWrongBalanceAfterFlashLoan();
            // }

            // Distribute fee to all depositors
            totals[token].elastic = totals[token].elastic + uint128(fees[i]);

            // processedTokens[_tokens[i]] = true;
            emit LogFlashLoan(_borrower, _receivers[i], token, _amounts[i], fees[i]);
        }
        // }
    }

    // ************* //
    // *** YIELD *** //
    // ************* //

    function harvest(IERC20 _token, bool _balance, uint256 _maxChangeAmount) public {
        // Retrieve the strategy data and strategy address
        StrategyData memory data = strategyData[_token];
        IStrategy _strategy = strategy[_token];

        // Harvest from the strategy
        int256 balanceChange = _strategy.harvest(data.balance, msg.sender);

        // If there is no balance change and housekeeping is not needed, return
        if (balanceChange == 0 && !_balance) {
            return;
        }

        // Retrieve the total elastic balance of the token
        uint256 totalElastic = totals[_token].elastic;

        // If positive balance change
        if (balanceChange > 0) {
            uint256 add = uint256(balanceChange);
            totalElastic = totalElastic + add;
            totals[_token].elastic = uint128(totalElastic);
            emit LogStrategyProfit(_token, add);
        } else if (balanceChange < 0) {
            // If negative balance change
            uint256 sub = uint256(-balanceChange);
            totalElastic = totalElastic - sub;
            totals[_token].elastic = uint128(totalElastic);
            data.balance = data.balance - uint128(sub);
            emit LogStrategyLoss(_token, sub);
        }

        // Rebalances the strategy to match the target percentage

        if (_balance) {
            uint256 targetBalance = totalElastic * data.targetPercentage / PRECISION_DIVISOR;

            if (data.balance < targetBalance) {
                uint256 amountOut = targetBalance - data.balance;
                if (_maxChangeAmount != 0 && amountOut > _maxChangeAmount) {
                    amountOut = _maxChangeAmount;
                }
                _token.safeTransfer(address(_strategy), amountOut);
                data.balance = data.balance + uint128(amountOut);
                _strategy.skim(amountOut);
                emit LogStrategyInvest(_token, amountOut);
            } else if (data.balance > targetBalance) {
                uint256 amountIn = data.balance - targetBalance;
                if (_maxChangeAmount != 0 && amountIn > _maxChangeAmount) {
                    amountIn = _maxChangeAmount;
                }
                uint256 actualAmountIn = _strategy.withdraw(amountIn);
                data.balance = data.balance - uint128(actualAmountIn);
                emit LogStrategyDivest(_token, actualAmountIn);
            }
        }

        strategyData[_token] = data;
    }

    // ********************* //
    // *** CONFIGURATION *** //
    // ********************* //
    /**
     * @dev     Updates the flash loan fee percentage, only callable by contract owner.
     *          The new fee must not exceed the maximum allowed fee (1%).
     * @param   _newFee   The new fee percentage to set, expressed with PRECISION_DIVISOR (e.g., 9 = 0.09%).
     */
    function setFlashLoanFee(uint256 _newFee) external onlyOwner {
        if (_newFee > MAX_FLASH_LOAN_FEE) revert ErrorSetFlashLoanFeeTooHigh();
        uint256 oldFee = FLASH_LOAN_FEE;
        FLASH_LOAN_FEE = _newFee;
        emit LogFlashLoanFeeUpdated(_newFee, oldFee);
    }

    /**
     * @dev     Sets the target percentage of the strategy for `_token`.
     * @param   _token              The token of which its strategy target percentage will be set.
     * @param   _targetPercentage   The new target in percent. Must be lesser than or equal to `MAX_TARGET_PERCENTAGE`.
     */
    function setStrategyTargetPercentage(IERC20 _token, uint64 _targetPercentage) public onlyOwner {
        if (_targetPercentage > MAX_TARGET_PERCENTAGE) revert ErrorStrategyTargetPercentageTooHigh();
        strategyData[_token].targetPercentage = _targetPercentage;
        emit LogStrategyTargetPercentage(_token, _targetPercentage);
    }

    /**
     * @dev     1) Sets a new strategy as pending strategy.
     *          2) Sets a fully queued strategy as current strategy, and exits from the old strategy.
     * @param   _token              The token of which its strategy will change.
     * @param   _newStrategy        The address of the new strategy contract.
     */
    function setStrategy(IERC20 _token, IStrategy _newStrategy) public onlyOwner {
        // Guard Clause: Ensure the new strategy is not the zero address
        if (address(_newStrategy) == address(0)) revert ErrorStrategyZeroAddress();

        // Retrieve the strategy data of the _token
        StrategyData memory data = strategyData[_token];

        // Retrieve the pending strategy of the _token
        IStrategy pending = pendingStrategy[_token];

        if (data.strategyStartDate == 0 || pending != _newStrategy) {
            // If it's the first strategy or pending strategy is different from the new strategy
            // Set the pending strategy
            pendingStrategy[_token] = _newStrategy;
            data.strategyStartDate = uint64(block.timestamp + STRATEGY_DELAY);
            emit LogStrategyQueued(_token, _newStrategy);
        } else {
            // Guard Clause: The strategy wasn't ready for activation
            if (data.strategyStartDate == 0 || block.timestamp < data.strategyStartDate) {
                revert ErrorStrategyDelayNotPassed();
            }

            // Exits the old strategy
            if (address(strategy[_token]) != address(0)) {
                int256 balanceChange = strategy[_token].exit(data.balance);
                // Effects
                if (balanceChange > 0) {
                    uint256 add = uint256(balanceChange);
                    totals[_token].addElastic(add);
                    emit LogStrategyProfit(_token, add);
                } else if (balanceChange < 0) {
                    uint256 sub = uint256(-balanceChange);
                    totals[_token].subElastic(sub);
                    emit LogStrategyLoss(_token, sub);
                }

                emit LogStrategyDivest(_token, data.balance);
            }
            // Update pending strategy as current strategy
            strategy[_token] = pending;
            data.strategyStartDate = 0;
            data.balance = 0;
            pendingStrategy[_token] = IStrategy(address(0));
            emit LogStrategySet(_token, _newStrategy);
        }
        strategyData[_token] = data;
    }

    // ***************************** //
    // *** HOOKS *** //
    // ***************************** //

    function _configure() internal virtual {}

    function _onBeforeDeposit(IERC20 _token, address _from, address _to, uint256 _amount, uint256 _share)
        internal
        virtual
    {}

    // ***************************** //
    // *** PUBLIC VIEW FUNCTIONS *** //
    // ***************************** //

    /**
     * @dev     Helper function to represent an `amount` of `token` in shares.
     * @param   _token      The ERC-20 token.
     * @param   _amount     The `token` amount.
     * @param   _roundUp    If the result `share` should be rounded up.
     * @return  _share      The token amount represented in shares.
     */
    function toShare(IERC20 _token, uint256 _amount, bool _roundUp) external view returns (uint256 _share) {
        _share = totals[_token].toBase(_amount, _roundUp);
    }

    /**
     * @dev     Helper function to represent shares back into the `token` amount.
     * @param   _token      The ERC-20 token.
     * @param   _share      The amount of shares.
     * @param   _roundUp    If the result `share` should be rounded up.
     * @return  _amount     The share amount back into native representation.
     */
    function toAmount(IERC20 _token, uint256 _share, bool _roundUp) external view returns (uint256 _amount) {
        _amount = totals[_token].toElastic(_share, _roundUp);
    }

    // ************************** //
    // *** INTERNAL FUNCTIONS *** //
    // ************************** //

    /**
     * @dev     Internal helper function to get the balance of specific token in the YoloBox and its strategy.
     * @param   _token   Contract address of the token
     */
    function _tokenBalanceOf(address _token) internal view returns (uint256 amount) {
        IERC20 token = IERC20(_token);
        amount = token.balanceOf(address(this)) + (strategyData[token].balance);
    }

    // ************************** //
    // *** RECEIVE & FALLBACK *** //
    // ************************** //

    receive() external payable {}
}
