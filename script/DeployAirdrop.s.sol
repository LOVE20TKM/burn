// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {Script} from "forge-std/Script.sol";
import {Airdrop} from "../src/Airdrop.sol";
import {ValidateAirdropSnapshot} from "./ValidateAirdropSnapshot.s.sol";

contract DeployAirdrop is Script {
    function run() external returns (Airdrop deployed) {
        uint256 sourceChainId = vm.envUint("SOURCE_CHAIN_ID");
        uint256 sourceBlockNumber = vm.envUint("SOURCE_BLOCK_NUMBER");
        address sourceBurnAddress = vm.envAddress("SOURCE_BURN");
        bytes32 merkleRoot = vm.envBytes32("MERKLE_ROOT");
        uint256 totalShare = vm.envUint("TOTAL_SHARE");

        // Fail closed: the deployer must point at the exact published snapshot.
        // Validating it here makes a bare `forge script DeployAirdrop` invocation
        // unable to skip the sum/root/proof checks (the contract itself cannot
        // verify that `totalShare == sum(entries)`).
        string memory snapshot = vm.envOr("SNAPSHOT_INPUT", string(""));
        require(bytes(snapshot).length > 0, "SNAPSHOT_INPUT required");
        // Deployment-time validation must not inherit a previously deployed
        // instance from an exported environment variable.
        vm.setEnv("AIRDROP_ADDRESS", vm.toString(address(0)));
        ValidateAirdropSnapshot validator = new ValidateAirdropSnapshot();
        uint256 validatedAccounts = validator.run();
        require(validatedAccounts > 0, "empty snapshot");

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
