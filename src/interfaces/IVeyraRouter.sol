// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {VeyraTypes} from "../types/VeyraTypes.sol";

/// @title IVeyraRouter
/// @notice User-facing execution interface for single-pool Veyra swaps.
interface IVeyraRouter {
    function factory() external view returns (address);
    function exactInputSingle(VeyraTypes.ExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut);
    function exactOutputSingle(VeyraTypes.ExactOutputSingleParams calldata params)
        external
        returns (uint256 amountIn);
}
