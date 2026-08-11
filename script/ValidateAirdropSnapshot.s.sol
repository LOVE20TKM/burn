// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {Script} from "forge-std/Script.sol";
import {Airdrop} from "../src/Airdrop.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract ValidateAirdropSnapshot is Script {
    uint256 internal constant WAD = 1e18;

    struct Entry {
        address account;
        uint256 share;
        bytes32[] proof;
        bytes32 leaf;
    }

    mapping(address => bool) internal seen;

    function run() external returns (uint256 accountCount) {
        string memory json = vm.readFile(vm.envString("SNAPSHOT_INPUT"));
        uint256 sourceChainId = vm.envUint("SOURCE_CHAIN_ID");
        uint256 sourceBlockNumber = vm.envUint("SOURCE_BLOCK_NUMBER");
        address sourceBurnAddress = vm.envAddress("SOURCE_BURN");
        bytes32 expectedRoot = vm.envBytes32("MERKLE_ROOT");
        uint256 expectedTotalShare = vm.envUint("TOTAL_SHARE");

        require(vm.parseJsonUint(json, ".sourceChainId") == sourceChainId, "snapshot source chain mismatch");
        require(vm.parseJsonUint(json, ".sourceBlockNumber") == sourceBlockNumber, "snapshot source block mismatch");
        require(vm.parseJsonAddress(json, ".sourceBurnAddress") == sourceBurnAddress, "snapshot source Burn mismatch");
        require(vm.parseJsonBytes32(json, ".merkleRoot") == expectedRoot, "snapshot root mismatch");
        require(vm.parseJsonUint(json, ".totalShare") == expectedTotalShare, "snapshot total share mismatch");

        uint256 declaredCount = vm.parseJsonUint(json, ".accountCount");
        while (vm.keyExistsJson(json, string.concat(".entries[", vm.toString(accountCount), "]"))) ++accountCount;
        require(accountCount == declaredCount, "snapshot account count mismatch");
        require(accountCount > 0, "snapshot has no entries");

        Entry[] memory entries = new Entry[](accountCount);
        bytes32[] memory leaves = new bytes32[](accountCount);
        uint256 totalShare;
        for (uint256 i; i < accountCount; ++i) {
            string memory prefix = string.concat(".entries[", vm.toString(i), "]");
            Entry memory entry;
            entry.account = vm.parseJsonAddress(json, string.concat(prefix, ".account"));
            entry.share = vm.parseJsonUint(json, string.concat(prefix, ".share"));
            entry.proof = vm.parseJsonBytes32Array(json, string.concat(prefix, ".proof"));
            require(entry.account != address(0) && entry.share > 0, "invalid snapshot entry");
            require(!seen[entry.account], "duplicate snapshot account");
            seen[entry.account] = true;
            totalShare += entry.share;
            entry.leaf = _leafHash(entry.account, entry.share);
            entries[i] = entry;
            leaves[i] = entry.leaf;
        }
        require(totalShare == expectedTotalShare && totalShare <= WAD, "snapshot share sum mismatch");

        bytes32 root = _root(leaves);
        require(root == expectedRoot, "snapshot entries produce a different root");
        for (uint256 i; i < accountCount; ++i) {
            require(MerkleProof.verify(entries[i].proof, root, entries[i].leaf), "snapshot proof mismatch");
        }

        address airdropAddress = vm.envOr("AIRDROP_ADDRESS", address(0));
        if (airdropAddress != address(0)) {
            Airdrop airdrop = Airdrop(airdropAddress);
            require(airdrop.sourceChainId() == sourceChainId, "deployed source chain mismatch");
            require(airdrop.sourceBlockNumber() == sourceBlockNumber, "deployed source block mismatch");
            require(airdrop.sourceBurnAddress() == sourceBurnAddress, "deployed source Burn mismatch");
            require(airdrop.merkleRoot() == expectedRoot, "deployed root mismatch");
            require(airdrop.totalShare() == expectedTotalShare, "deployed total share mismatch");
            for (uint256 i; i < accountCount; ++i) {
                require(
                    airdrop.leafHash(entries[i].account, entries[i].share) == entries[i].leaf, "deployed leaf mismatch"
                );
                require(
                    MerkleProof.verify(entries[i].proof, airdrop.merkleRoot(), entries[i].leaf),
                    "deployed proof mismatch"
                );
            }
        }
    }

    function _leafHash(address account, uint256 share) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, share))));
    }

    function _root(bytes32[] memory leaves) internal pure returns (bytes32 root) {
        while (leaves.length > 1) {
            bytes32[] memory next = new bytes32[]((leaves.length + 1) / 2);
            for (uint256 i; i < next.length; ++i) {
                uint256 left = i * 2;
                next[i] = left + 1 < leaves.length ? _hashPair(leaves[left], leaves[left + 1]) : leaves[left];
            }
            leaves = next;
        }
        return leaves[0];
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(bytes.concat(a, b)) : keccak256(bytes.concat(b, a));
    }
}
