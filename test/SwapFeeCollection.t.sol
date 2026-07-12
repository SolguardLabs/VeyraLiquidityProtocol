// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {VeyraFactory} from "../src/VeyraFactory.sol";
import {IVeyraPool} from "../src/interfaces/IVeyraPool.sol";
import {PriceMath} from "../src/libraries/PriceMath.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {VeyraPositionManager} from "../src/periphery/VeyraPositionManager.sol";
import {VeyraSwapRouter} from "../src/periphery/VeyraSwapRouter.sol";
import {VeyraTypes} from "../src/types/VeyraTypes.sol";

contract SwapFeeCollectionTest is Test {
    uint160 internal constant Q96 = 1 << 96;
    uint24 internal constant FEE_PIPS = 3000;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal trader = makeAddr("trader");
    address internal treasury = makeAddr("treasury");

    MockERC20 internal assetA;
    MockERC20 internal assetB;
    MockERC20 internal token0;
    MockERC20 internal token1;
    VeyraFactory internal factory;
    VeyraPositionManager internal manager;
    VeyraSwapRouter internal router;
    IVeyraPool internal pool;

    function setUp() public {
        assetA = new MockERC20("Veyra USD", "vUSD", 18);
        assetB = new MockERC20("Veyra ETH", "vETH", 18);
        factory = new VeyraFactory(address(this), treasury);
        manager = new VeyraPositionManager(address(factory));
        router = new VeyraSwapRouter(address(factory));

        address poolAddress = factory.createPool(address(assetA), address(assetB), FEE_PIPS, Q96);
        pool = IVeyraPool(poolAddress);
        token0 = MockERC20(pool.token0());
        token1 = MockERC20(pool.token1());

        _fundAndApprove(alice);
        _fundAndApprove(bob);
        _fundAndApprove(trader);
    }

    function test_ExactInputMovesPriceAndCreditsInputTokenFees() public {
        _mintPosition(alice, 1_000_000 ether, -600, 600);
        uint256 traderOutputBefore = token1.balanceOf(trader);
        uint160 priceBefore = pool.slot0().sqrtPriceX96;

        uint256 amountOut = _swap(trader, address(token0), address(token1), 10_000 ether);

        assertGt(amountOut, 0);
        assertEq(token1.balanceOf(trader) - traderOutputBefore, amountOut);
        assertLt(pool.slot0().sqrtPriceX96, priceBefore);
        assertGt(pool.feeGrowthGlobal0X128(), 0);
        assertEq(pool.feeGrowthGlobal1X128(), 0);
    }

    function test_SwapsInBothDirectionsAccumulateIndependentGrowth() public {
        _mintPosition(alice, 1_000_000 ether, -600, 600);

        _swap(trader, address(token0), address(token1), 8000 ether);
        uint256 growth0 = pool.feeGrowthGlobal0X128();
        _swap(trader, address(token1), address(token0), 4000 ether);

        assertEq(pool.feeGrowthGlobal0X128(), growth0);
        assertGt(pool.feeGrowthGlobal1X128(), 0);
    }

    function test_CollectMaterializesFeesAndSecondCollectIsIdempotent() public {
        uint256 tokenId = _mintPosition(alice, 1_000_000 ether, -600, 600);
        _swap(trader, address(token0), address(token1), 12_000 ether);

        uint256 balanceBefore = token0.balanceOf(alice);
        vm.prank(alice);
        (uint256 collected0, uint256 collected1) = manager.collect(
            VeyraTypes.ManagerCollectParams({
                tokenId: tokenId,
                recipient: alice,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        assertGt(collected0, 0);
        assertEq(collected1, 0);
        assertEq(token0.balanceOf(alice) - balanceBefore, collected0);

        vm.prank(alice);
        (collected0, collected1) = manager.collect(
            VeyraTypes.ManagerCollectParams({
                tokenId: tokenId,
                recipient: alice,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        assertEq(collected0, 0);
        assertEq(collected1, 0);
    }

    function test_OverlappingPositionsReceiveFeesProRata() public {
        uint256 aliceId = _mintPosition(alice, 1_000_000 ether, -600, 600);
        uint256 bobId = _mintPosition(bob, 500_000 ether, -600, 600);
        _swap(trader, address(token0), address(token1), 15_000 ether);

        vm.prank(alice);
        (uint256 aliceFee,) = manager.collect(
            VeyraTypes.ManagerCollectParams({
                tokenId: aliceId,
                recipient: alice,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        vm.prank(bob);
        (uint256 bobFee,) = manager.collect(
            VeyraTypes.ManagerCollectParams({
                tokenId: bobId,
                recipient: bob,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        assertGt(aliceFee, bobFee);
        assertApproxEqRel(aliceFee, bobFee * 2, 1e14);
        assertLe(aliceFee + bobFee, 15_000 ether * uint256(FEE_PIPS) / 1_000_000);
    }

    function test_NewRangeStartsAtCurrentFeeCheckpoint() public {
        _mintPosition(alice, 1_000_000 ether, -600, 600);
        _swap(trader, address(token0), address(token1), 10_000 ether);
        uint256 bobId = _mintPosition(bob, 300_000 ether, -120, 120);

        vm.prank(bob);
        (uint256 collected0, uint256 collected1) = manager.collect(
            VeyraTypes.ManagerCollectParams({
                tokenId: bobId,
                recipient: bob,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        assertEq(collected0, 0);
        assertEq(collected1, 0);
    }

    function test_ProtocolFeeShareCanBeWithdrawnByFactoryOwner() public {
        _mintPosition(alice, 1_000_000 ether, -600, 600);
        factory.setPoolProtocolFee(address(pool), 100_000);
        _swap(trader, address(token0), address(token1), 20_000 ether);

        VeyraTypes.ProtocolFees memory accrued = pool.protocolFees();
        assertGt(accrued.token0, 0);
        uint256 treasuryBefore = token0.balanceOf(treasury);
        factory.collectPoolProtocolFees(address(pool), type(uint128).max, type(uint128).max);

        assertEq(token0.balanceOf(treasury) - treasuryBefore, accrued.token0);
        assertEq(pool.protocolFees().token0, 0);
    }

    function test_ExactOutputHonorsMaximumInput() public {
        _mintPosition(alice, 1_000_000 ether, -600, 600);
        uint256 inputBefore = token0.balanceOf(trader);
        uint256 outputBefore = token1.balanceOf(trader);

        vm.prank(trader);
        uint256 amountIn = router.exactOutputSingle(
            VeyraTypes.ExactOutputSingleParams({
                tokenIn: address(token0),
                tokenOut: address(token1),
                feePips: FEE_PIPS,
                recipient: trader,
                deadline: block.timestamp + 1,
                amountOut: 2000 ether,
                amountInMaximum: 2100 ether,
                sqrtPriceLimitX96: PriceMath.getSqrtPriceAtTick(-540)
            })
        );

        assertLe(amountIn, 2100 ether);
        assertEq(inputBefore - token0.balanceOf(trader), amountIn);
        assertEq(token1.balanceOf(trader) - outputBefore, 2000 ether);
    }

    function _mintPosition(address owner, uint256 desired, int24 lower, int24 upper)
        internal
        returns (uint256 tokenId)
    {
        vm.prank(owner);
        (tokenId,,,) = manager.mint(
            VeyraTypes.MintPositionParams({
                token0: address(token0),
                token1: address(token1),
                feePips: FEE_PIPS,
                tickLower: lower,
                tickUpper: upper,
                amount0Desired: desired,
                amount1Desired: desired,
                amount0Min: 0,
                amount1Min: 0,
                recipient: owner,
                deadline: block.timestamp + 1
            })
        );
    }

    function _swap(address caller, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        bool zeroForOne = tokenIn == address(token0);
        vm.prank(caller);
        amountOut = router.exactInputSingle(
            VeyraTypes.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                feePips: FEE_PIPS,
                recipient: caller,
                deadline: block.timestamp + 1,
                amountIn: amountIn,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: PriceMath.getSqrtPriceAtTick(
                    zeroForOne ? int24(-540) : int24(540)
                )
            })
        );
    }

    function _fundAndApprove(address account) internal {
        token0.mint(account, 10_000_000 ether);
        token1.mint(account, 10_000_000 ether);
        vm.startPrank(account);
        token0.approve(address(manager), type(uint256).max);
        token1.approve(address(manager), type(uint256).max);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }
}
