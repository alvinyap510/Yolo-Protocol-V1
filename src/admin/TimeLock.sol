// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title   TimeLock.sol
 * @author  0xyolodev
 * @dev     Contract to serve as the main administrator of Yolo Protocol.
 *          Provides a transparent buffer time before major changes could be
 *          made to the protocol.
 */
contract ManekiTimelock {
    /*------ CONTRACT VARIABLES ------*/
    uint256 public constant MINIMUM_DELAY = 1 days;
    uint256 public constant EXEC_PERIOD = 14 days;
    uint256 public constant MAXIMUM_DELAY = 30 days;

    mapping(address => bool) public isAdmin;
    mapping(address => bool) public pendingAdmins;
    mapping(bytes32 => bool) public queuedTransactions;

    uint256 public totalAdmins;
    uint256 public delayTime;

    /*------ EVENTS ------*/
    /**
     * @notice  Emitted when the delay time of this contract has changed.
     * @param   newDelayTime    The new delay time in seconds.
     */
    event NewDelayTime(uint256 indexed newDelayTime);

    /**
     * @notice  Emitted when a new pending administrator is being proposed.
     * @param   newPendingAdmin    The address of the proposed new administrator.
     */
    event NewPendingAdmin(address indexed newPendingAdmin);

    /**
     * @notice  Emitted when a new administrator is confirmed.
     * @param   newAdmin    The address of the new administrator.
     */
    event NewAdmin(address indexed newAdmin);

    /**
     * @notice  Emitted when an admin is revoked.
     * @param   revokedAdmin    The address of the revoked admin.
     */
    event RevokedAdmin(address indexed revokedAdmin);

    /**
     * @notice  Emitted when ether was rescued from this contract.
     */
    event EtherTransfer(address indexed to, uint256 amount);

    /**
     * @notice  Emitted when a transaction is scheduled.
     */
    event QueueTransaction(
        bytes32 indexed txHash, address indexed target, uint256 value, string signature, bytes data, uint256 eta
    );

    /**
     * @notice  Emitted when a queued transaction is canceled.
     */
    event CancelTransaction(
        bytes32 indexed txHash, address indexed target, uint256 value, string signature, bytes data, uint256 eta
    );

    /**
     * @notice  Emitted when a queued transaction is successfully executed.
     */
    event ExecuteTransaction(
        bytes32 indexed txHash, address indexed target, uint256 value, string signature, bytes data, uint256 eta
    );

    /*------ CONSTRUCTOR ------*/
    /**
     * @notice  Initializes the contract with a given admin and delay.
     * @param   _admin          The address of the initial administrator.
     * @param   _delayTime      The initial delay in seconds.
     */
    constructor(address _admin, uint256 _delayTime) {
        require(_delayTime >= MINIMUM_DELAY, "ManekiTimelock: Delay must exceed minimum delay");
        require(_delayTime <= MAXIMUM_DELAY, "ManekiTimelock: Delay must not exceed maximum delay");
        isAdmin[_admin] = true;
        totalAdmins += 1;
        delayTime = _delayTime;
    }

    /*------ FALLBACKS ------*/
    /**
     * @notice  Executed when there is no calldata in a transaction call to
     *          this contract.
     */
    receive() external payable {}

    /**
     * @notice  Executed when an undefined function is called or when there are
     *          non-empty calldata to this contract.
     */
    fallback() external payable {}

    /*------ FUNCTIONS ------*/
    /**
     * @notice  Sets new delay time for transactions.
     * @dev     Can only be called by the Timelock itself.
     * @param   _newDelayTime   The new delay time in seconds.
     */
    function setDelay(uint256 _newDelayTime) public {
        require(msg.sender == address(this), "ManekiTimelock: Set new delay call must come from timelock itself");
        require(_newDelayTime >= MINIMUM_DELAY, "ManekiTimelock: Delay must exceed minimum delay");
        require(_newDelayTime <= MAXIMUM_DELAY, "ManekiTimelock: Delay must not exceed maximum delay.");
        delayTime = _newDelayTime;

        emit NewDelayTime(delayTime);
    }

    /**
     * @notice  Proposes a new additional administrator.
     * @dev     Can only be called by the Timelock itself.
     * @param   _pendingAdmin   Address of the new pending admin.
     */
    function setPendingAdmin(address _pendingAdmin) public {
        require(
            msg.sender == address(this), "ManekiTimelock: Set new pending admin call must come from timelock itself"
        );
        pendingAdmins[_pendingAdmin] = true;

        emit NewPendingAdmin(_pendingAdmin);
    }

    /**
     * @notice  Pending admin accepts the role of administrator.
     * @dev     Can only be called by the pending admin.
     */
    function acceptAdmin() public {
        require(pendingAdmins[msg.sender], "ManekiTimelock: Only a pending admin can accept admin role");
        isAdmin[msg.sender] = true;
        totalAdmins += 1;
        pendingAdmins[msg.sender] = false;

        emit NewAdmin(msg.sender);
    }

    /**
     * @notice  An admin address revokes its own admin rights.
     * @dev     Can only be called by an admin.
     */
    function selfRevokeAdmin() public {
        require(isAdmin[msg.sender], "ManekiTimelock: Only an admin can call selfRevokeAdmin function");
        require(totalAdmins - 1 > 0, "ManekiTimelock: Timelock contract must at least have 1 admin");
        isAdmin[msg.sender] = false;
        totalAdmins -= 1;
        emit RevokedAdmin(msg.sender);
    }

    /**
     * @notice  Schedules a transaction.
     * @dev     Can only be called by an admin.
     * @param   target      The target address for the transaction.
     * @param   value       The ether value (in wei) to be transferred.
     * @param   signature   The function signature to be called.
     * @param   data        The calldata to be passed.
     * @param   eta         The scheduled time for the transaction to execute.
     * @return  txHash      The hash of the scheduled transaction.
     */
    function queueTransaction(address target, uint256 value, string memory signature, bytes memory data, uint256 eta)
        public
        returns (bytes32)
    {
        require(isAdmin[msg.sender], "ManekiTimelock: Only an admin can queue transactions");
        require(eta >= getBlockTimestamp() + delayTime, "ManekiTimelock: Estimated execution block must satisfy delay.");
        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        queuedTransactions[txHash] = true;

        emit QueueTransaction(txHash, target, value, signature, data, eta);
        return txHash;
    }

    /**
     * @notice  Cancels a queued transaction.
     * @dev     Can only be called by an admin.
     * @param   target      The target address for the transaction.
     * @param   value       The ether value (in wei) to be transferred.
     * @param   signature   The function signature to be called.
     * @param   data        The calldata to be passed.
     * @param   eta         The scheduled time for the transaction to execute.
     */
    function cancelTransaction(address target, uint256 value, string memory signature, bytes memory data, uint256 eta)
        public
    {
        require(isAdmin[msg.sender], "ManekiTimelock: Only an admin can cancel transactions");

        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        queuedTransactions[txHash] = false;

        emit CancelTransaction(txHash, target, value, signature, data, eta);
    }

    /**
     * @notice  Executes a queued transaction.
     * @dev     Can only be called by an admin.
     * @param   target      The target contract address of the transaction.
     * @param   value       The ether value (in wei) involved.
     * @param   signature   The function signature intended to be called.
     * @param   data        The calldata to be sent.
     * @param   eta         The timestamp at which the transaction was originally scheduled to be executed.
     * @return  returnData  Return data after the successful function call.
     */
    function executeTransaction(address target, uint256 value, string memory signature, bytes memory data, uint256 eta)
        public
        payable
        returns (bytes memory)
    {
        require(isAdmin[msg.sender], "ManekiTimelock: Only an admin can execute transactions");
        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        require(queuedTransactions[txHash], "ManekiTimelock: Transaction wasn't queued");
        require(getBlockTimestamp() >= eta, "ManekiTimelock: Transaction hasn't surpassed time lock.");
        require(getBlockTimestamp() <= eta + EXEC_PERIOD, "ManekiTimelock: Transaction is stale.");

        queuedTransactions[txHash] = false;

        bytes memory callData;

        if (bytes(signature).length == 0) {
            callData = data;
        } else {
            callData = abi.encodePacked(bytes4(keccak256(bytes(signature))), data);
        }

        (bool success, bytes memory returnData) = target.call{value: value}(callData);
        require(success, "ManekiTimelock: Transaction execution reverted");

        emit ExecuteTransaction(txHash, target, value, signature, data, eta);

        return returnData;
    }

    /**
     * @notice  Sends ether of the contract to another address.
     *          Used to save ether that was unintendedly sent here.
     * @dev     Can only be called by an admin.
     * @param   _to         Address to receive the ether.
     * @param   _amount     Amount of ether to send.
     */
    function transferEther(address payable _to, uint256 _amount) public {
        require(isAdmin[msg.sender], "ManekiTimelock: Only admin can send ethers of time lock contract");
        require(address(this).balance >= _amount, "ManekiTimelock: Insufficient ether balance");

        (bool success,) = _to.call{value: _amount}("");
        require(success, "ManekiTimelock: Ether transfer failed");

        emit EtherTransfer(_to, _amount);
    }

    /*------ INTERNAL FUNCTIONS ------*/
    /**
     * @dev     Internal helper function to get the current block timestamp.
     * @return  timestamp   The current block UNIX timestamp.
     */
    function getBlockTimestamp() internal view returns (uint256 timestamp) {
        return block.timestamp;
    }
}
