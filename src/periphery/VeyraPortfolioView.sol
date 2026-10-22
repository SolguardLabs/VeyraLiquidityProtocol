// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IVeyraLens} from "../interfaces/IVeyraLens.sol";
import {IVeyraPositionManager} from "../interfaces/IVeyraPositionManager.sol";
import {VeyraTypes} from "../types/VeyraTypes.sol";

/// @title VeyraPortfolioView
/// @notice Combines NFT ownership and pool snapshots for read-only client batches.
contract VeyraPortfolioView {
    IVeyraPositionManager public immutable manager;
    IVeyraLens public immutable lens;

    struct PositionView {
        uint256 tokenId;
        address owner;
        address pool;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        uint256 fees0;
        uint256 fees1;
    }

    error ZeroAddress();

    constructor(IVeyraPositionManager manager_, IVeyraLens lens_) {
        if (address(manager_) == address(0) || address(lens_) == address(0)) revert ZeroAddress();
        manager = manager_;
        lens = lens_;
    }

    function position(uint256 tokenId) public view returns (PositionView memory result) {
        VeyraTypes.ManagedPosition memory managed = manager.positions(tokenId);
        VeyraTypes.PositionSnapshot memory snapshot = lens.positionSnapshot(
            managed.pool, address(manager), managed.tickLower, managed.tickUpper, managed.salt
        );
        result = PositionView({
            tokenId: tokenId,
            owner: manager.ownerOf(tokenId),
            pool: managed.pool,
            tickLower: managed.tickLower,
            tickUpper: managed.tickUpper,
            liquidity: managed.liquidity,
            amount0: snapshot.amount0,
            amount1: snapshot.amount1,
            fees0: uint256(snapshot.state.tokensOwed0) + snapshot.accrued0,
            fees1: uint256(snapshot.state.tokensOwed1) + snapshot.accrued1
        });
    }

    /// @dev Integrators should paginate large ID sets to stay within RPC limits.
    function batch(uint256[] calldata tokenIds)
        external
        view
        returns (PositionView[] memory results)
    {
        results = new PositionView[](tokenIds.length);
        for (uint256 i; i < tokenIds.length; ++i) {
            results[i] = position(tokenIds[i]);
        }
    }
}
