// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RangeKey} from "../src/libraries/RangeKey.sol";
import {VeyraPositionManager} from "../src/periphery/VeyraPositionManager.sol";
import {VeyraTypes} from "../src/types/VeyraTypes.sol";
import {VeyraTestBase} from "./helpers/VeyraTestBase.sol";

contract PositionLifecycleTest is VeyraTestBase {
    function test_MintCreatesManagedPositionAndPoolAccounting() public {
        uint256 balance0Before = token0.balanceOf(alice);
        uint256 balance1Before = token1.balanceOf(alice);

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) =
            _mintStandardPosition(alice);

        assertEq(tokenId, 1);
        assertEq(positionManager.nextTokenId(), 2);
        assertEq(positionManager.ownerOf(tokenId), alice);
        assertEq(positionManager.balanceOf(alice), 1);
        assertGt(liquidity, 0);
        assertGt(amount0, 0);
        assertGt(amount1, 0);
        assertEq(balance0Before - token0.balanceOf(alice), amount0);
        assertEq(balance1Before - token1.balanceOf(alice), amount1);

        (VeyraTypes.ManagedPosition memory managed, VeyraTypes.PositionState memory state) =
            _poolPosition(tokenId);
        assertEq(managed.pool, address(pool));
        assertEq(managed.token0, address(token0));
        assertEq(managed.token1, address(token1));
        assertEq(managed.tickLower, TICK_LOWER);
        assertEq(managed.tickUpper, TICK_UPPER);
        assertEq(managed.liquidity, liquidity);
        assertEq(state.owner, address(positionManager));
        assertEq(state.salt, managed.salt);
        assertEq(state.liquidity, liquidity);
        assertEq(pool.liquidity(), liquidity);

        VeyraTypes.RangeState memory range = pool.rangeState(RangeKey.range(TICK_LOWER, TICK_UPPER));
        assertEq(range.liquidityGross, liquidity);
        assertEq(range.positionCount, 1);
        assertTrue(pool.tickState(TICK_LOWER).initialized);
        assertTrue(pool.tickState(TICK_UPPER).initialized);
    }

    function test_IncreaseLiquidityUpdatesManagedAndPoolBalances() public {
        (uint256 tokenId, uint128 initialLiquidity,,) = _mintStandardPosition(alice);
        uint256 balance0Before = token0.balanceOf(alice);
        uint256 balance1Before = token1.balanceOf(alice);

        (uint128 addedLiquidity, uint256 amount0, uint256 amount1) =
            _increasePosition(alice, tokenId, 25_000 ether);

        assertGt(addedLiquidity, 0);
        assertGt(amount0, 0);
        assertGt(amount1, 0);
        assertEq(balance0Before - token0.balanceOf(alice), amount0);
        assertEq(balance1Before - token1.balanceOf(alice), amount1);

        (VeyraTypes.ManagedPosition memory managed, VeyraTypes.PositionState memory state) =
            _poolPosition(tokenId);
        assertEq(managed.liquidity, initialLiquidity + addedLiquidity);
        assertEq(state.liquidity, managed.liquidity);
        assertEq(pool.liquidity(), managed.liquidity);
    }

    function test_DecreaseLiquidityReturnsUnderlyingToOwner() public {
        (uint256 tokenId, uint128 initialLiquidity,,) = _mintStandardPosition(alice);
        uint128 removedLiquidity = initialLiquidity / 2;
        uint256 balance0Before = token0.balanceOf(alice);
        uint256 balance1Before = token1.balanceOf(alice);

        (uint256 amount0, uint256 amount1) = _decreasePosition(alice, tokenId, removedLiquidity);

        assertGt(amount0, 0);
        assertGt(amount1, 0);
        assertEq(token0.balanceOf(alice) - balance0Before, amount0);
        assertEq(token1.balanceOf(alice) - balance1Before, amount1);
        VeyraTypes.ManagedPosition memory managed = positionManager.positions(tokenId);
        assertEq(managed.liquidity, initialLiquidity - removedLiquidity);
        assertEq(pool.liquidity(), initialLiquidity - removedLiquidity);
    }

    function test_CollectAndBurnCompletePositionLifecycle() public {
        (uint256 tokenId, uint128 liquidity,,) = _mintStandardPosition(alice);
        uint256 traderOutputBefore = token1.balanceOf(trader);
        uint256 amountOut = _swapToken0ForToken1(trader, 1000 ether);
        assertGt(amountOut, 0);
        assertEq(token1.balanceOf(trader) - traderOutputBefore, amountOut);
        assertGt(pool.feeGrowthGlobal0X128(), 0);

        _decreasePosition(alice, tokenId, liquidity);
        uint256 feeBalanceBefore = token0.balanceOf(alice);
        VeyraTypes.ManagerCollectParams memory collectParams = VeyraTypes.ManagerCollectParams({
            tokenId: tokenId,
            recipient: alice,
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        vm.prank(alice);
        (uint256 collected0, uint256 collected1) = positionManager.collect(collectParams);
        assertGt(collected0, 0);
        assertEq(collected1, 0);
        assertEq(token0.balanceOf(alice) - feeBalanceBefore, collected0);

        (, VeyraTypes.PositionState memory state) = _poolPosition(tokenId);
        assertEq(state.liquidity, 0);
        assertEq(state.tokensOwed0, 0);
        assertEq(state.tokensOwed1, 0);

        vm.prank(alice);
        positionManager.burn(tokenId);
        assertEq(positionManager.balanceOf(alice), 0);
        vm.expectRevert(
            abi.encodeWithSelector(VeyraPositionManager.TokenDoesNotExist.selector, tokenId)
        );
        positionManager.ownerOf(tokenId);
    }

    function test_UnauthorizedAccountCannotManagePosition() public {
        (uint256 tokenId,,,) = _mintStandardPosition(alice);
        bytes memory expected =
            abi.encodeWithSelector(VeyraPositionManager.Unauthorized.selector, tokenId, bob);

        vm.startPrank(bob);
        vm.expectRevert(expected);
        positionManager.increaseLiquidity(
            VeyraTypes.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: 1000 ether,
                amount1Desired: 1000 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: _deadline()
            })
        );
        vm.expectRevert(expected);
        positionManager.collect(
            VeyraTypes.ManagerCollectParams({
                tokenId: tokenId,
                recipient: bob,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        vm.expectRevert(expected);
        positionManager.burn(tokenId);
        vm.stopPrank();
    }

    function test_ApprovedAccountCanIncreaseAndTransferPosition() public {
        (uint256 tokenId, uint128 initialLiquidity,,) = _mintStandardPosition(alice);
        vm.prank(alice);
        positionManager.approve(bob, tokenId);
        assertEq(positionManager.getApproved(tokenId), bob);

        (uint128 addedLiquidity,,) = _increasePosition(bob, tokenId, 10_000 ether);
        assertGt(addedLiquidity, 0);
        assertEq(positionManager.positions(tokenId).liquidity, initialLiquidity + addedLiquidity);

        vm.prank(bob);
        positionManager.transferFrom(alice, bob, tokenId);
        assertEq(positionManager.ownerOf(tokenId), bob);
        assertEq(positionManager.balanceOf(alice), 0);
        assertEq(positionManager.balanceOf(bob), 1);
        assertEq(positionManager.getApproved(tokenId), address(0));
    }

    function test_OperatorApprovalAuthorizesLiquidityManagement() public {
        (uint256 tokenId, uint128 initialLiquidity,,) = _mintStandardPosition(alice);
        vm.prank(alice);
        positionManager.setApprovalForAll(bob, true);
        assertTrue(positionManager.isApprovedForAll(alice, bob));

        uint128 removal = initialLiquidity / 4;
        (uint256 amount0, uint256 amount1) = _decreasePosition(bob, tokenId, removal);
        assertGt(amount0, 0);
        assertGt(amount1, 0);
        assertEq(positionManager.positions(tokenId).liquidity, initialLiquidity - removal);
    }

    function test_BurnRequiresEmptyPosition() public {
        (uint256 tokenId, uint128 liquidity,,) = _mintStandardPosition(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                VeyraPositionManager.PositionNotEmpty.selector, liquidity, uint128(0), uint128(0)
            )
        );
        vm.prank(alice);
        positionManager.burn(tokenId);
    }

    function test_PartialDecreasesUseConservativeRounding() public {
        (uint256 aliceId,,,) = _mintStandardPosition(alice);
        (uint256 bobId,,,) = _mintStandardPosition(bob);
        uint256 fragmented0;
        uint256 fragmented1;

        for (uint256 i; i < 64; ++i) {
            (uint256 amount0, uint256 amount1) = _decreasePosition(alice, aliceId, 1);
            fragmented0 += amount0;
            fragmented1 += amount1;
        }
        (uint256 aggregate0, uint256 aggregate1) = _decreasePosition(bob, bobId, 64);

        assertLe(fragmented0, aggregate0);
        assertLe(fragmented1, aggregate1);
    }
}
