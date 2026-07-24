// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {Script} from "forge-std/Script.sol";
import {Burn} from "../src/Burn.sol";
import {CommunityWeight} from "../src/interface/IBurn.sol";

contract DeployBurn is Script {
    function run() external returns (Burn deployed) {
        address[] memory tokens = vm.envAddress("COMMUNITY_TOKENS", ",");
        uint256[] memory weights = vm.envUint("COMMUNITY_WEIGHTS", ",");
        require(tokens.length == weights.length, "community length mismatch");

        CommunityWeight[] memory communities = new CommunityWeight[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            communities[i] = CommunityWeight(tokens[i], weights[i]);
        }

        address[] memory emptyFactories = new address[](0);
        address[] memory factories = vm.envOr("SUPPORTED_EXTENSION_FACTORIES", ",", emptyFactories);

        vm.startBroadcast();
        deployed = new Burn(
            vm.envAddress("EXTENSION_CENTER"),
            vm.envAddress("SCOPE_TOKEN"),
            vm.envOr("AIRDROP_TOKEN", address(0)),
            communities,
            vm.envUint("START_ROUND"),
            vm.envUint("ROUND_COUNT"),
            vm.envUint("QUOTA_MULTIPLIER"),
            factories
        );
        vm.stopBroadcast();
    }
}
