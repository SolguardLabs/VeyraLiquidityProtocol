// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IVeyraFactory
/// @notice Registry and deployment authority for canonical Veyra pools.
interface IVeyraFactory {
    event PoolCreated(
        address indexed token0,
        address indexed token1,
        uint24 indexed feePips,
        int24 tickSpacing,
        address pool
    );
    event FeeTierEnabled(uint24 indexed feePips, int24 tickSpacing);
    event ProtocolFeeRecipientUpdated(
        address indexed previousRecipient, address indexed newRecipient
    );
    event PoolProtocolFeeUpdated(address indexed pool, uint24 protocolFeePips);

    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function protocolFeeRecipient() external view returns (address);
    function feeAmountTickSpacing(uint24 feePips) external view returns (int24);
    function getPool(address tokenA, address tokenB, uint24 feePips) external view returns (address);
    function allPools(uint256 index) external view returns (address);
    function allPoolsLength() external view returns (uint256);
    function createPool(address tokenA, address tokenB, uint24 feePips, uint160 initialSqrtPriceX96)
        external
        returns (address pool);
    function enableFeeTier(uint24 feePips, int24 tickSpacing) external;
    function setProtocolFeeRecipient(address recipient) external;
    function setPoolProtocolFee(address pool, uint24 protocolFeePips) external;
}
