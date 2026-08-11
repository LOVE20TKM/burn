// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {Script} from "forge-std/Script.sol";
import {Airdrop} from "../src/Airdrop.sol";

contract DeployAirdrop is Script {
    function run() external returns (Airdrop deployed) {
        uint256 sourceChainId = vm.envUint("SOURCE_CHAIN_ID");
        uint256 sourceBlockNumber = vm.envUint("SOURCE_BLOCK_NUMBER");
        address sourceBurnAddress = vm.envAddress("SOURCE_BURN");
        bytes32 merkleRoot = vm.envBytes32("MERKLE_ROOT");
        uint256 totalShare = vm.envUint("TOTAL_SHARE");

        vm.startBroadcast();
        deployed = new Airdrop(sourceChainId, sourceBlockNumber, sourceBurnAddress, merkleRoot, totalShare);
        vm.stopBroadcast();

        require(deployed.sourceChainId() == sourceChainId, "source chain id mismatch");
        require(deployed.sourceBlockNumber() == sourceBlockNumber, "source block mismatch");
        require(deployed.sourceBurnAddress() == sourceBurnAddress, "source burn mismatch");
        require(deployed.merkleRoot() == merkleRoot, "merkle root mismatch");
        require(deployed.totalShare() == totalShare, "total share mismatch");

        string memory network = vm.envOr("network", string("anvil"));
        vm.writeFile(
            string.concat("script/network/", network, "/address.airdrop.params"),
            string.concat("airdropAddress=", vm.toString(address(deployed)), "\n")
        );
    }
}
