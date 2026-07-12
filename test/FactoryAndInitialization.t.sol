// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {VeyraFactory} from "../src/VeyraFactory.sol";
import {VeyraPool} from "../src/VeyraPool.sol";
import {VeyraTypes} from "../src/types/VeyraTypes.sol";
import {VeyraTestBase} from "./helpers/VeyraTestBase.sol";

contract FactoryAndInitializationTest is VeyraTestBase {
    function test_FactoryCreatesCanonicalInitializedPool() public view {
        assertEq(factory.owner(), admin);
        assertEq(factory.protocolFeeRecipient(), treasury);
        assertEq(factory.getPool(address(token0), address(token1), FEE_PIPS), address(pool));
        assertEq(factory.getPool(address(token1), address(token0), FEE_PIPS), address(pool));
        assertEq(factory.allPoolsLength(), 1);
        assertEq(factory.allPools(0), address(pool));

        VeyraTypes.PoolKey memory key = pool.poolKey();
        assertEq(key.token0, address(token0));
        assertEq(key.token1, address(token1));
        assertEq(key.feePips, FEE_PIPS);
        assertEq(key.tickSpacing, TICK_SPACING);

        VeyraTypes.Slot0 memory state = pool.slot0();
        assertEq(state.sqrtPriceX96, Q96);
        assertEq(state.tick, 0);
        assertEq(state.protocolFeePips, 0);
        assertTrue(state.unlocked);
    }

    function test_DefaultFeeTiersUseExpectedTickSpacing() public view {
        assertEq(factory.feeAmountTickSpacing(500), 10);
        assertEq(factory.feeAmountTickSpacing(3000), 60);
        assertEq(factory.feeAmountTickSpacing(10_000), 200);
        assertEq(factory.feeAmountTickSpacing(2500), 0);
    }

    function test_PredictedAddressMatchesDeployedPool() public {
        address predicted = factory.computePoolAddress(address(token1), address(token0), 500);
        address deployed = factory.createPool(address(token1), address(token0), 500, Q96);
        assertEq(deployed, predicted);
        assertEq(factory.getPool(address(token0), address(token1), 500), deployed);
        assertEq(factory.allPoolsLength(), 2);

        VeyraTypes.Slot0 memory state = VeyraPool(deployed).slot0();
        assertEq(state.sqrtPriceX96, Q96);
        assertEq(state.tick, 0);
    }

    function test_DuplicatePoolCreationIsRejected() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                VeyraFactory.PoolAlreadyExists.selector, address(token0), address(token1), FEE_PIPS
            )
        );
        factory.createPool(address(token1), address(token0), FEE_PIPS, Q96);
    }

    function test_OnlyOwnerCanEnableFeeTier() public {
        vm.expectRevert(VeyraFactory.Unauthorized.selector);
        vm.prank(bob);
        factory.enableFeeTier(2500, 50);

        vm.prank(admin);
        factory.enableFeeTier(2500, 50);
        assertEq(factory.feeAmountTickSpacing(2500), 50);
    }

    function test_InvalidAndDuplicateFeeTiersAreRejected() public {
        vm.expectRevert(abi.encodeWithSelector(VeyraFactory.InvalidTickSpacing.selector, int24(0)));
        vm.prank(admin);
        factory.enableFeeTier(2500, 0);

        vm.expectRevert(
            abi.encodeWithSelector(VeyraFactory.FeeTierAlreadyEnabled.selector, uint24(FEE_PIPS))
        );
        vm.prank(admin);
        factory.enableFeeTier(FEE_PIPS, TICK_SPACING);
    }

    function test_InitializedPoolCannotBeInitializedAgain() public {
        vm.expectRevert(VeyraPool.AlreadyInitialized.selector);
        vm.prank(address(factory));
        pool.initialize(Q96);
    }

    function test_FactoryOwnershipUsesExplicitAcceptance() public {
        vm.prank(admin);
        factory.transferOwnership(bob);
        assertEq(factory.owner(), admin);
        assertEq(factory.pendingOwner(), bob);

        vm.prank(bob);
        factory.acceptOwnership();
        assertEq(factory.owner(), bob);
        assertEq(factory.pendingOwner(), address(0));
    }
}
