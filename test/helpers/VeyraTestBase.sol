// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {VeyraFactory} from "../../src/VeyraFactory.sol";
import {VeyraPool} from "../../src/VeyraPool.sol";
import {IVeyraPool} from "../../src/interfaces/IVeyraPool.sol";
import {PriceMath} from "../../src/libraries/PriceMath.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {VeyraPositionManager} from "../../src/periphery/VeyraPositionManager.sol";
import {VeyraSwapRouter} from "../../src/periphery/VeyraSwapRouter.sol";
import {VeyraTypes} from "../../src/types/VeyraTypes.sol";

abstract contract VeyraTestBase is Test {
    uint160 internal constant Q96 = uint160(1 << 96);
    uint24 internal constant FEE_PIPS = 3000;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;
    uint256 internal constant STARTING_BALANCE = 10_000_000 ether;
    uint256 internal constant STANDARD_DEPOSIT = 100_000 ether;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal trader = makeAddr("trader");

    MockERC20 internal token0;
    MockERC20 internal token1;
    VeyraFactory internal factory;
    VeyraPool internal pool;
    VeyraPositionManager internal positionManager;
    VeyraSwapRouter internal swapRouter;

    function setUp() public virtual {
        MockERC20 tokenA = new MockERC20("Veyra USD", "vUSD", 18);
        MockERC20 tokenB = new MockERC20("Veyra Ether", "vETH", 18);
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);

        factory = new VeyraFactory(admin, treasury);
        positionManager = new VeyraPositionManager(address(factory));
        swapRouter = new VeyraSwapRouter(address(factory));
        pool = VeyraPool(factory.createPool(address(token0), address(token1), FEE_PIPS, Q96));

        _fundAndApprove(alice);
        _fundAndApprove(bob);
        _fundAndApprove(trader);

        vm.label(address(factory), "VeyraFactory");
        vm.label(address(pool), "VeyraPool-0.30%");
        vm.label(address(positionManager), "VeyraPositionManager");
        vm.label(address(swapRouter), "VeyraSwapRouter");
        vm.label(address(token0), "Token0");
        vm.label(address(token1), "Token1");
    }

    function _fundAndApprove(address account) internal {
        token0.mint(account, STARTING_BALANCE);
        token1.mint(account, STARTING_BALANCE);
        vm.startPrank(account);
        token0.approve(address(positionManager), type(uint256).max);
        token1.approve(address(positionManager), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _mintStandardPosition(address account)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        return _mintPosition(account, TICK_LOWER, TICK_UPPER, STANDARD_DEPOSIT, STANDARD_DEPOSIT);
    }

    function _mintPosition(
        address account,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) internal returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        VeyraTypes.MintPositionParams memory params = VeyraTypes.MintPositionParams({
            token0: address(token0),
            token1: address(token1),
            feePips: FEE_PIPS,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            recipient: account,
            deadline: _deadline()
        });
        vm.prank(account);
        return positionManager.mint(params);
    }

    function _increasePosition(address account, uint256 tokenId, uint256 amount)
        internal
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        VeyraTypes.IncreaseLiquidityParams memory params = VeyraTypes.IncreaseLiquidityParams({
            tokenId: tokenId,
            amount0Desired: amount,
            amount1Desired: amount,
            amount0Min: 0,
            amount1Min: 0,
            deadline: _deadline()
        });
        vm.prank(account);
        return positionManager.increaseLiquidity(params);
    }

    function _decreasePosition(address account, uint256 tokenId, uint128 liquidity)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        VeyraTypes.DecreaseLiquidityParams memory params = VeyraTypes.DecreaseLiquidityParams({
            tokenId: tokenId,
            liquidity: liquidity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: _deadline()
        });
        vm.prank(account);
        return positionManager.decreaseLiquidity(params);
    }

    function _swapToken0ForToken1(address account, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        VeyraTypes.ExactInputSingleParams memory params = VeyraTypes.ExactInputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            feePips: FEE_PIPS,
            recipient: account,
            deadline: _deadline(),
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: PriceMath.getSqrtPriceAtTick(-540)
        });
        vm.prank(account);
        return swapRouter.exactInputSingle(params);
    }

    function _poolPosition(uint256 tokenId)
        internal
        view
        returns (VeyraTypes.ManagedPosition memory managed, VeyraTypes.PositionState memory state)
    {
        managed = positionManager.positions(tokenId);
        bytes32 key = IVeyraPool(managed.pool).positionKey(address(positionManager), managed.salt);
        state = IVeyraPool(managed.pool).positionState(key);
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + 1 days;
    }
}
