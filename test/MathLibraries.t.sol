// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {FeeMath} from "../src/libraries/FeeMath.sol";
import {FullMath} from "../src/libraries/FullMath.sol";
import {LiquidityMath} from "../src/libraries/LiquidityMath.sol";
import {PriceMath} from "../src/libraries/PriceMath.sol";
import {RangeKey} from "../src/libraries/RangeKey.sol";
import {SwapMath} from "../src/libraries/SwapMath.sol";

contract MathLibrariesTest is Test {
    uint160 internal constant Q96 = uint160(1 << 96);

    function test_FullMathHandlesFullWidthProduct() public pure {
        uint256 maximum = type(uint256).max;
        assertEq(FullMath.mulDiv(maximum, maximum, maximum), maximum);
    }

    function test_FullMathRoundingModes() public pure {
        assertEq(FullMath.mulDiv(10, 10, 6), 16);
        assertEq(FullMath.mulDivRoundingUp(10, 10, 6), 17);
        assertEq(FullMath.ceilDiv(100, 10), 10);
        assertEq(FullMath.ceilDiv(101, 10), 11);
    }

    function testFuzz_FullMathMatchesNativeArithmetic(uint128 a, uint128 b, uint128 rawDenominator)
        public
        pure
    {
        uint256 denominator = uint256(rawDenominator) + 1;
        uint256 product = uint256(a) * uint256(b);
        assertEq(FullMath.mulDiv(a, b, denominator), product / denominator);
        uint256 expectedUp = product == 0 ? 0 : ((product - 1) / denominator) + 1;
        assertEq(FullMath.mulDivRoundingUp(a, b, denominator), expectedUp);
    }

    function test_FeeMathUsesPipDenominator() public pure {
        uint256 amount = 1 ether;
        assertEq(FeeMath.feeAmount(amount, 3000), 0.003 ether);
        assertEq(FeeMath.netInput(amount, 3000), 0.997 ether);
        assertEq(FeeMath.feeFromNetInput(0.997 ether, 3000), 0.003 ether);
    }

    function test_FeeGrowthAccruesAgainstLiquidity() public pure {
        uint128 liquidity = 100;
        uint256 growth = FeeMath.growthIncrement(1000, liquidity);
        assertEq(FeeMath.accrued(liquidity, growth, 0), 1000);
        assertEq(FeeMath.addOwed(25, 1000), 1025);
    }

    function test_FeeSplitPreservesTotal() public pure {
        (uint256 protocolFee, uint256 providerFee) = FeeMath.split(50_000, 100_000);
        assertEq(protocolFee, 5000);
        assertEq(providerFee, 45_000);
        assertEq(protocolFee + providerFee, 50_000);
    }

    function test_FeeMathRejectsOneHundredPercentFee() public {
        vm.expectRevert(abi.encodeWithSelector(FeeMath.InvalidFeePips.selector, uint24(1_000_000)));
        this.validateFee(1_000_000);
    }

    function testFuzz_FeeComponentsDoNotExceedGross(uint128 rawAmount, uint24 rawFeePips)
        public
        pure
    {
        uint256 amount = uint256(rawAmount);
        uint24 feePips = uint24(uint256(rawFeePips) % 1_000_000);
        uint256 net = FeeMath.netInput(amount, feePips);
        uint256 fee = FeeMath.feeAmount(amount, feePips);
        assertLe(net + fee, amount);
        assertLe(amount - net - fee, 1);
    }

    function test_TickZeroIsUnitSquareRootPrice() public pure {
        assertEq(PriceMath.getSqrtPriceAtTick(0), Q96);
        assertEq(PriceMath.getTickAtSqrtPrice(Q96), 0);
    }

    function test_TickPricesAreStrictlyIncreasing() public pure {
        uint160 below = PriceMath.getSqrtPriceAtTick(-120);
        uint160 center = PriceMath.getSqrtPriceAtTick(0);
        uint160 above = PriceMath.getSqrtPriceAtTick(120);
        assertLt(below, center);
        assertLt(center, above);
    }

    function test_NegativeTicksFloorToSpacing() public pure {
        assertEq(PriceMath.floorToSpacing(121, 60), 120);
        assertEq(PriceMath.floorToSpacing(-121, 60), -180);
        assertEq(PriceMath.floorToSpacing(-120, 60), -120);
    }

    function testFuzz_TickPriceRoundTrip(int24 rawTick) public pure {
        int24 tick = int24(
            bound(int256(rawTick), int256(PriceMath.MIN_TICK), int256(PriceMath.MAX_TICK) - 1)
        );
        uint160 sqrtPriceX96 = PriceMath.getSqrtPriceAtTick(tick);
        assertEq(PriceMath.getTickAtSqrtPrice(sqrtPriceX96), tick);
    }

    function test_InputPriceMovementUsesSwapDirection() public pure {
        uint128 liquidity = 1 ether;
        uint160 down = PriceMath.nextSqrtPriceFromInput(Q96, liquidity, 1e12, true);
        uint160 up = PriceMath.nextSqrtPriceFromInput(Q96, liquidity, 1e12, false);
        assertLt(down, Q96);
        assertGt(up, Q96);
    }

    function test_LiquidityDeltaUpdatesWithBounds() public {
        assertEq(LiquidityMath.addDelta(1000, 250), 1250);
        assertEq(LiquidityMath.addDelta(1000, -250), 750);
        vm.expectRevert(LiquidityMath.LiquidityUnderflow.selector);
        this.applyLiquidityDelta(100, -101);
    }

    function test_AmountDeltasAreIndependentOfEndpointOrder() public pure {
        uint160 lower = PriceMath.getSqrtPriceAtTick(-300);
        uint160 upper = PriceMath.getSqrtPriceAtTick(300);
        uint128 liquidity = 10 ether;
        assertEq(
            LiquidityMath.amount0Delta(lower, upper, liquidity, true),
            LiquidityMath.amount0Delta(upper, lower, liquidity, true)
        );
        assertEq(
            LiquidityMath.amount1Delta(lower, upper, liquidity, false),
            LiquidityMath.amount1Delta(upper, lower, liquidity, false)
        );
    }

    function testFuzz_LiquidityAndAmountsRoundTrip(uint128 rawLiquidity) public pure {
        uint128 liquidity = uint128(bound(rawLiquidity, 1e6, 1e18));
        uint160 lower = PriceMath.getSqrtPriceAtTick(-600);
        uint160 upper = PriceMath.getSqrtPriceAtTick(600);
        (uint256 amount0, uint256 amount1) =
            LiquidityMath.amountsForLiquidity(Q96, lower, upper, liquidity);
        uint128 recovered = LiquidityMath.liquidityForAmounts(Q96, lower, upper, amount0, amount1);
        assertApproxEqAbs(uint256(recovered), uint256(liquidity), 100);
    }

    function test_SwapStepReachesTargetWithSufficientInput() public pure {
        uint160 target = PriceMath.getSqrtPriceAtTick(-60);
        (uint160 next, uint256 amountIn, uint256 amountOut, uint256 fee) =
            SwapMath.computeSwapStep(Q96, target, 1 ether, int256(1 ether), 3000);
        assertEq(next, target);
        assertGt(amountIn, 0);
        assertGt(amountOut, 0);
        assertGt(fee, 0);
        assertLe(amountIn + fee, 1 ether);
    }

    function test_PartialExactInputConsumesSpecifiedAmount() public pure {
        uint256 specified = 1e12;
        uint160 target = PriceMath.getSqrtPriceAtTick(-600);
        (uint160 next, uint256 amountIn, uint256 amountOut, uint256 fee) =
            SwapMath.computeSwapStep(Q96, target, 1 ether, int256(specified), 3000);
        assertLt(next, Q96);
        assertGt(next, target);
        assertGt(amountOut, 0);
        assertEq(amountIn + fee, specified);
    }

    function test_ExactOutputDoesNotExceedRequestedAmount() public pure {
        uint256 requested = 1e12;
        uint160 target = PriceMath.getSqrtPriceAtTick(-600);
        (uint160 next, uint256 amountIn, uint256 amountOut, uint256 fee) =
            SwapMath.computeSwapStep(Q96, target, 1 ether, -int256(requested), 3000);
        assertLt(next, Q96);
        assertGt(next, target);
        assertGt(amountIn, 0);
        assertGt(fee, 0);
        assertLe(amountOut, requested);
    }

    function testFuzz_PartialSwapMaintainsPriceBounds(uint96 rawAmount) public pure {
        uint256 amount = bound(uint256(rawAmount), 1e6, 1e15);
        uint160 target = PriceMath.getSqrtPriceAtTick(-1200);
        (uint160 next, uint256 amountIn, uint256 amountOut, uint256 fee) =
            SwapMath.computeSwapStep(Q96, target, 100 ether, int256(amount), 500);
        assertGe(next, target);
        assertLe(next, Q96);
        assertLe(amountIn + fee, amount);
        assertGt(amountOut, 0);
    }

    function test_RangeKeysAreCanonical() public pure {
        address tokenA = address(0xA11CE);
        address tokenB = address(0xB0B);
        (address token0, address token1) = RangeKey.sortTokens(tokenA, tokenB);
        assertLt(uint160(token0), uint160(token1));
        assertEq(RangeKey.pool(tokenA, tokenB, 3000), RangeKey.pool(tokenB, tokenA, 3000));
        assertNotEq(RangeKey.range(-120, 120), RangeKey.range(-60, 120));
    }

    function test_PositionKeysAreStableAndSalted() public pure {
        address owner = address(0xCAFE);
        bytes32 first = RangeKey.position(owner, bytes32(uint256(1)));
        assertEq(first, RangeKey.position(owner, bytes32(uint256(1))));
        assertNotEq(first, RangeKey.position(owner, bytes32(uint256(2))));
    }

    function test_RangeValidationRequiresOrderedAlignedTicks() public {
        RangeKey.validateRange(-120, 120, 60);
        vm.expectRevert(
            abi.encodeWithSelector(RangeKey.InvalidRange.selector, int24(120), int24(120))
        );
        this.validateRange(120, 120, 60);
        vm.expectRevert(
            abi.encodeWithSelector(RangeKey.TickNotAligned.selector, int24(-121), int24(60))
        );
        this.validateRange(-121, 120, 60);
    }

    function validateFee(uint24 feePips) external pure {
        FeeMath.validate(feePips);
    }

    function applyLiquidityDelta(uint128 liquidity, int128 delta) external pure returns (uint128) {
        return LiquidityMath.addDelta(liquidity, delta);
    }

    function validateRange(int24 tickLower, int24 tickUpper, int24 tickSpacing) external pure {
        RangeKey.validateRange(tickLower, tickUpper, tickSpacing);
    }
}
