// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FullMath} from "./FullMath.sol";

/// @title LiquidityMath
/// @notice Liquidity changes and token amounts for Q64.96 price intervals.
library LiquidityMath {
    uint256 internal constant Q96 = 1 << 96;

    error LiquidityUnderflow();
    error LiquidityOverflow();
    error InvalidPriceRange();

    function addDelta(uint128 liquidity, int128 delta) internal pure returns (uint128 updated) {
        if (delta < 0) {
            uint128 decrease = uint128(uint256(-int256(delta)));
            if (decrease > liquidity) revert LiquidityUnderflow();
            updated = liquidity - decrease;
        } else {
            uint256 sum = uint256(liquidity) + uint128(delta);
            if (sum > type(uint128).max) revert LiquidityOverflow();
            updated = uint128(sum);
        }
    }

    function amount0Delta(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity,
        bool roundUp
    ) internal pure returns (uint256 amount0) {
        (uint160 lower, uint160 upper) = _sort(sqrtPriceAX96, sqrtPriceBX96);
        if (lower == 0) revert InvalidPriceRange();
        uint256 numerator = uint256(liquidity) << 96;
        uint256 difference = uint256(upper) - lower;
        amount0 = roundUp
            ? FullMath.ceilDiv(FullMath.mulDivRoundingUp(numerator, difference, upper), lower)
            : FullMath.mulDiv(numerator, difference, upper) / lower;
    }

    function amount1Delta(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity,
        bool roundUp
    ) internal pure returns (uint256 amount1) {
        (uint160 lower, uint160 upper) = _sort(sqrtPriceAX96, sqrtPriceBX96);
        uint256 difference = uint256(upper) - lower;
        amount1 = roundUp
            ? FullMath.mulDivRoundingUp(liquidity, difference, Q96)
            : FullMath.mulDiv(liquidity, difference, Q96);
    }

    function liquidityForAmount0(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount0)
        internal
        pure
        returns (uint128)
    {
        (uint160 lower, uint160 upper) = _sort(sqrtPriceAX96, sqrtPriceBX96);
        if (lower == 0 || lower == upper) revert InvalidPriceRange();
        uint256 intermediate = FullMath.mulDiv(lower, upper, Q96);
        return _toUint128(FullMath.mulDiv(amount0, intermediate, uint256(upper) - lower));
    }

    function liquidityForAmount1(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount1)
        internal
        pure
        returns (uint128)
    {
        (uint160 lower, uint160 upper) = _sort(sqrtPriceAX96, sqrtPriceBX96);
        if (lower == upper) revert InvalidPriceRange();
        return _toUint128(FullMath.mulDiv(amount1, Q96, uint256(upper) - lower));
    }

    function liquidityForAmounts(
        uint160 currentSqrtPriceX96,
        uint160 lowerSqrtPriceX96,
        uint160 upperSqrtPriceX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 result) {
        if (lowerSqrtPriceX96 >= upperSqrtPriceX96) revert InvalidPriceRange();
        if (currentSqrtPriceX96 <= lowerSqrtPriceX96) {
            return liquidityForAmount0(lowerSqrtPriceX96, upperSqrtPriceX96, amount0);
        }
        if (currentSqrtPriceX96 < upperSqrtPriceX96) {
            uint128 from0 = liquidityForAmount0(currentSqrtPriceX96, upperSqrtPriceX96, amount0);
            uint128 from1 = liquidityForAmount1(lowerSqrtPriceX96, currentSqrtPriceX96, amount1);
            return from0 < from1 ? from0 : from1;
        }
        result = liquidityForAmount1(lowerSqrtPriceX96, upperSqrtPriceX96, amount1);
    }

    function amountsForLiquidity(
        uint160 currentSqrtPriceX96,
        uint160 lowerSqrtPriceX96,
        uint160 upperSqrtPriceX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (lowerSqrtPriceX96 >= upperSqrtPriceX96) revert InvalidPriceRange();
        if (currentSqrtPriceX96 <= lowerSqrtPriceX96) {
            amount0 = amount0Delta(lowerSqrtPriceX96, upperSqrtPriceX96, liquidity, true);
        } else if (currentSqrtPriceX96 < upperSqrtPriceX96) {
            amount0 = amount0Delta(currentSqrtPriceX96, upperSqrtPriceX96, liquidity, true);
            amount1 = amount1Delta(lowerSqrtPriceX96, currentSqrtPriceX96, liquidity, true);
        } else {
            amount1 = amount1Delta(lowerSqrtPriceX96, upperSqrtPriceX96, liquidity, true);
        }
    }

    function _sort(uint160 a, uint160 b) private pure returns (uint160 lower, uint160 upper) {
        (lower, upper) = a < b ? (a, b) : (b, a);
    }

    function _toUint128(uint256 value) private pure returns (uint128) {
        if (value > type(uint128).max) revert LiquidityOverflow();
        return uint128(value);
    }
}
