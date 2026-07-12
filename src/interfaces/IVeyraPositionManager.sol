// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {VeyraTypes} from "../types/VeyraTypes.sol";

/// @title IVeyraPositionManager
/// @notice Transferable ownership and lifecycle operations for Veyra positions.
interface IVeyraPositionManager {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event PositionMinted(
        uint256 indexed tokenId,
        address indexed pool,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    event LiquidityIncreased(
        uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1
    );
    event LiquidityDecreased(
        uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1
    );
    event PositionCollected(
        uint256 indexed tokenId, address indexed recipient, uint256 amount0, uint256 amount1
    );
    event PositionRebalanced(
        uint256 indexed tokenId,
        int24 previousTickLower,
        int24 previousTickUpper,
        int24 newTickLower,
        int24 newTickUpper,
        uint128 liquidity
    );

    function factory() external view returns (address);
    function nextTokenId() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function getApproved(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function positions(uint256 tokenId) external view returns (VeyraTypes.ManagedPosition memory);
    function approve(address spender, uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data)
        external;
    function mint(VeyraTypes.MintPositionParams calldata params)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    function increaseLiquidity(VeyraTypes.IncreaseLiquidityParams calldata params)
        external
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);
    function decreaseLiquidity(VeyraTypes.DecreaseLiquidityParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);
    function collect(VeyraTypes.ManagerCollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);
    function rebalance(VeyraTypes.RebalanceParams calldata params)
        external
        returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used);
    function burn(uint256 tokenId) external;
}
