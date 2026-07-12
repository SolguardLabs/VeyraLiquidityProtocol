// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IVeyraPool} from "../src/interfaces/IVeyraPool.sol";
import {PriceMath} from "../src/libraries/PriceMath.sol";
import {VeyraPositionManager} from "../src/periphery/VeyraPositionManager.sol";
import {VeyraTypes} from "../src/types/VeyraTypes.sol";
import {VeyraTestBase} from "./helpers/VeyraTestBase.sol";

contract RebalanceLifecycleTest is VeyraTestBase {
    function test_RebalanceMovesPositionWhilePreservingTokenOwnership() public {
        (uint256 tokenId,,,) = _mintStandardPosition(alice);

        vm.prank(alice);
        (uint128 newLiquidity, uint256 amount0Used, uint256 amount1Used) = positionManager.rebalance(
            VeyraTypes.RebalanceParams({
                tokenId: tokenId,
                newTickLower: -300,
                newTickUpper: 300,
                zeroForOne: true,
                amountIn: 0,
                sqrtPriceLimitX96: 0,
                amount0Min: 0,
                amount1Min: 0,
                deadline: _deadline()
            })
        );

        (VeyraTypes.ManagedPosition memory managed, VeyraTypes.PositionState memory state) =
            _poolPosition(tokenId);
        assertEq(positionManager.ownerOf(tokenId), alice);
        assertEq(managed.tickLower, -300);
        assertEq(managed.tickUpper, 300);
        assertEq(managed.liquidity, newLiquidity);
        assertEq(state.tickLower, -300);
        assertEq(state.tickUpper, 300);
        assertEq(state.liquidity, newLiquidity);
        assertFalse(state.transitioning);
        assertGt(amount0Used, 0);
        assertGt(amount1Used, 0);
    }

    function test_RebalanceCanNormalizeInventoryThroughPoolSwap() public {
        _mintStandardPosition(bob);
        (uint256 tokenId,,,) = _mintStandardPosition(alice);
        uint256 growthBefore = pool.feeGrowthGlobal1X128();

        vm.prank(alice);
        (uint128 newLiquidity, uint256 amount0Used, uint256 amount1Used) = positionManager.rebalance(
            VeyraTypes.RebalanceParams({
                tokenId: tokenId,
                newTickLower: 120,
                newTickUpper: 600,
                zeroForOne: false,
                amountIn: 5000 ether,
                sqrtPriceLimitX96: PriceMath.getSqrtPriceAtTick(540),
                amount0Min: 1,
                amount1Min: 0,
                deadline: _deadline()
            })
        );

        VeyraTypes.ManagedPosition memory managed = positionManager.positions(tokenId);
        assertEq(managed.tickLower, 120);
        assertEq(managed.tickUpper, 600);
        assertEq(managed.liquidity, newLiquidity);
        assertGt(amount0Used, 0);
        assertEq(amount1Used, 0);
        assertGt(pool.feeGrowthGlobal1X128(), growthBefore);
    }

    function test_RebalanceUpdatesOldAndNewRangeTotals() public {
        (uint256 tokenId, uint128 oldLiquidity,,) = _mintStandardPosition(alice);
        bytes32 oldRange = keccak256(abi.encodePacked(TICK_LOWER, TICK_UPPER));
        assertEq(pool.rangeState(oldRange).liquidityGross, oldLiquidity);

        vm.prank(alice);
        (uint128 newLiquidity,,) = positionManager.rebalance(
            VeyraTypes.RebalanceParams({
                tokenId: tokenId,
                newTickLower: -300,
                newTickUpper: 300,
                zeroForOne: true,
                amountIn: 0,
                sqrtPriceLimitX96: 0,
                amount0Min: 0,
                amount1Min: 0,
                deadline: _deadline()
            })
        );

        bytes32 newRange = keccak256(abi.encodePacked(int24(-300), int24(300)));
        assertEq(pool.rangeState(oldRange).liquidityGross, 0);
        assertEq(pool.rangeState(newRange).liquidityGross, newLiquidity);
    }

    function test_RebalanceRejectsUnapprovedCaller() public {
        (uint256 tokenId,,,) = _mintStandardPosition(alice);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(VeyraPositionManager.Unauthorized.selector, tokenId, bob)
        );
        positionManager.rebalance(
            VeyraTypes.RebalanceParams({
                tokenId: tokenId,
                newTickLower: -300,
                newTickUpper: 300,
                zeroForOne: true,
                amountIn: 0,
                sqrtPriceLimitX96: 0,
                amount0Min: 0,
                amount1Min: 0,
                deadline: _deadline()
            })
        );
    }

    function test_RebalanceRespectsMinimumAmounts() public {
        (uint256 tokenId,,,) = _mintStandardPosition(alice);
        vm.prank(alice);
        vm.expectPartialRevert(VeyraPositionManager.AmountBelowMinimum.selector);
        positionManager.rebalance(
            VeyraTypes.RebalanceParams({
                tokenId: tokenId,
                newTickLower: -300,
                newTickUpper: 300,
                zeroForOne: true,
                amountIn: 0,
                sqrtPriceLimitX96: 0,
                amount0Min: type(uint128).max,
                amount1Min: type(uint128).max,
                deadline: _deadline()
            })
        );
    }
}
