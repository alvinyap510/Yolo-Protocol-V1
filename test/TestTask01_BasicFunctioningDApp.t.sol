// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/*---------- IMPORT TEST SUITES ----------*/
import "forge-std/Test.sol";
import "forge-std/console2.sol";
/*---------- IMPORT LIBRARIES ----------*/
import "@BoringSolidity/RebaseLibrary.sol";
/*---------- IMPORT INTERFACES ----------*/
import "@yolo/contracts/interfaces/IWETH.sol";
import "@yolo/contracts/interfaces/IYoloBox.sol";
import "@yolo/contracts/interfaces/IMintableERC20.sol";
import "@yolo/contracts/interfaces/IOracle.sol";
import "@yolo/contracts/interfaces/IYoloVault.sol";
/*---------- IMPORT MOCKS ----------*/
import "@yolo/contracts/mocks/MockWETH.sol";
import "@yolo/contracts/mocks/MockERC20.sol";
import "@yolo/contracts/mocks/MockOracle.sol";
/*---------- IMPORT CONTRACTS ----------*/
import "@yolo/contracts/YoloBox.sol";
import "@yolo/contracts/vaults/YoloVault.sol";

/**
 * @title   TestTask01_BasicFunctioningDApp
 * @author  0xyolodev.eth
 * @notice  This test script is meant to test the basic functionality of a minimal
 *          functioning overcollateralized stablecoin protocol.
 */
