// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@BoringSolidity/RebaseLibrary.sol";
import "@yolo/contracts/interfaces/IYoloBox.sol";
import "@yolo/contracts/interfaces/IOracle.sol";
import "@yolo/contracts/interfaces/ISwapperV2.sol";

/**
 * @title IYoloVault
 * @notice Interface for interacting with YoloVault contracts
 */
interface IYoloVault {
    // ***************** //
    // *** DATATYPES *** //
    // ***************** //

    struct BorrowCap {
        uint128 total;
        uint128 borrowPartPerAddress;
    }

    struct AccrueInfo {
        uint64 lastAccrued;
        uint128 feesEarned;
        uint64 INTEREST_PER_SECOND;
    }

    struct CookStatus {
        bool needsSolvencyCheck;
        bool hasAccrued;
    }

    // ************** //
    // *** EVENTS *** //
    // ************** //

    event LogAccrue(uint128 accruedAmount);
    event LogExchangeRate(uint256 rate);
    event LogAddCollateral(address indexed from, address indexed receiver, uint256 share);
    event LogRemoveCollateral(address indexed from, address indexed receiver, uint256 share);
    event LogBorrow(address indexed from, address indexed receiver, uint256 amount, uint256 part);
    event LogRepay(address indexed from, address indexed to, uint256 amount, uint256 part);
    event LogLiquidation(
        address indexed from,
        address indexed user,
        address indexed to,
        uint256 collateralShare,
        uint256 borrowAmount,
        uint256 borrowPart
    );
    event LogInterestChange(uint64 oldInterestRate, uint64 newInterestRate);
    event LogChangeBorrowLimit(uint128 newLimit, uint128 perAddressPart);
    event LogChangeBlacklistedCallee(address indexed account, bool blacklisted);
    event LogLiquidationMultiplierChanged(uint256 previous, uint256 current);
    event LogBorrowOpeningFeeChanged(uint256 previous, uint256 current);
    event LogCollateralizationRateChanged(uint256 previous, uint256 current);
    event LogFeeTo(address indexed newFeeTo);
    event LogWithdrawFees(address indexed feeTo, uint256 feesEarnedFraction);

    // ************************ //
    // *** VIEW FUNCTIONS *** //
    // ************************ //

    function yoloBox() external view returns (IYoloBox);
    function masterContract() external view returns (IYoloVault);
    function yoloUsd() external view returns (IERC20);
    function blacklistedCallees(address) external view returns (bool);
    function feeTo() external view returns (address);
    function COLLATERIZATION_RATE() external view returns (uint256);
    function LIQUIDATION_MULTIPLIER() external view returns (uint256);
    function BORROW_OPENING_FEE() external view returns (uint256);
    function collateral() external view returns (IERC20);
    function oracle() external view returns (IOracle);
    function oracleData() external view returns (bytes memory);
    function borrowLimit() external view returns (BorrowCap memory);
    function accrueInfo() external view returns (AccrueInfo memory);
    function exchangeRate() external view returns (uint256);
    function totalCollateralShare() external view returns (uint256);
    function totalBorrow() external view returns (Rebase memory);
    function userCollateralShare(address) external view returns (uint256);
    function userBorrowPart(address) external view returns (uint256);
    function isSolvent(address _user) external view returns (bool);
    function owner() external view returns (address);

    // ************************ //
    // *** PUBLIC FUNCTIONS *** //
    // ************************ //

    function init(bytes calldata data) external payable;
    function accrue() external;
    function updateExchangeRate() external returns (bool _isUpdated, uint256 _rate);
    function withdrawFees() external;
    function addCollateral(address to, bool skim, uint256 share) external;
    function removeCollateral(address to, uint256 share) external;
    function borrow(address to, uint256 amount) external returns (uint256 part, uint256 share);
    function repay(address to, bool skim, uint256 part) external returns (uint256 amount);
    function liquidate(
        address[] memory users,
        uint256[] memory maxBorrowParts,
        address to,
        ISwapperV2 swapper,
        bytes memory swapperData
    ) external;

    // ********************* //
    // *** CONFIGURATION *** //
    // ********************* //

    function changeInterestRate(uint64 newInterestRate) external;
    function changeBorrowLimit(uint128 newBorrowLimit, uint128 perAddressPart) external;
    function setBlacklistedCallee(address callee, bool blacklisted) external;
    function setLiquidationMultiplier(uint256 liquidationMultiplier) external;
    function setBorrowOpeningFee(uint256 borrowOpeningFee) external;
    function setCollateralizationRate(uint256 collateralizationRate) external;
    function setFeeTo(address newFeeTo) external;
    function reduceSupply(uint256 amount) external;
    function cook(
        uint8[] calldata actions,
        uint256[] calldata values,
        bytes[] calldata datas
    ) external payable returns (uint256 value1, uint256 value2);
}