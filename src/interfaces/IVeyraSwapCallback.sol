// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IVeyraSwapCallback
/// @notice Implemented by callers that execute swaps directly through a Veyra pool.
interface IVeyraSwapCallback {
    /// @notice Pays whichever positive delta is owed to the calling pool.
    /// @dev A negative delta denotes tokens already sent by the pool.
    function veyraSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data)
        external;
}
