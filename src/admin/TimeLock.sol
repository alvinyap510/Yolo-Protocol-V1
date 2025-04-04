// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title   TimeLock.sol
 * @author  0xyolodev
 * @dev     Contract to serve as the main administrator of Yolo Protocol.
 *          Provides a transparent buffer time before major changes could be
 *          made to the protocol.
 */
contract TimeLock {
    // ******************************** //
    // *** CONSTANTS AND IMMUTABLES *** //
    // ******************************** //

    // CONSTANTS
    uint256 public constant MINIMUM_DELAY = 1 days;
    uint256 public constant MAXIMUM_DELAY = 30 days;
    uint256 public constant EXEC_PERIOD = 14 days;

    // ***************************//
    // *** CONTRACT VARIABLES *** //
    // ************************** //

    mapping(address => bool) public isAdmin;
    mapping(address => bool) public pendingAdmins;
    mapping(bytes32 => bool) public queuedTransactions;

    uint256 public totalAdmins;
    uint256 public delayTime;

    // ************** //
    // *** EVENTS *** //
    // ************** //

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

    // ************** //
    // *** ERRORS *** //
    // ************** //
    error ErrorInvalidDelayTime(uint256 delayTime);
    error ErrorCallerNotTimeLock();
    error ErrorCallerNotPendingAdmin();
    error ErrorCallerNotAdmin();
    error ErrorZeroAdmin();
    error ErrorInvalidEta(uint256 eta, uint256 minEta);
    error ErrorTxNotQueued(bytes32 txHash);
    error ErrorTxNotReady(uint256 currentTime, uint256 eta);
    error ErrorTxStale(uint256 currentTime, uint256 expiry);
    error ErrorInsufficientEther(uint256 balance, uint256 requested);
    error ErrorTxExecutionFailed();
    error ErrorEtherTransferFailed();

    // ***************** //
    // *** MODIFIERS *** //
    // ***************** //

    modifier onlyTimeLock() {
        if (msg.sender != address(this)) revert ErrorCallerNotTimeLock();
        _;
    }

    // ******************* //
    // *** CONSTRUCTOR *** //
    // ******************* //

    /**
     * @notice  Initializes the contract with a given admin and delay.
     * @param   _admin          The address of the initial administrator.
     * @param   _delayTime      The initial delay in seconds.
     */
    constructor(address _admin, uint256 _delayTime) {
        // Guard Clause
        if (_delayTime < MINIMUM_DELAY || _delayTime > MAXIMUM_DELAY) revert ErrorInvalidDelayTime(_delayTime);

        isAdmin[_admin] = true;
        totalAdmins += 1;
        delayTime = _delayTime;
    }

    // ************************ //
    // *** PUBLIC FUNCTIONS *** //
    // ************************ //

    /**
     * @notice  Sets new delay time for transactions.
     * @dev     Can only be called by the Timelock itself.
     * @param   _newDelayTime   The new delay time in seconds.
     */
    function setDelay(uint256 _newDelayTime) public onlyTimeLock {
        // Guard Clause
        if (_newDelayTime < MINIMUM_DELAY || _newDelayTime > MAXIMUM_DELAY) revert ErrorInvalidDelayTime(_newDelayTime);

        delayTime = _newDelayTime;
        emit NewDelayTime(delayTime);
    }

    /**
     * @notice  Proposes a new additional administrator.
     * @dev     Can only be called by the Timelock itself.
     * @param   _pendingAdmin   Address of the new pending admin.
     */
    function setPendingAdmin(address _pendingAdmin) public onlyTimeLock {
        pendingAdmins[_pendingAdmin] = true;
        emit NewPendingAdmin(_pendingAdmin);
    }

    /**
     * @notice  Pending admin accepts the role of administrator.
     * @dev     Can only be called by the pending admin.
     */
    function acceptAdmin() public {
        // Guard Clause
        if (!pendingAdmins[msg.sender]) revert ErrorCallerNotPendingAdmin();

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
        // Guard Clause
        if (!isAdmin[msg.sender]) revert ErrorCallerNotAdmin();
        if (totalAdmins <= 1) revert ErrorZeroAdmin();

        isAdmin[msg.sender] = false;
        totalAdmins -= 1;
        emit RevokedAdmin(msg.sender);
    }

    /**
     * @notice  Schedules a transaction.
     * @dev     Can only be called by an admin.
     * @param   _target      The target address for the transaction.
     * @param   _value       The ether value (in wei) to be transferred.
     * @param   _signature   The function signature to be called.
     * @param   _data        The calldata to be passed.
     * @param   _eta         The scheduled time for the transaction to execute.
     * @return  txHash      The hash of the scheduled transaction.
     */
    function queueTransaction(
        address _target,
        uint256 _value,
        string memory _signature,
        bytes memory _data,
        uint256 _eta
    ) public returns (bytes32) {
        // Guard Clause
        if (!isAdmin[msg.sender]) revert ErrorCallerNotAdmin();
        if (_eta < getBlockTimestamp() + delayTime) revert ErrorInvalidEta(_eta, getBlockTimestamp() + delayTime);

        bytes32 txHash = keccak256(abi.encode(_target, _value, _signature, _data, _eta));
        queuedTransactions[txHash] = true;

        emit QueueTransaction(txHash, _target, _value, _signature, _data, _eta);
        return txHash;
    }

    /**
     * @notice  Cancels a queued transaction.
     * @dev     Can only be called by an admin.
     * @param   _target      The target address for the transaction.
     * @param   _value       The ether value (in wei) to be transferred.
     * @param   _signature   The function signature to be called.
     * @param   _data        The calldata to be passed.
     * @param   _eta         The scheduled time for the transaction to execute.
     */
    function cancelTransaction(
        address _target,
        uint256 _value,
        string memory _signature,
        bytes memory _data,
        uint256 _eta
    ) public {
        // Guard Clause
        if (!isAdmin[msg.sender]) revert ErrorCallerNotAdmin();

        bytes32 txHash = keccak256(abi.encode(_target, _value, _signature, _data, _eta));
        queuedTransactions[txHash] = false;

        emit CancelTransaction(txHash, _target, _value, _signature, _data, _eta);
    }

    /**
     * @notice  Executes a queued transaction.
     * @dev     Can only be called by an admin.
     * @param   _target     The target contract address of the transaction.
     * @param   _value       The ether value (in wei) involved.
     * @param   _signature   The function signature intended to be called.
     * @param   _data        The calldata to be sent.
     * @param   _eta         The timestamp at which the transaction was originally scheduled to be executed.
     * @return  returnData  Return data after the successful function call.
     */
    function executeTransaction(
        address _target,
        uint256 _value,
        string memory _signature,
        bytes memory _data,
        uint256 _eta
    ) public payable returns (bytes memory) {
        // Guard Clause
        if (!isAdmin[msg.sender]) revert ErrorCallerNotAdmin();

        bytes32 txHash = keccak256(abi.encode(_target, _value, _signature, _data, _eta));

        if (!queuedTransactions[txHash]) revert ErrorTxNotQueued(txHash);
        if (getBlockTimestamp() < _eta) revert ErrorTxNotReady(getBlockTimestamp(), _eta);
        if (getBlockTimestamp() > _eta + EXEC_PERIOD) revert ErrorTxStale(getBlockTimestamp(), _eta + EXEC_PERIOD);

        queuedTransactions[txHash] = false;

        bytes memory callData;

        if (bytes(_signature).length == 0) {
            callData = _data;
        } else {
            callData = abi.encodePacked(bytes4(keccak256(bytes(_signature))), _data);
        }

        (bool success, bytes memory returnData) = _target.call{value: _value}(callData);
        if (!success) revert ErrorTxExecutionFailed();

        emit ExecuteTransaction(txHash, _target, _value, _signature, _data, _eta);

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
        // Guard Clause
        if (!isAdmin[msg.sender]) revert ErrorCallerNotAdmin();
        if (address(this).balance < _amount) revert ErrorInsufficientEther(address(this).balance, _amount);

        (bool success,) = _to.call{value: _amount}("");
        if (!success) revert ErrorEtherTransferFailed();

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

    // ************************** //
    // *** RECEIVE & FALLBACK *** //
    // ************************** //

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
}
