// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title VeyraTypes
/// @notice Shared value types used by Veyra pools and their periphery contracts.
library VeyraTypes {
    /// @notice Immutable identity and market configuration for a pool.
    struct PoolKey {
        address token0;
        address token1;
        uint24 feePips;
        int24 tickSpacing;
    }

    /// @notice Compact state required to price swaps against the active range.
    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
        uint24 protocolFeePips;
        bool unlocked;
    }

    /// @notice Protocol fees retained by a pool until withdrawal by the factory owner.
    struct ProtocolFees {
        uint128 token0;
        uint128 token1;
    }

    /// @notice Accounting stored for one initialized tick boundary.
    struct TickState {
        uint128 liquidityGross;
        int128 liquidityNet;
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
        bool initialized;
    }

    /// @notice Cached accounting for one half-open liquidity range.
    struct RangeState {
        uint128 liquidityGross;
        uint32 positionCount;
        uint64 lastSyncedBlock;
        uint256 feeGrowthInside0X128;
        uint256 feeGrowthInside1X128;
    }

    /// @notice Accounting stored for one owner, range, and caller-supplied salt.
    struct PositionState {
        address owner;
        bytes32 salt;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
        uint64 transitionBlock;
        bool transitioning;
    }

    /// @notice Signed token movement from the perspective of a pool.
    /// @dev Positive values are owed to the pool and negative values are sent by it.
    struct BalanceDelta {
        int256 amount0;
        int256 amount1;
    }

    /// @notice Parameters for adding liquidity to or removing it from a position.
    struct ModifyLiquidityParams {
        address owner;
        int24 tickLower;
        int24 tickUpper;
        int128 liquidityDelta;
        bytes32 salt;
    }

    /// @notice Parameters for a swap executed directly against one pool.
    struct SwapParams {
        address recipient;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Parameters for collecting settled fees from a pool position.
    struct CollectParams {
        address owner;
        address recipient;
        int24 tickLower;
        int24 tickUpper;
        uint128 amount0Requested;
        uint128 amount1Requested;
        bytes32 salt;
    }

    /// @notice Aggregate pool state suitable for user interfaces and monitoring.
    struct PoolSnapshot {
        PoolKey key;
        Slot0 slot0;
        uint128 liquidity;
        uint256 feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128;
        ProtocolFees protocolFees;
        uint256 balance0;
        uint256 balance1;
    }

    /// @notice Range state paired with its current fee-growth-inside values.
    struct RangeSnapshot {
        int24 tickLower;
        int24 tickUpper;
        TickState lower;
        TickState upper;
        RangeState state;
        uint256 feeGrowthInside0X128;
        uint256 feeGrowthInside1X128;
    }

    /// @notice Position state paired with its currently accrued, uncheckpointed fees.
    struct PositionSnapshot {
        bytes32 key;
        PositionState state;
        uint256 accrued0;
        uint256 accrued1;
        uint256 amount0;
        uint256 amount1;
    }

    /// @notice Parameters for creating a managed liquidity position.
    struct MintPositionParams {
        address token0;
        address token1;
        uint24 feePips;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    /// @notice Parameters for adding funds to an existing managed position.
    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /// @notice Parameters for removing liquidity from a managed position.
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /// @notice Parameters for collecting proceeds from a managed position.
    struct ManagerCollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    /// @notice Parameters for moving a managed position to a new half-open range.
    struct RebalanceParams {
        uint256 tokenId;
        int24 newTickLower;
        int24 newTickUpper;
        bool zeroForOne;
        uint256 amountIn;
        uint160 sqrtPriceLimitX96;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /// @notice Metadata maintained by the position manager for an issued token.
    struct ManagedPosition {
        address pool;
        address token0;
        address token1;
        uint24 feePips;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bytes32 salt;
    }

    /// @notice Parameters for an exact-input single-pool router swap.
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 feePips;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Parameters for an exact-output single-pool router swap.
    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 feePips;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Quote returned by read-only swap simulation.
    struct QuoteResult {
        uint256 amountIn;
        uint256 amountOut;
        uint160 sqrtPriceAfterX96;
        int24 tickAfter;
        uint128 liquidityAfter;
        uint256 feeAmount;
    }
}
