// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FixedPoint128} from "./FixedPoint128.sol";
import {FullMath} from "./FullMath.sol";

/// @title FeeMath
/// @notice Swap-fee and Q128 fee-growth calculations using parts per million.
library FeeMath {
    uint24 internal constant FEE_DENOMINATOR = 1_000_000;

    error InvalidFeePips(uint24 feePips);
    error NoActiveLiquidity();
    error FeeAmountOverflow();

    function validate(uint24 feePips) internal pure {
        if (feePips >= FEE_DENOMINATOR) revert InvalidFeePips(feePips);
    }

    /// @notice Calculates a fraction of an amount, rounded down.
    function feeAmount(uint256 amount, uint24 feePips) internal pure returns (uint256) {
        validate(feePips);
        return FullMath.mulDiv(amount, feePips, FEE_DENOMINATOR);
    }

    /// @notice Calculates a fraction of an amount, rounded up.
    function feeAmountRoundingUp(uint256 amount, uint24 feePips) internal pure returns (uint256) {
        validate(feePips);
        return FullMath.mulDivRoundingUp(amount, feePips, FEE_DENOMINATOR);
    }

    /// @notice Calculates the fee added on top of a net swap input.
    function feeFromNetInput(uint256 netAmount, uint24 feePips) internal pure returns (uint256) {
        validate(feePips);
        return FullMath.mulDivRoundingUp(netAmount, feePips, FEE_DENOMINATOR - feePips);
    }

    /// @notice Removes the fee portion from a gross exact-input amount.
    function netInput(uint256 grossAmount, uint24 feePips) internal pure returns (uint256) {
        validate(feePips);
        return FullMath.mulDiv(grossAmount, FEE_DENOMINATOR - feePips, FEE_DENOMINATOR);
    }

    /// @notice Splits swap fees between protocol reserves and liquidity providers.
    function split(uint256 totalFee, uint24 protocolFeePips)
        internal
        pure
        returns (uint256 protocolFee, uint256 liquidityProviderFee)
    {
        validate(protocolFeePips);
        protocolFee = FullMath.mulDiv(totalFee, protocolFeePips, FEE_DENOMINATOR);
        liquidityProviderFee = totalFee - protocolFee;
    }

    /// @notice Converts collected fees into a Q128 growth increment per unit of liquidity.
    function growthIncrement(uint256 fee, uint128 activeLiquidity) internal pure returns (uint256) {
        if (activeLiquidity == 0) revert NoActiveLiquidity();
        return FullMath.mulDiv(fee, FixedPoint128.Q128, activeLiquidity);
    }

    /// @notice Calculates position fees accrued between two Q128 growth checkpoints.
    /// @dev Fee-growth accumulators are permitted to wrap modulo 2^256.
    function accrued(
        uint128 positionLiquidity,
        uint256 currentGrowthX128,
        uint256 previousGrowthX128
    ) internal pure returns (uint256 amount) {
        uint256 delta;
        unchecked {
            delta = currentGrowthX128 - previousGrowthX128;
        }
        amount = FullMath.mulDiv(positionLiquidity, delta, FixedPoint128.Q128);
    }

    /// @notice Adds a newly accrued amount to a compact uint128 claim balance.
    function addOwed(uint128 currentOwed, uint256 accruedAmount)
        internal
        pure
        returns (uint128 updated)
    {
        uint256 sum = uint256(currentOwed) + accruedAmount;
        if (sum > type(uint128).max) revert FeeAmountOverflow();
        updated = uint128(sum);
    }
}
