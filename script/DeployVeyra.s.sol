// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";

import {VeyraFactory} from "../src/VeyraFactory.sol";
import {VeyraLens} from "../src/periphery/VeyraLens.sol";
import {VeyraPositionManager} from "../src/periphery/VeyraPositionManager.sol";
import {VeyraQuoter} from "../src/periphery/VeyraQuoter.sol";
import {VeyraSwapRouter} from "../src/periphery/VeyraSwapRouter.sol";

/// @notice Deploys the Veyra core registry and its canonical periphery contracts.
contract DeployVeyra is Script {
    uint160 internal constant Q96 = 1 << 96;

    struct Deployment {
        VeyraFactory factory;
        VeyraPositionManager positionManager;
        VeyraSwapRouter router;
        VeyraQuoter quoter;
        VeyraLens lens;
        address pool;
    }

    function run() external returns (Deployment memory deployed) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address admin = vm.envOr("VEYRA_ADMIN", deployer);
        address feeRecipient = vm.envOr("VEYRA_FEE_RECIPIENT", admin);
        address tokenA = vm.envOr("VEYRA_TOKEN_A", address(0));
        address tokenB = vm.envOr("VEYRA_TOKEN_B", address(0));
        uint256 configuredPrice = vm.envOr("VEYRA_INITIAL_SQRT_PRICE_X96", uint256(Q96));
        uint256 configuredFee = vm.envOr("VEYRA_FEE_PIPS", uint256(3000));

        require(configuredPrice <= type(uint160).max, "initial price exceeds uint160");
        require(configuredFee <= type(uint24).max, "fee exceeds uint24");

        vm.startBroadcast(deployerKey);
        deployed.factory = new VeyraFactory(admin, feeRecipient);
        deployed.positionManager = new VeyraPositionManager(address(deployed.factory));
        deployed.router = new VeyraSwapRouter(address(deployed.factory));
        deployed.quoter = new VeyraQuoter(address(deployed.factory));
        deployed.lens = new VeyraLens(address(deployed.factory));

        if (tokenA != address(0) || tokenB != address(0)) {
            require(tokenA != address(0) && tokenB != address(0), "both pool tokens required");
            deployed.pool = deployed.factory
                .createPool(tokenA, tokenB, uint24(configuredFee), uint160(configuredPrice));
        }
        vm.stopBroadcast();
    }
}
