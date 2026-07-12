// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Ownable2Step
/// @notice Administrative ownership with explicit acceptance by a nominated successor.
abstract contract Ownable2Step {
    address private _owner;
    address private _pendingOwner;

    error Unauthorized(address caller);
    error InvalidOwner(address owner);
    error NotPendingOwner(address caller);

    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert InvalidOwner(initialOwner);
        _transferOwnership(initialOwner);
    }

    modifier onlyOwner() {
        if (msg.sender != _owner) revert Unauthorized(msg.sender);
        _;
    }

    function owner() public view virtual returns (address) {
        return _owner;
    }

    function pendingOwner() public view virtual returns (address) {
        return _pendingOwner;
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        if (newOwner == address(0)) revert InvalidOwner(newOwner);
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(_owner, newOwner);
    }

    function acceptOwnership() public virtual {
        if (msg.sender != _pendingOwner) revert NotPendingOwner(msg.sender);
        _transferOwnership(msg.sender);
    }

    function cancelOwnershipTransfer() public virtual onlyOwner {
        _pendingOwner = address(0);
        emit OwnershipTransferStarted(_owner, address(0));
    }

    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    function _transferOwnership(address newOwner) internal virtual {
        address previousOwner = _owner;
        _owner = newOwner;
        _pendingOwner = address(0);
        emit OwnershipTransferred(previousOwner, newOwner);
    }
}
