// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FeeMath} from "./FeeMath.sol";
import {LiquidityMath} from "./LiquidityMath.sol";
import {PriceMath} from "./PriceMath.sol";

/// @title SwapMath
/// @notice Computes one swap step between the current price and a target tick price.
library SwapMath {
    error InvalidAmountSpecified();

    function computeSwapStep(
        uint160 currentSqrtPriceX96,
        uint160 targetSqrtPriceX96,
        uint128 liquidity,
        int256 amountRemaining,
        uint24 feePips
    )
        internal
        pure
        returns (uint160 nextSqrtPriceX96, uint256 amountIn, uint256 amountOut, uint256 feeAmount)
    {
        if (amountRemaining == 0) revert InvalidAmountSpecified();
        FeeMath.validate(feePips);
        bool zeroForOne = currentSqrtPriceX96 >= targetSqrtPriceX96;
        bool exactInput = amountRemaining > 0;
        uint256 remaining = exactInput ? uint256(amountRemaining) : _absolute(amountRemaining);

        if (exactInput) {
            uint256 available = FeeMath.netInput(remaining, feePips);
            amountIn = zeroForOne
                ? LiquidityMath.amount0Delta(
                    targetSqrtPriceX96, currentSqrtPriceX96, liquidity, true
                )
                : LiquidityMath.amount1Delta(
                    currentSqrtPriceX96, targetSqrtPriceX96, liquidity, true
                );
            nextSqrtPriceX96 = available >= amountIn
                ? targetSqrtPriceX96
                : PriceMath.nextSqrtPriceFromInput(
                    currentSqrtPriceX96, liquidity, available, zeroForOne
                );
        } else {
            amountOut = zeroForOne
                ? LiquidityMath.amount1Delta(
                    targetSqrtPriceX96, currentSqrtPriceX96, liquidity, false
                )
                : LiquidityMath.amount0Delta(
                    currentSqrtPriceX96, targetSqrtPriceX96, liquidity, false
                );
            nextSqrtPriceX96 = remaining >= amountOut
                ? targetSqrtPriceX96
                : PriceMath.nextSqrtPriceFromOutput(
                    currentSqrtPriceX96, liquidity, remaining, zeroForOne
                );
        }

        bool reachedTarget = nextSqrtPriceX96 == targetSqrtPriceX96;
        if (zeroForOne) {
            if (!(reachedTarget && exactInput)) {
                amountIn = LiquidityMath.amount0Delta(
                    nextSqrtPriceX96, currentSqrtPriceX96, liquidity, true
                );
            }
            if (!(reachedTarget && !exactInput)) {
                amountOut = LiquidityMath.amount1Delta(
                    nextSqrtPriceX96, currentSqrtPriceX96, liquidity, false
                );
            }
        } else {
            if (!(reachedTarget && exactInput)) {
                amountIn = LiquidityMath.amount1Delta(
                    currentSqrtPriceX96, nextSqrtPriceX96, liquidity, true
                );
            }
            if (!(reachedTarget && !exactInput)) {
                amountOut = LiquidityMath.amount0Delta(
                    currentSqrtPriceX96, nextSqrtPriceX96, liquidity, false
                );
            }
        }
        if (!exactInput && amountOut > remaining) amountOut = remaining;
        feeAmount = exactInput && !reachedTarget
            ? remaining - amountIn
            : FeeMath.feeFromNetInput(amountIn, feePips);
    }

    function _absolute(int256 value) private pure returns (uint256) {
        unchecked {
            return uint256(-(value + 1)) + 1;
        }
    }
}
