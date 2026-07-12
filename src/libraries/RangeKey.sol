// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title RangeKey
/// @notice Canonical token, pool, range, and position key derivation.
library RangeKey {
    error IdenticalTokens();
    error ZeroToken();
    error InvalidRange(int24 tickLower, int24 tickUpper);
    error InvalidTickSpacing(int24 tickSpacing);
    error TickNotAligned(int24 tick, int24 tickSpacing);

    function sortTokens(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1)
    {
        if (tokenA == tokenB) revert IdenticalTokens();
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert ZeroToken();
    }

    function pool(address tokenA, address tokenB, uint24 feePips) internal pure returns (bytes32) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        return keccak256(abi.encode(token0, token1, feePips));
    }

    function range(int24 tickLower, int24 tickUpper) internal pure returns (bytes32) {
        if (tickLower >= tickUpper) revert InvalidRange(tickLower, tickUpper);
        return keccak256(abi.encodePacked(tickLower, tickUpper));
    }

    /// @notice Derives a stable position identity whose range may be changed in place.
    function position(address owner, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, salt));
    }

    function validateRange(int24 tickLower, int24 tickUpper, int24 tickSpacing) internal pure {
        if (tickLower >= tickUpper) revert InvalidRange(tickLower, tickUpper);
        if (tickSpacing <= 0) revert InvalidTickSpacing(tickSpacing);
        if (tickLower % tickSpacing != 0) revert TickNotAligned(tickLower, tickSpacing);
        if (tickUpper % tickSpacing != 0) revert TickNotAligned(tickUpper, tickSpacing);
    }
}
