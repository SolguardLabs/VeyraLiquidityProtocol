// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IVeyraMintCallback
/// @notice Implemented by callers that add liquidity directly through a Veyra pool.
interface IVeyraMintCallback {
    /// @notice Pays the token amounts required by a liquidity modification.
    /// @dev The pool verifies its balances after this callback returns.
    function veyraMintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data)
        external;
}
