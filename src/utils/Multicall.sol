// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Multicall
/// @notice Batches non-payable calls while preserving the original caller.
abstract contract Multicall {
    function multicall(bytes[] calldata calls) external returns (bytes[] memory results) {
        results = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            (bool success, bytes memory result) = address(this).delegatecall(calls[i]);
            if (!success) _revert(result);
            results[i] = result;
        }
    }

    function _revert(bytes memory reason) private pure {
        assembly ("memory-safe") {
            revert(add(reason, 0x20), mload(reason))
        }
    }
}