contract TestTask01_BasicFunctioningDApp is Test {
    // ***************** //
    // *** LIBRARIES *** //
    // ***************** //
    using RebaseLibrary for Rebase;

    // ************* //
    // *** ROLES *** //
    // ************* //
    uint256 deployerKey = 1;
    address deployer = vm.addr(deployerKey);

    uint256 user1Key = 11;
    address user1 = vm.addr(user1Key);

    uint256 user2Key = 22;
    address user2 = vm.addr(user2Key);

    uint256 user3Key = 33;
    address user3 = vm.addr(user3Key);

    // ***************** //
    // *** DATATYPES *** //
    // ***************** //

    // ************************** //
    // *** DEPLOYED CONTRACTS *** //
    // ************************** //
    YoloBox yoloBox;
    IWETH weth; // also functions as collateral
    IMintableERC20 usy; // as stablecoin
    IOracle oracle;
    IYoloVault masterVault;
    IYoloVault cloneVault;

    // ******************* //
    // *** TEST CONFIG *** //
    // ******************* //
    uint256 constant INITIAL_USY_MINT = 10_000_000 * 1e18; // 10 million USY
    uint256 constant INITIAL_ETH_PRCE = 2020 * 1e8; // 1 ETH = 2000 USD
    uint256 constant INITIAL_ETH_AMOUNT = 1_000 * 1e18; // 1000 ETH
    uint256 constant COLLATERIZATION_RATE = 75_000; // 75% (75000/100000)
    uint64 constant INTEREST_PER_SECOND = 158549382; // ~5% APY
    uint256 constant LIQUIDATION_MULTIPLIER = 110_000; // 110% (10% fee)
    uint256 constant BORROW_OPENING_FEE = 50; // 0.05% (50/100000)
    uint256 internal constant EXCHANGE_RATE_PRECISION = 1e18; // The precision of the exchange rate
    uint256 internal constant COLLATERIZATION_RATE_PRECISION = 1e5; // Must be less than EXCHANGE_RATE_PRECISION (due to optimization in math)
    uint256 internal constant BORROW_OPENING_FEE_PRECISION = 1e5; // Precision of the borrow opening fee
    uint256 internal constant LIQUIDATION_MULTIPLIER_PRECISION = 1e5; // Precision of the borrow opening fee
    uint256 internal constant DISTRIBUTION_PART = 10; // The part of the liquidation bonus that is distributed to sSpell holders
    uint256 internal constant DISTRIBUTION_PRECISION = 100; // The precision of the distribution

    // At the top of your contract, add:
    bytes32 constant MASTER_CONTRACT_APPROVAL_TYPEHASH = keccak256(
        "SetMasterContractApproval(string warning,address user,address masterContract,bool approved,uint256 nonce)"
    );

    // ******************* //
    // *** CONSTRUCTOR *** //
    // ******************* //

    constructor() {
        console.log("Deployer: ", deployer);
        vm.startPrank(deployer);

        // Deploy the basic contracts
        weth = IWETH(address(new MockWETH()));
        yoloBox = new YoloBox(address(weth));
        usy = IMintableERC20(address(new MockERC20("USD Yolo", "USY")));
        oracle = IOracle(address(new MockOracle(INITIAL_ETH_PRCE))); // 1 ETH = 2020 USD

        // Mint USY stablecoin to the deployer
        usy.mint(deployer, INITIAL_USY_MINT);

        // Approve YoloBox to spend USY tokens
        usy.approve(address(yoloBox), type(uint256).max);

        // Deposit USY to YoloBox
        yoloBox.deposit(IERC20(address(usy)), deployer, deployer, INITIAL_USY_MINT, 0);

        // Deploy YoloVault master contract
        masterVault = IYoloVault(address(new YoloVault(IYoloBox(address(yoloBox)), IERC20(address(usy)), deployer)));

        // Create initialization data for YoloVault clone
        bytes memory initData = abi.encode(
            IERC20(address(weth)), // collateral
            oracle, // oracle
            "", // oracleData (empty for MockOracle)
            INTEREST_PER_SECOND, // interestPerSecond
            LIQUIDATION_MULTIPLIER, // liquidationMultiplier
            COLLATERIZATION_RATE, // collaterizationRate
            BORROW_OPENING_FEE // borrowOpeningFee
        );

        // Deploy YoloVault clone via YoloBox
        address cloneVaultAddress = yoloBox.deploy(
            address(masterVault),
            initData,
            true // useCreate2
        );

        cloneVault = IYoloVault(address(YoloVault(cloneVaultAddress)));

        // Set fee receiver
        cloneVault.setFeeTo(deployer);

        // Transfer USY shares from deployer to vault in YoloBox
        uint256 usyShare = yoloBox.balanceOf(IERC20(address(usy)), deployer);
        yoloBox.transfer(address(usy), deployer, address(cloneVault), usyShare);

        vm.stopPrank();

        // Setup users with ETH and WETH
        vm.deal(user1, INITIAL_ETH_AMOUNT);
        vm.prank(user1);
        weth.deposit{value: 500 * 1e18}();

        vm.deal(user2, INITIAL_ETH_AMOUNT);
        vm.prank(user2);
        weth.deposit{value: 100 * 1e18}();

        vm.deal(user3, INITIAL_ETH_AMOUNT);
        vm.prank(user3);
        weth.deposit{value: 100 * 1e18}();
    }

    // *************** //
    // *** HELPERS *** //
    // *************** //

    function _borrow(address user, uint256 amount) internal {
        vm.startPrank(user);
        cloneVault.borrow(user, amount);
        vm.stopPrank();
    }

    /**
     * @dev     Helper function to set approval for a vault to spend a token in YoloBox.
     * @param   _privateKey     The private key of the user used in vm.sign().
     * @param   _yoloBox        The address of the YoloBox contract.
     * @param   _vault          The address of the clone vault contract.
     * @param   _asset          The address of the asset.
     */
    function _setApprovalHelper(uint256 _privateKey, address _yoloBox, address _vault, address _asset, bool _toApprove)
        internal
    {
        address user = vm.addr(_privateKey);
        IYoloBox yoloBox_ = IYoloBox(_yoloBox);
        IYoloVault vault_ = IYoloVault(_vault);

        bytes32 domainSeparator = yoloBox_.DOMAIN_SEPARATOR();
        bytes32 typeHash = MASTER_CONTRACT_APPROVAL_TYPEHASH;
        uint256 nonce = yoloBox_.nonces(user);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            _privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    domainSeparator,
                    keccak256(
                        abi.encode(
                            typeHash,
                            _toApprove
                                ? keccak256("Give FULL access to funds in (and approved to) BentoBox?")
                                : keccak256("Revoke access to BentoBox?"),
                            user,
                            address(vault_),
                            true,
                            nonce
                        )
                    )
                )
            )
        );
        yoloBox_.setMasterContractApproval(user, address(vault_), true, v, r, s);
    }

    /**
     * @dev     Helper function to deposit an asset to YoloBox on behalf of user.
     * @param   _privateKey     The private key of the user.
     * @param   _yoloBox        The address of the YoloBox contract.
     * @param   _asset          The address of the asset.
     * @param   _amount         The amount to deposit.
     */
    function _depositHelper(uint256 _privateKey, address _yoloBox, address _asset, uint256 _amount) internal {
        address user = vm.addr(_privateKey);
        IERC20 asset = IERC20(_asset);
        IYoloBox yoloBox_ = IYoloBox(_yoloBox);

        if (asset.allowance(_yoloBox, user) < _amount) {
            asset.approve(address(yoloBox_), type(uint256).max);
        }
        yoloBox.deposit(asset, user, user, _amount, 0);
    }

    /**
     * @dev     Helper function to pack the transfer(), borrow() and addCollateral() into a single cook()
     *          function to prevent frontrunning attacks.
     * @param   _privateKey         The private key of the user.
     * @param   _yoloBox            The address of the YoloBox contract.
     * @param   _vault              The address of the clone vault contract.
     * @param   _amountToBorrow     The amount to deposit.
     * @return  _borrowPart         The borrow part assigned to the user by the vault.
     * @return  _usyBorrowedShare   The share amount of USY transferred to the user in YoloBox.
     */
    function _borrowHelper(uint256 _privateKey, address _yoloBox, address _vault, uint256 _amountToBorrow)
        internal
        returns (uint256 _borrowPart, uint256 _usyBorrowedShare)
    {
        address user = vm.addr(_privateKey);
        IYoloBox yoloBox_ = IYoloBox(_yoloBox);
        IYoloVault vault_ = IYoloVault(_vault);
        IERC20 collateral_ = vault_.collateral();

        // --- Get user's current collateral share in YoloBox ---
        uint256 userShareInYoloBox = yoloBox_.balanceOf(collateral_, user);
        require(userShareInYoloBox > 0, "_borrowHelper: User has no collateral shares in YoloBox");

        console.log("--- _borrowHelper for user:", user, "---");
        console.log("Collateral Share to use:", userShareInYoloBox);
        console.log("Amount to Borrow:", _amountToBorrow);
        console.log("------------------------------------------");

        // --- Prepare cook() parameters ---
        uint8[] memory actions = new uint8[](4); // No ETH value needed

        actions[0] = 22; // ACTION_BENTO_TRANSFER: User transfers collateral shares to the vault
        actions[1] = 10; // ACTION_ADD_COLLATERAL: Vault recognises the shares (skim=true)
        actions[2] = 5; // ACTION_BORROW: User borrows USY
        actions[3] = 21; // ACTION_BENTO_WITHDRAW: Withdraw user's USY share

        uint256[] memory values = new uint256[](4); // No ETH value needed

        bytes[] memory datas = new bytes[](4);
        // Action 0: BENTO_TRANSFER(token, to, share) -> from is msg.sender (user)
        datas[0] = abi.encode(collateral_, _vault, int256(userShareInYoloBox));
        // Action 1: ADD_COLLATERAL(share, to, skim) -> 'to' is who gets credited
        datas[1] = abi.encode(int256(userShareInYoloBox), user, true); // skim = true
        // Action 2: BORROW(amount, to) -> 'to' is who receives the borrowed funds
        datas[2] = abi.encode(int256(_amountToBorrow), user);
        // Action 3: WITHDRAW(token, from, share) -> 'from' is who gets debited
        datas[3] = abi.encode(address(usy), user, user, int256(_amountToBorrow), 0);

        // --- Execute cook() via the user ---
        vm.startPrank(user);
        (, _usyBorrowedShare) = vault_.cook(actions, values, datas);
        _borrowPart = vault_.userBorrowPart(user); // Get actual borrow part including fee
        vm.stopPrank();

        console.log("--- _borrowHelper Cook Results ---");
        console.log("Returned Borrow Part:", _borrowPart);
        console.log("Returned USY Share:", _usyBorrowedShare);
        console.log("----------------------------------");
    }

    // ******************* //
    // *** TEST CASES *** //
    // ******************* //

    function test_00_deployment() public {
        console.log();
        console.log("**************** Test 00 Deployment ****************");
        console.log();

        // Verify contracts are properly deployed
        assertEq(address(cloneVault.yoloBox()), address(yoloBox));
        assertEq(address(cloneVault.yoloUsd()), address(usy));
        assertEq(address(cloneVault.collateral()), address(weth));
        assertEq(address(cloneVault.oracle()), address(oracle));

        // Verify parameters are set correctly
        assertEq(cloneVault.COLLATERIZATION_RATE(), COLLATERIZATION_RATE);
        assertEq(cloneVault.LIQUIDATION_MULTIPLIER(), LIQUIDATION_MULTIPLIER);
        assertEq(cloneVault.BORROW_OPENING_FEE(), BORROW_OPENING_FEE);
    }

    function test_01_deposit_collateral() public {
        console.log();
        console.log("**************** Test 01 Deposit Collateral ****************");
        console.log();

        // Determine user
        address user = vm.addr(user1Key);
        vm.startPrank(user);

        // Initial balances
        uint256 initialWethBalance = weth.balanceOf(user1);
        uint256 depositAmount = initialWethBalance / 2;

        // Check user state
        console.log("User is despositing collateral: ", user);
        console.log("User initial weth balance: ", initialWethBalance);

        // Approve and deposit
        _depositHelper(user1Key, address(yoloBox), address(weth), depositAmount);

        // Check balances after deposit
        assertEq(weth.balanceOf(user1), initialWethBalance - depositAmount);

        // Assert YoloBox related balances
        uint256 userShareInYoloBox = yoloBox.balanceOf(IERC20(address(weth)), user);
        assertGt(userShareInYoloBox, 0, "User should have shares in YoloBox");
        console.log("User share in YoloBox: ", userShareInYoloBox);

        // Assert that the token actually arrived at YoloBox
        assertEq(weth.balanceOf(address(yoloBox)), depositAmount, "YoloBox should have received the WETH");

        _setApprovalHelper(user1Key, address(yoloBox), address(masterVault), address(weth), true);

        // Verify master contract is approved
        assertTrue(yoloBox.masterContractApproved(address(masterVault), user), "Clone contract should be approved");

        vm.stopPrank();
    }

    function test_02_borrow() public {
        console.log();
        console.log("**************** Test 02 Borrow ****************");
        console.log();

        // Determine user
        address user = vm.addr(user1Key);
        vm.startPrank(user);

        // Deposit funds to YoloBox
        uint256 depositAmount = weth.balanceOf(user1) / 2;
        _depositHelper(user1Key, address(yoloBox), address(weth), depositAmount);

        // Approvae cloneVault to spend WETH
        _setApprovalHelper(user1Key, address(yoloBox), address(masterVault), address(weth), true);

        // Amount USY
        uint256 borrowAmount = 15000 * 1e18;

        // Use cook() to transfer() -> addCollateral() -> borrow()

        _borrowHelper(user1Key, address(yoloBox), address(cloneVault), borrowAmount);

        // Assert user's wallet balance
        assertEq(usy.balanceOf(user), borrowAmount, "User should have borrowed USY");

        vm.stopPrank();
    }

    function test_03_repay() public {
        console.log();
        console.log("**************** Test 03 Repay ****************");
        console.log();

        address user = vm.addr(user1Key);

        // Step 1: Deposit collateral and borrow
        uint256 depositAmount = 500 * 1e18 / 2; // 250 ETH
        uint256 borrowAmount = 15000 * 1e18; // 15,000 USY

        vm.startPrank(user);
        _depositHelper(user1Key, address(yoloBox), address(weth), depositAmount);
        _setApprovalHelper(user1Key, address(yoloBox), address(masterVault), address(weth), true);
        (uint256 borrowPartBefore, uint256 usyBorrowedShare) =
            _borrowHelper(user1Key, address(yoloBox), address(cloneVault), borrowAmount);
        vm.stopPrank();

        // Step 2: Record initial state
        uint256 initialUserUsyShare = yoloBox.balanceOf(IERC20(address(usy)), user);
        uint256 initialVaultUsyShare = yoloBox.balanceOf(IERC20(address(usy)), address(cloneVault));
        Rebase memory totalBorrowBefore = cloneVault.totalBorrow();
        uint256 initialUserUsyWalletBalance = usy.balanceOf(user);

        console.log("Initial User USY Balance:", initialUserUsyWalletBalance);
        console.log("Initial User USY Share:", initialUserUsyShare);
        console.log("Initial Vault USY Share:", initialVaultUsyShare);
        console.log("Total Borrow Base Before:", totalBorrowBefore.base);
        console.log("Total Borrow Elastic Before:", totalBorrowBefore.elastic);
        console.log("User Borrow Part Before:", borrowPartBefore);
        console.log("User Borrow Share Before:", usyBorrowedShare);

        // Mint difference to user
        vm.startPrank(deployer);
        usy.mint(user, borrowPartBefore - initialUserUsyWalletBalance);
        vm.stopPrank();

        // Step 3: Repay the full debt using _repayHelper
        vm.startPrank(user);
        // uint256 repaidAmount = _repayHelper(user1Key, address(yoloBox), address(cloneVault), borrowPartBefore);
        usy.approve(address(yoloBox), type(uint256).max);
        yoloBox.deposit(IERC20(address(usy)), user, user, borrowPartBefore, 0);
        cloneVault.repay(user, false, borrowPartBefore);
        vm.stopPrank();

        // Step 4: Verify repayment
        uint256 afterRepayUserUsyWalletBalance = usy.balanceOf(user);
        uint256 userBorrowPartAfter = cloneVault.userBorrowPart(user);
        uint256 finalUserUsyWalletBalance = usy.balanceOf(user);
        uint256 finalUserUsyShare = yoloBox.balanceOf(IERC20(address(usy)), user);
        uint256 finalVaultUsyShare = yoloBox.balanceOf(IERC20(address(usy)), address(cloneVault));
        Rebase memory totalBorrowAfter = cloneVault.totalBorrow();

        console.log();
        console.log("After Repay User USY Balance:", afterRepayUserUsyWalletBalance);
        console.log("After Repay User USY Share:", finalUserUsyShare);
        console.log("After Repay Vault USY Share:", finalVaultUsyShare);
        console.log("Total Borrow Elastic After:", totalBorrowAfter.elastic);
        console.log("User Borrow Part After:", userBorrowPartAfter);

        assertEq(userBorrowPartAfter, 0, "User debt should be fully repaid");
        assertEq(afterRepayUserUsyWalletBalance, 0, "User USY wallet balance should be zero after repayment");
        assertEq(finalUserUsyShare, 0, "User should have no USY shares after repayment");
        assertEq(totalBorrowAfter.elastic, 0, "Total borrow elastic should be zero after full repayment");
        assertEq(totalBorrowAfter.base, 0, "Total borrow base should be zero after full repayment");
    }

    function test_04_liquidation() public {
        console.log();
        console.log("**************** Test 04 Liquidation ****************");
        console.log();

        // Step 1: Setup - User1 deposits collateral and borrows max 75% of it
        address user = vm.addr(user1Key); // Borrower
        address liquidator = vm.addr(user2Key); // Liquidator
        uint256 depositAmount = 10 * 1e18; // 10 ETH
        uint256 borrowAmount = 15_000 * 1e18; // 15,000 USY

        vm.startPrank(user);
        _depositHelper(user1Key, address(yoloBox), address(weth), depositAmount);
        _setApprovalHelper(user1Key, address(yoloBox), address(masterVault), address(weth), true);
        (uint256 borrowPartBefore, uint256 usyBorrowedShare) =
            _borrowHelper(user1Key, address(yoloBox), address(cloneVault), borrowAmount);
        vm.stopPrank();

        // Record initial state
        uint256 initialUserCollateralShare = cloneVault.userCollateralShare(user);
        uint256 initialUserBorrowPart = cloneVault.userBorrowPart(user);
        uint256 initialVaultUsyShare = yoloBox.balanceOf(IERC20(address(usy)), address(cloneVault));
        Rebase memory totalBorrowBefore = cloneVault.totalBorrow();

        console.log("Initial User Collateral Share:", initialUserCollateralShare);
        console.log("Initial User Borrow Part:", initialUserBorrowPart);
        console.log("Initial Vault USY Share:", initialVaultUsyShare);
        console.log("Total Borrow Elastic Before:", totalBorrowBefore.elastic);

        // Step 2: Make user insolvent by dropping ETH price
        uint256 initialEthPrice = INITIAL_ETH_PRCE; // Initial price: 1 ETH = 2020 USD
        uint256 newEthPrice = 2000 * 1e8; // New price: 1 ETH = 1000 USD
        vm.prank(deployer);
        MockOracle(address(oracle)).setPrice(newEthPrice); // Update oracle price

        // Verify insolvency
        (, uint256 exchangeRate) = cloneVault.updateExchangeRate();
        bool isSolvent = cloneVault.isSolvent(user);
        console.log("User Solvent After Price Drop:", isSolvent);
        assertFalse(isSolvent, "User should be insolvent after price drop");

        // Step 3: Liquidator prepares USY (debt + 1% distribution)
        uint256 debtAmount = totalBorrowBefore.toElastic(borrowPartBefore, false); // 15,007.5 * 1e18
        uint256 bonusAmount =
            debtAmount * (LIQUIDATION_MULTIPLIER - LIQUIDATION_MULTIPLIER_PRECISION) / LIQUIDATION_MULTIPLIER_PRECISION; // 1,500.75 * 1e18
        uint256 distributionAmount = bonusAmount * DISTRIBUTION_PART / DISTRIBUTION_PRECISION; // 150.075 * 1e18
        uint256 totalUsyNeeded = debtAmount + distributionAmount; // 15,157.575 * 1e18

        vm.startPrank(deployer);
        usy.mint(liquidator, totalUsyNeeded);
        vm.stopPrank();

        vm.startPrank(liquidator);
        usy.approve(address(yoloBox), type(uint256).max);
        yoloBox.deposit(IERC20(address(usy)), liquidator, liquidator, totalUsyNeeded, 0);
        _setApprovalHelper(user2Key, address(yoloBox), address(masterVault), address(usy), true);
        vm.stopPrank();

        // Step 4: Liquidate
        address[] memory users = new address[](1);
        uint256[] memory maxBorrowParts = new uint256[](1);
        users[0] = user;
        maxBorrowParts[0] = initialUserBorrowPart;

        vm.prank(liquidator);
        cloneVault.liquidate(users, maxBorrowParts, liquidator, ISwapperV2(address(0)), "");

        // Step 5: Verify
        uint256 finalUserCollateralShare = cloneVault.userCollateralShare(user);
        uint256 finalUserBorrowPart = cloneVault.userBorrowPart(user);
        uint256 finalVaultUsyShare = yoloBox.balanceOf(IERC20(address(usy)), address(cloneVault));
        uint256 liquidatorCollateralShare = yoloBox.balanceOf(IERC20(address(weth)), liquidator);
        Rebase memory totalBorrowAfter = cloneVault.totalBorrow();

        console.log("Final User Collateral Share:", finalUserCollateralShare);
        console.log("Final User Borrow Part:", finalUserBorrowPart);
        console.log("Final Vault USY Share:", finalVaultUsyShare);
        console.log("Liquidator Collateral Share:", liquidatorCollateralShare);
        console.log("Total Borrow Elastic After:", totalBorrowAfter.elastic);

        assertEq(finalUserBorrowPart, 0, "User debt should be fully repaid");
        assertEq(totalBorrowAfter.elastic, 0, "Total borrow elastic should be zero");
        assertGt(liquidatorCollateralShare, 0, "Liquidator should receive collateral");
        assertApproxEqAbs(
            finalVaultUsyShare,
            initialVaultUsyShare + yoloBox.toShare(IERC20(address(usy)), totalUsyNeeded, true),
            1e18,
            "Vault USY share should increase by repaid amount"
        );
    }
}