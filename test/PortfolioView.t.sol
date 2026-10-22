// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IVeyraLens} from "../src/interfaces/IVeyraLens.sol";
import {IVeyraPositionManager} from "../src/interfaces/IVeyraPositionManager.sol";
import {VeyraLens} from "../src/periphery/VeyraLens.sol";
import {VeyraPortfolioView} from "../src/periphery/VeyraPortfolioView.sol";
import {VeyraTestBase} from "./helpers/VeyraTestBase.sol";

contract PortfolioViewTest is VeyraTestBase {
    function testBatchesOwnedPositionsAndAmounts() public {
        (uint256 aliceId,,,) = _mintStandardPosition(alice);
        (uint256 bobId,,,) = _mintStandardPosition(bob);
        VeyraLens lens = new VeyraLens(address(factory));
        VeyraPortfolioView view_ = new VeyraPortfolioView(
            IVeyraPositionManager(address(positionManager)), IVeyraLens(address(lens))
        );
        uint256[] memory ids = new uint256[](2);
        ids[0] = aliceId;
        ids[1] = bobId;

        VeyraPortfolioView.PositionView[] memory rows = view_.batch(ids);
        assertEq(rows.length, 2);
        assertEq(rows[0].owner, alice);
        assertEq(rows[1].owner, bob);
        assertEq(rows[0].pool, address(pool));
        assertGt(rows[0].liquidity, 0);
        assertGt(rows[0].amount0, 0);
        assertGt(rows[0].amount1, 0);
        assertEq(rows[0].fees0, 0);
    }

    function testRejectsZeroDependencies() public {
        vm.expectRevert(VeyraPortfolioView.ZeroAddress.selector);
        new VeyraPortfolioView(IVeyraPositionManager(address(0)), IVeyraLens(address(0)));
    }
}
