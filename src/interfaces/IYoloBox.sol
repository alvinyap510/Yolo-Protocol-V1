// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@yolo/contracts/interfaces/IFlashBorrower.sol";
import "@yolo/contracts/interfaces/IStrategy.sol";
import {Rebase} from "@BoringSolidity/RebaseLibrary.sol";

interface IYoloBox {
    function balanceOf(IERC20, address) external view returns (uint256);

    function batch(bytes[] calldata calls, bool revertOnFail)
        external
        payable
        returns (bool[] memory successes, bytes[] memory results);

    function batchFlashLoan(
        IFlashBorrower borrower,
        address[] calldata receivers,
        IERC20[] calldata tokens,
        uint256[] calldata amounts,
        bytes calldata data
    ) external;

    function claimOwnership() external;

    function flashLoan(IFlashBorrower borrower, address receiver, IERC20 token, uint256 amount, bytes calldata data)
        external;

    function deploy(address masterContract, bytes calldata data, bool useCreate2) external payable returns (address);

    function deposit(IERC20 token_, address from, address to, uint256 amount, uint256 share)
        external
        payable
        returns (uint256 amountOut, uint256 shareOut);

    function harvest(IERC20 token, bool balance, uint256 maxChangeAmount) external;

    function masterContractApproved(address, address) external view returns (bool);

    function masterContractOf(address) external view returns (address);

    function nonces(address) external view returns (uint256);

    function owner() external view returns (address);

    function pendingOwner() external view returns (address);

    function pendingStrategy(IERC20) external view returns (IStrategy);

    function permitToken(
        IERC20 token,
        address from,
        address to,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function registerProtocol() external;

    function setMasterContractApproval(
        address user,
        address masterContract,
        bool approved,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function setStrategy(IERC20 token, IStrategy newStrategy) external;

    function setStrategyTargetPercentage(IERC20 token, uint64 targetPercentage_) external;

    function strategy(IERC20) external view returns (IStrategy);

    function strategyData(IERC20)
        external
        view
        returns (uint64 strategyStartDate, uint64 targetPercentage, uint128 balance);

    function toAmount(IERC20 token, uint256 share, bool roundUp) external view returns (uint256 amount);

    function toShare(IERC20 token, uint256 amount, bool roundUp) external view returns (uint256 share);

    function totals(IERC20) external view returns (Rebase memory totals_);

    function transfer(IERC20 token, address from, address to, uint256 share) external;

    function transferMultiple(IERC20 token, address from, address[] calldata tos, uint256[] calldata shares) external;

    function transferOwnership(address newOwner, bool direct, bool renounce) external;

    function whitelistMasterContract(address masterContract, bool approved) external;

    function whitelistedMasterContracts(address) external view returns (bool);

    function withdraw(IERC20 token_, address from, address to, uint256 amount, uint256 share)
        external
        returns (uint256 amountOut, uint256 shareOut);
}
