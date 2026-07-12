// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {PriceMath} from "../src/libraries/PriceMath.sol";
import {VeyraLens} from "../src/periphery/VeyraLens.sol";
import {VeyraQuoter} from "../src/periphery/VeyraQuoter.sol";
import {VeyraTypes} from "../src/types/VeyraTypes.sol";
import {VeyraTestBase} from "./helpers/VeyraTestBase.sol";

contract ViewsAndQuotesTest is VeyraTestBase {
    VeyraQuoter internal quoter;
    VeyraLens internal lens;

    function setUp() public override {
        super.setUp();
        quoter = new VeyraQuoter(address(factory));
        lens = new VeyraLens(address(factory));
    }

    function test_PoolSnapshotReportsBalancesAndMarketConfiguration() public {
        _mintStandardPosition(alice);

        VeyraTypes.PoolSnapshot memory snapshot = lens.poolSnapshot(address(pool));
        assertEq(snapshot.key.token0, address(token0));
        assertEq(snapshot.key.token1, address(token1));
        assertEq(snapshot.key.feePips, FEE_PIPS);
        assertEq(snapshot.slot0.sqrtPriceX96, Q96);
        assertEq(snapshot.liquidity, pool.liquidity());
        assertEq(snapshot.balance0, STANDARD_DEPOSIT);
        assertEq(snapshot.balance1, STANDARD_DEPOSIT);
    }

    function test_RangeAndPositionSnapshotsIncludeAccruedGrowth() public {
        (uint256 tokenId, uint128 positionLiquidity,,) = _mintStandardPosition(alice);
        _swapToken0ForToken1(trader, 2000 ether);
        VeyraTypes.ManagedPosition memory managed = positionManager.positions(tokenId);

        VeyraTypes.RangeSnapshot memory range =
            lens.rangeSnapshot(address(pool), TICK_LOWER, TICK_UPPER);
        VeyraTypes.PositionSnapshot memory position = lens.positionSnapshot(
            address(pool), address(positionManager), TICK_LOWER, TICK_UPPER, managed.salt
        );

        assertEq(range.state.liquidityGross, positionLiquidity);
        assertGt(range.feeGrowthInside0X128, 0);
        assertEq(position.state.liquidity, positionLiquidity);
        assertGt(position.accrued0, 0);
        assertEq(position.accrued1, 0);
        assertGt(position.amount0, 0);
        assertGt(position.amount1, 0);
    }

    function test_ManagedPositionViewReturnsNFTController() public {
        (uint256 tokenId,,,) = _mintStandardPosition(alice);

        (VeyraTypes.ManagedPosition memory managed, address owner) =
            lens.managedPosition(address(positionManager), tokenId);

        assertEq(owner, alice);
        assertEq(managed.pool, address(pool));
        assertEq(managed.tickLower, TICK_LOWER);
        assertEq(managed.tickUpper, TICK_UPPER);
    }

    function test_ExactInputQuoteMatchesExecution() public {
        _mintStandardPosition(alice);
        uint256 amountIn = 1000 ether;
        uint160 limit = PriceMath.getSqrtPriceAtTick(-540);
        VeyraTypes.QuoteResult memory quote =
            quoter.quoteExactInputSingle(address(pool), true, amountIn, limit);

        uint256 actualOut = _swapToken0ForToken1(trader, amountIn);

        assertEq(actualOut, quote.amountOut);
        assertEq(pool.slot0().sqrtPriceX96, quote.sqrtPriceAfterX96);
        assertEq(pool.slot0().tick, quote.tickAfter);
        assertEq(quote.amountIn, amountIn);
        assertGt(quote.feeAmount, 0);
    }

    function test_LiquidityAmountViewsRoundTripWithinRoundingBound() public {
        uint128 liquidity = lens.liquidityForAmounts(
            address(pool), TICK_LOWER, TICK_UPPER, 50_000 ether, 50_000 ether
        );
        (uint256 amount0, uint256 amount1) =
            lens.amountsForLiquidity(address(pool), TICK_LOWER, TICK_UPPER, liquidity);

        assertLe(amount0, 50_000 ether);
        assertLe(amount1, 50_000 ether);
        assertApproxEqAbs(amount0, 50_000 ether, 1);
        assertApproxEqAbs(amount1, 50_000 ether, 1);
    }
}
