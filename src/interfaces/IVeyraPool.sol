// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {VeyraTypes} from "../types/VeyraTypes.sol";

/// @title IVeyraPool
/// @notice Core interface for one concentrated-liquidity token pair and fee tier.
interface IVeyraPool {
    event Initialized(uint160 sqrtPriceX96, int24 tick);
    event LiquidityModified(
        bytes32 indexed positionKey,
        address indexed owner,
        int24 indexed tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        int256 amount0,
        int256 amount1
    );
    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );
    event FeesCollected(
        bytes32 indexed positionKey, address indexed recipient, uint128 amount0, uint128 amount1
    );
    event Donated(address indexed sender, uint256 amount0, uint256 amount1);
    event ProtocolFeeUpdated(uint24 protocolFeePips);
    event ProtocolFeesCollected(address indexed recipient, uint128 amount0, uint128 amount1);

    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function feePips() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function poolKey() external view returns (VeyraTypes.PoolKey memory);
    function slot0() external view returns (VeyraTypes.Slot0 memory);
    function liquidity() external view returns (uint128);
    function feeGrowthGlobal0X128() external view returns (uint256);
    function feeGrowthGlobal1X128() external view returns (uint256);
    function protocolFees() external view returns (VeyraTypes.ProtocolFees memory);
    function tickState(int24 tick) external view returns (VeyraTypes.TickState memory);
    function rangeState(bytes32 key) external view returns (VeyraTypes.RangeState memory);
    function positionState(bytes32 key) external view returns (VeyraTypes.PositionState memory);
    function positionKey(address owner, bytes32 salt) external pure returns (bytes32);
    function feeGrowthInside(int24 tickLower, int24 tickUpper)
        external
        view
        returns (uint256 growth0X128, uint256 growth1X128);
    function initialize(uint160 sqrtPriceX96) external;
    function modifyLiquidity(VeyraTypes.ModifyLiquidityParams calldata params, bytes calldata data)
        external
        returns (VeyraTypes.BalanceDelta memory delta);
    function releaseForRebalance(bytes32 key, address recipient)
        external
        returns (uint128 releasedLiquidity, uint256 amount0, uint256 amount1);
    function commitRebalance(
        bytes32 key,
        int24 newTickLower,
        int24 newTickUpper,
        uint128 liquidityDesired,
        bytes calldata data
    ) external returns (VeyraTypes.BalanceDelta memory delta);
    function collect(VeyraTypes.CollectParams calldata params)
        external
        returns (uint128 amount0, uint128 amount1);
    function swap(VeyraTypes.SwapParams calldata params, bytes calldata data)
        external
        returns (VeyraTypes.BalanceDelta memory delta);
    function donate(uint256 amount0, uint256 amount1, bytes calldata data) external;
    function setProtocolFee(uint24 protocolFeePips) external;
    function collectProtocolFees(
        address recipient,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external returns (uint128 amount0, uint128 amount1);
}
