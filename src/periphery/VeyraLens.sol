// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IVeyraFactory} from "../interfaces/IVeyraFactory.sol";
import {IVeyraLens} from "../interfaces/IVeyraLens.sol";
import {IVeyraPool} from "../interfaces/IVeyraPool.sol";
import {IVeyraPositionManager} from "../interfaces/IVeyraPositionManager.sol";
import {FeeMath} from "../libraries/FeeMath.sol";
import {LiquidityMath} from "../libraries/LiquidityMath.sol";
import {PriceMath} from "../libraries/PriceMath.sol";
import {RangeKey} from "../libraries/RangeKey.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {VeyraTypes} from "../types/VeyraTypes.sol";
import {VeyraQuoteMath} from "./VeyraQuoter.sol";

/// @title VeyraLens
/// @notice Aggregates pool and position state for off-chain clients.
contract VeyraLens is IVeyraLens {
    using SafeTransferLib for address;

    error ZeroAddress();
    error UnknownPool(address pool);
    error AmountTooLarge();

    address public immutable factory;

    constructor(address factory_) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    function poolSnapshot(address pool)
        external
        view
        override
        returns (VeyraTypes.PoolSnapshot memory snapshot)
    {
        IVeyraPool market = _pool(pool);
        VeyraTypes.PoolKey memory key = market.poolKey();
        snapshot = VeyraTypes.PoolSnapshot({
            key: key,
            slot0: market.slot0(),
            liquidity: market.liquidity(),
            feeGrowthGlobal0X128: market.feeGrowthGlobal0X128(),
            feeGrowthGlobal1X128: market.feeGrowthGlobal1X128(),
            protocolFees: market.protocolFees(),
            balance0: key.token0.safeBalanceOf(pool),
            balance1: key.token1.safeBalanceOf(pool)
        });
    }

    function rangeSnapshot(address pool, int24 tickLower, int24 tickUpper)
        external
        view
        override
        returns (VeyraTypes.RangeSnapshot memory snapshot)
    {
        IVeyraPool market = _pool(pool);
        RangeKey.validateRange(tickLower, tickUpper, market.tickSpacing());
        (uint256 growth0, uint256 growth1) = market.feeGrowthInside(tickLower, tickUpper);
        snapshot = VeyraTypes.RangeSnapshot({
            tickLower: tickLower,
            tickUpper: tickUpper,
            lower: market.tickState(tickLower),
            upper: market.tickState(tickUpper),
            state: market.rangeState(RangeKey.range(tickLower, tickUpper)),
            feeGrowthInside0X128: growth0,
            feeGrowthInside1X128: growth1
        });
    }

    function positionSnapshot(
        address pool,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) external view override returns (VeyraTypes.PositionSnapshot memory snapshot) {
        IVeyraPool market = _pool(pool);
        bytes32 key = market.positionKey(owner, salt);
        VeyraTypes.PositionState memory state = market.positionState(key);
        snapshot.key = key;
        snapshot.state = state;
        if (state.owner == address(0)) return snapshot;

        (uint256 growth0, uint256 growth1) =
            market.feeGrowthInside(state.tickLower, state.tickUpper);
        snapshot.accrued0 =
            FeeMath.accrued(state.liquidity, growth0, state.feeGrowthInside0LastX128);
        snapshot.accrued1 =
            FeeMath.accrued(state.liquidity, growth1, state.feeGrowthInside1LastX128);
        (snapshot.amount0, snapshot.amount1) =
            _amounts(market, state.tickLower, state.tickUpper, state.liquidity);

        if (tickLower != state.tickLower || tickUpper != state.tickUpper) {
            snapshot.amount0 = 0;
            snapshot.amount1 = 0;
        }
    }

    function managedPosition(address manager, uint256 tokenId)
        external
        view
        override
        returns (VeyraTypes.ManagedPosition memory position, address owner)
    {
        if (manager == address(0)) revert ZeroAddress();
        position = IVeyraPositionManager(manager).positions(tokenId);
        owner = IVeyraPositionManager(manager).ownerOf(tokenId);
    }

    function quoteExactInputSingle(
        address pool,
        bool zeroForOne,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external view override returns (VeyraTypes.QuoteResult memory quote) {
        _pool(pool);
        if (amountIn > uint256(type(int256).max)) revert AmountTooLarge();
        return VeyraQuoteMath.quote(pool, zeroForOne, int256(amountIn), sqrtPriceLimitX96);
    }

    function quoteExactOutputSingle(
        address pool,
        bool zeroForOne,
        uint256 amountOut,
        uint160 sqrtPriceLimitX96
    ) external view override returns (VeyraTypes.QuoteResult memory quote) {
        _pool(pool);
        if (amountOut > uint256(type(int256).max)) revert AmountTooLarge();
        return VeyraQuoteMath.quote(pool, zeroForOne, -int256(amountOut), sqrtPriceLimitX96);
    }

    function amountsForLiquidity(address pool, int24 tickLower, int24 tickUpper, uint128 liquidity)
        external
        view
        override
        returns (uint256 amount0, uint256 amount1)
    {
        return _amounts(_pool(pool), tickLower, tickUpper, liquidity);
    }

    function liquidityForAmounts(
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) external view override returns (uint128 liquidity) {
        IVeyraPool market = _pool(pool);
        RangeKey.validateRange(tickLower, tickUpper, market.tickSpacing());
        return LiquidityMath.liquidityForAmounts(
            market.slot0().sqrtPriceX96,
            PriceMath.getSqrtPriceAtTick(tickLower),
            PriceMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
    }

    function _amounts(IVeyraPool market, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        RangeKey.validateRange(tickLower, tickUpper, market.tickSpacing());
        return LiquidityMath.amountsForLiquidity(
            market.slot0().sqrtPriceX96,
            PriceMath.getSqrtPriceAtTick(tickLower),
            PriceMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );
    }

    function _pool(address pool) internal view returns (IVeyraPool market) {
        if (pool == address(0)) revert UnknownPool(pool);
        market = IVeyraPool(pool);
        if (
            IVeyraFactory(factory).getPool(market.token0(), market.token1(), market.feePips())
                != pool
        ) {
            revert UnknownPool(pool);
        }
    }
}
