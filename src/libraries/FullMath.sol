// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title FullMath
/// @notice Full-precision multiplication and division for protocol accounting.
library FullMath {
    error DivisionByZero();
    error MulDivOverflow();

    /// @notice Calculates floor(a * b / denominator) with 512-bit intermediate precision.
    function mulDiv(uint256 a, uint256 b, uint256 denominator)
        internal
        pure
        returns (uint256 result)
    {
        uint256 prod0;
        uint256 prod1;
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            prod0 := mul(a, b)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }

        if (prod1 == 0) {
            if (denominator == 0) revert DivisionByZero();
            return prod0 / denominator;
        }
        if (denominator <= prod1) {
            if (denominator == 0) revert DivisionByZero();
            revert MulDivOverflow();
        }

        uint256 remainder;
        assembly ("memory-safe") {
            remainder := mulmod(a, b, denominator)
            prod1 := sub(prod1, gt(remainder, prod0))
            prod0 := sub(prod0, remainder)
        }

        uint256 twos = denominator & (~denominator + 1);
        assembly ("memory-safe") {
            denominator := div(denominator, twos)
            prod0 := div(prod0, twos)
            twos := add(div(sub(0, twos), twos), 1)
        }
        unchecked {
            prod0 |= prod1 * twos;

            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            result = prod0 * inverse;
        }
    }

    /// @notice Calculates ceil(a * b / denominator) with full intermediate precision.
    function mulDivRoundingUp(uint256 a, uint256 b, uint256 denominator)
        internal
        pure
        returns (uint256 result)
    {
        result = mulDiv(a, b, denominator);
        if (mulmod(a, b, denominator) != 0) {
            if (result == type(uint256).max) revert MulDivOverflow();
            unchecked {
                ++result;
            }
        }
    }

    /// @notice Calculates ceil(numerator / denominator).
    function ceilDiv(uint256 numerator, uint256 denominator)
        internal
        pure
        returns (uint256 result)
    {
        if (denominator == 0) revert DivisionByZero();
        if (numerator == 0) return 0;
        unchecked {
            result = ((numerator - 1) / denominator) + 1;
        }
    }
}
