// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title FixedPoint128
/// @notice Constants for unsigned Q128 fixed-point accounting.
library FixedPoint128 {
    uint256 internal constant Q128 = 1 << 128;
    uint256 internal constant RESOLUTION = 128;
}
