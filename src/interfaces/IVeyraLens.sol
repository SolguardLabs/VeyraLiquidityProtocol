// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {VeyraTypes} from "../types/VeyraTypes.sol";

/// @title IVeyraLens
/// @notice Aggregated read-only views for integrations and monitoring systems.
interface IVeyraLens {
    function poolSnapshot(address pool)
        external
        view
        returns (VeyraTypes.PoolSnapshot memory snapshot);
    function rangeSnapshot(address pool, int24 tickLower, int24 tickUpper)
        external
        view
        returns (VeyraTypes.RangeSnapshot memory snapshot);
    function positionSnapshot(
        address pool,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) external view returns (VeyraTypes.PositionSnapshot memory snapshot);
    function managedPosition(address manager, uint256 tokenId)
        external
        view
        returns (VeyraTypes.ManagedPosition memory position, address owner);
    function quoteExactInputSingle(
        address pool,
        bool zeroForOne,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external view returns (VeyraTypes.QuoteResult memory quote);
    function quoteExactOutputSingle(
        address pool,
        bool zeroForOne,
        uint256 amountOut,
        uint160 sqrtPriceLimitX96
    ) external view returns (VeyraTypes.QuoteResult memory quote);
    function amountsForLiquidity(address pool, int24 tickLower, int24 tickUpper, uint128 liquidity)
        external
        view
        returns (uint256 amount0, uint256 amount1);
    function liquidityForAmounts(
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) external view returns (uint128 liquidity);
}
