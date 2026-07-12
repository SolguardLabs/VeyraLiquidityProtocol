// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FullMath} from "./FullMath.sol";

/// @title PriceMath
/// @notice Tick conversion and square-root-price movement in Q64.96 format.
library PriceMath {
    int24 internal constant MIN_TICK = -887_272;
    int24 internal constant MAX_TICK = 887_272;
    uint160 internal constant MIN_SQRT_PRICE_X96 = 4_295_128_739;
    uint160 internal constant MAX_SQRT_PRICE_X96 =
        1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;
    uint256 internal constant Q96 = 1 << 96;

    error TickOutOfBounds(int24 tick);
    error SqrtPriceOutOfBounds(uint160 sqrtPriceX96);
    error InvalidPriceOrLiquidity();
    error PriceMovementOverflow();

    function getSqrtPriceAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        if (absTick > uint256(uint24(MAX_TICK))) revert TickOutOfBounds(tick);
        uint256 ratio = absTick & 1 != 0
            ? 0xfffcb933bd6fad37aa2d162d1a594001
            : 0x100000000000000000000000000000000;
        if (absTick & 2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 16 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 32 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 64 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 128 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 256 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 512 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 1024 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 2048 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 4096 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 8192 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 16_384 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 32_768 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 65_536 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 131_072 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 262_144 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 524_288 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;
        if (tick > 0) ratio = type(uint256).max / ratio;
        sqrtPriceX96 = uint160((ratio >> 32) + (ratio & 0xffffffff == 0 ? 0 : 1));
    }

    function getTickAtSqrtPrice(uint160 sqrtPriceX96) internal pure returns (int24 tick) {
        if (sqrtPriceX96 < MIN_SQRT_PRICE_X96 || sqrtPriceX96 >= MAX_SQRT_PRICE_X96) {
            revert SqrtPriceOutOfBounds(sqrtPriceX96);
        }
        int24 low = MIN_TICK;
        int24 high = MAX_TICK;
        while (low < high) {
            int24 middle = int24(int256(low) + ((int256(high) - int256(low) + 1) / 2));
            if (getSqrtPriceAtTick(middle) <= sqrtPriceX96) low = middle;
            else high = middle - 1;
        }
        tick = low;
    }

    function floorToSpacing(int24 tick, int24 tickSpacing) internal pure returns (int24 aligned) {
        if (tickSpacing <= 0) revert TickOutOfBounds(tickSpacing);
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) --compressed;
        aligned = compressed * tickSpacing;
    }

    function nextSqrtPriceFromInput(
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint256 amountIn,
        bool zeroForOne
    ) internal pure returns (uint160) {
        if (sqrtPriceX96 == 0 || liquidity == 0) revert InvalidPriceOrLiquidity();
        return zeroForOne
            ? _nextFromAmount0(sqrtPriceX96, liquidity, amountIn, true)
            : _nextFromAmount1(sqrtPriceX96, liquidity, amountIn, true);
    }

    function nextSqrtPriceFromOutput(
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint256 amountOut,
        bool zeroForOne
    ) internal pure returns (uint160) {
        if (sqrtPriceX96 == 0 || liquidity == 0) {
            revert InvalidPriceOrLiquidity();
        }
        return zeroForOne
            ? _nextFromAmount1(sqrtPriceX96, liquidity, amountOut, false)
            : _nextFromAmount0(sqrtPriceX96, liquidity, amountOut, false);
    }

    function _nextFromAmount0(uint160 sqrtPriceX96, uint128 liquidity, uint256 amount, bool add)
        private
        pure
        returns (uint160 result)
    {
        if (amount == 0) return sqrtPriceX96;
        uint256 numerator = uint256(liquidity) << 96;
        if (add) {
            unchecked {
                uint256 productAdded = amount * uint256(sqrtPriceX96);
                if (productAdded / amount == sqrtPriceX96) {
                    uint256 denominator = numerator + productAdded;
                    if (denominator >= numerator) {
                        return
                            _toUint160(
                                FullMath.mulDivRoundingUp(numerator, sqrtPriceX96, denominator)
                            );
                    }
                }
            }
            return _toUint160(FullMath.ceilDiv(numerator, (numerator / sqrtPriceX96) + amount));
        }
        uint256 productRemoved = amount * uint256(sqrtPriceX96);
        if (productRemoved / amount != sqrtPriceX96 || productRemoved >= numerator) {
            revert PriceMovementOverflow();
        }
        result = _toUint160(
            FullMath.mulDivRoundingUp(numerator, sqrtPriceX96, numerator - productRemoved)
        );
    }

    function _nextFromAmount1(uint160 sqrtPriceX96, uint128 liquidity, uint256 amount, bool add)
        private
        pure
        returns (uint160 result)
    {
        uint256 quotient = add
            ? FullMath.mulDiv(amount, Q96, liquidity)
            : FullMath.mulDivRoundingUp(amount, Q96, liquidity);
        if (add) {
            uint256 next = uint256(sqrtPriceX96) + quotient;
            if (next > type(uint160).max) revert PriceMovementOverflow();
            result = uint160(next);
        } else {
            if (quotient >= sqrtPriceX96) revert PriceMovementOverflow();
            result = uint160(uint256(sqrtPriceX96) - quotient);
        }
    }

    function _toUint160(uint256 value) private pure returns (uint160) {
        if (value > type(uint160).max) revert PriceMovementOverflow();
        return uint160(value);
    }
}
