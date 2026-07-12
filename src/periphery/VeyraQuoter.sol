// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IVeyraFactory} from "../interfaces/IVeyraFactory.sol";
import {IVeyraPool} from "../interfaces/IVeyraPool.sol";
import {LiquidityMath} from "../libraries/LiquidityMath.sol";
import {PriceMath} from "../libraries/PriceMath.sol";
import {SwapMath} from "../libraries/SwapMath.sol";
import {VeyraTypes} from "../types/VeyraTypes.sol";

/// @notice Read-only swap simulation shared by the quoter and lens.
library VeyraQuoteMath {
    error InvalidAmount();
    error InvalidPriceLimit(uint160 currentPriceX96, uint160 limitPriceX96);
    error NoLiquidity();
    error QuoteDidNotProgress();
    error ArithmeticOverflow();

    struct State {
        uint160 priceX96;
        int24 tick;
        uint128 liquidity;
        int256 remaining;
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeAmount;
    }

    function quote(address pool, bool zeroForOne, int256 amountSpecified, uint160 requestedLimitX96)
        internal
        view
        returns (VeyraTypes.QuoteResult memory result)
    {
        if (amountSpecified == 0) revert InvalidAmount();
        IVeyraPool market = IVeyraPool(pool);
        VeyraTypes.Slot0 memory slot = market.slot0();
        State memory state = State({
            priceX96: slot.sqrtPriceX96,
            tick: slot.tick,
            liquidity: market.liquidity(),
            remaining: amountSpecified,
            amountIn: 0,
            amountOut: 0,
            feeAmount: 0
        });
        if (state.liquidity == 0) revert NoLiquidity();

        uint160 limitX96 = _priceLimit(state.priceX96, zeroForOne, requestedLimitX96);
        int24 spacing = market.tickSpacing();
        while (state.remaining != 0 && state.priceX96 != limitX96 && state.liquidity != 0) {
            (bool initialized, int24 nextTick) =
                _nextInitializedTick(market, state.tick, spacing, zeroForOne, limitX96);
            uint160 boundaryX96;
            uint160 targetX96 = limitX96;
            if (initialized) {
                boundaryX96 = PriceMath.getSqrtPriceAtTick(nextTick);
                if (zeroForOne ? boundaryX96 > limitX96 : boundaryX96 < limitX96) {
                    targetX96 = boundaryX96;
                }
            }
            if (targetX96 == state.priceX96) {
                if (!initialized) break;
                _cross(state, market.tickState(nextTick), nextTick, zeroForOne);
                continue;
            }

            (uint160 nextPriceX96, uint256 amountIn, uint256 amountOut, uint256 feeAmount) = SwapMath.computeSwapStep(
                state.priceX96, targetX96, state.liquidity, state.remaining, market.feePips()
            );
            if (nextPriceX96 == state.priceX96 && amountIn == 0 && amountOut == 0) {
                revert QuoteDidNotProgress();
            }

            uint256 grossInput = amountIn + feeAmount;
            state.amountIn += grossInput;
            state.amountOut += amountOut;
            state.feeAmount += feeAmount;
            if (amountSpecified > 0) {
                state.remaining -= _toInt256(grossInput);
                if (state.remaining < 0) state.remaining = 0;
            } else {
                state.remaining += _toInt256(amountOut);
                if (state.remaining > 0) state.remaining = 0;
            }

            state.priceX96 = nextPriceX96;
            if (initialized && nextPriceX96 == boundaryX96) {
                _cross(state, market.tickState(nextTick), nextTick, zeroForOne);
            } else {
                state.tick = PriceMath.getTickAtSqrtPrice(nextPriceX96);
            }
        }
        if (state.amountIn == 0 || state.amountOut == 0) revert QuoteDidNotProgress();
        result = VeyraTypes.QuoteResult({
            amountIn: state.amountIn,
            amountOut: state.amountOut,
            sqrtPriceAfterX96: state.priceX96,
            tickAfter: state.tick,
            liquidityAfter: state.liquidity,
            feeAmount: state.feeAmount
        });
    }

    function _nextInitializedTick(
        IVeyraPool pool,
        int24 currentTick,
        int24 spacing,
        bool zeroForOne,
        uint160 limitX96
    ) private view returns (bool found, int24 nextTick) {
        int256 cursor = PriceMath.floorToSpacing(currentTick, spacing);
        if (!zeroForOne) cursor += spacing;
        int256 step = zeroForOne ? -int256(spacing) : int256(spacing);
        while (cursor >= PriceMath.MIN_TICK && cursor <= PriceMath.MAX_TICK) {
            int24 candidate = int24(cursor);
            uint160 boundaryX96 = PriceMath.getSqrtPriceAtTick(candidate);
            if (zeroForOne ? boundaryX96 < limitX96 : boundaryX96 > limitX96) return (false, 0);
            if (pool.tickState(candidate).initialized) return (true, candidate);
            cursor += step;
        }
    }

    function _cross(
        State memory state,
        VeyraTypes.TickState memory tickState,
        int24 nextTick,
        bool zeroForOne
    ) private pure {
        int128 liquidityDelta = tickState.liquidityNet;
        if (zeroForOne) liquidityDelta = -liquidityDelta;
        state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityDelta);
        state.tick = zeroForOne ? nextTick - 1 : nextTick;
    }

    function _priceLimit(uint160 current, bool zeroForOne, uint160 requested)
        private
        pure
        returns (uint160 limit)
    {
        limit = requested;
        if (limit == 0) {
            limit = zeroForOne ? PriceMath.MIN_SQRT_PRICE_X96 + 1 : PriceMath.MAX_SQRT_PRICE_X96 - 1;
        }
        if (
            (zeroForOne && (limit >= current || limit <= PriceMath.MIN_SQRT_PRICE_X96))
                || (!zeroForOne && (limit <= current || limit >= PriceMath.MAX_SQRT_PRICE_X96))
        ) {
            revert InvalidPriceLimit(current, limit);
        }
    }

    function _toInt256(uint256 value) private pure returns (int256) {
        if (value > uint256(type(int256).max)) revert ArithmeticOverflow();
        return int256(value);
    }
}

/// @title VeyraQuoter
/// @notice Computes single-pool swap outcomes without changing pool state.
contract VeyraQuoter {
    error ZeroAddress();
    error UnknownPool(address pool);
    error AmountTooLarge();

    address public immutable factory;

    constructor(address factory_) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    function quoteExactInputSingle(
        address pool,
        bool zeroForOne,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external view returns (VeyraTypes.QuoteResult memory) {
        _validatePool(pool);
        if (amountIn > uint256(type(int256).max)) revert AmountTooLarge();
        return VeyraQuoteMath.quote(pool, zeroForOne, int256(amountIn), sqrtPriceLimitX96);
    }

    function quoteExactOutputSingle(
        address pool,
        bool zeroForOne,
        uint256 amountOut,
        uint160 sqrtPriceLimitX96
    ) external view returns (VeyraTypes.QuoteResult memory) {
        _validatePool(pool);
        if (amountOut > uint256(type(int256).max)) revert AmountTooLarge();
        return VeyraQuoteMath.quote(pool, zeroForOne, -int256(amountOut), sqrtPriceLimitX96);
    }

    function _validatePool(address pool) internal view {
        if (pool == address(0)) revert UnknownPool(pool);
        IVeyraPool market = IVeyraPool(pool);
        if (
            IVeyraFactory(factory).getPool(market.token0(), market.token1(), market.feePips())
                != pool
        ) {
            revert UnknownPool(pool);
        }
    }
}

