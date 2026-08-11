// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IBurn} from "../src/interface/IBurn.sol";

contract GenerateAirdropSnapshot is Script {
    error ContractAccountsRequireTargetReview(uint256 count);

    uint256 internal constant WAD = 1e18;
    uint256 internal constant PAGE_SIZE = 200;

    struct SnapshotMetadata {
        uint256 sourceChainId;
        uint256 sourceBlockNumber;
        address sourceBurnAddress;
        bytes32 root;
        uint256 totalShare;
    }

    function run() external returns (bytes32 root, uint256 totalShare, uint256 accountCount) {
        SnapshotMetadata memory metadata;
        metadata.sourceChainId = vm.envUint("SOURCE_CHAIN_ID");
        metadata.sourceBlockNumber = vm.envUint("SOURCE_BLOCK_NUMBER");
        metadata.sourceBurnAddress = vm.envAddress("SOURCE_BURN");

        require(block.chainid == metadata.sourceChainId, "source chain id mismatch");
        require(block.number == metadata.sourceBlockNumber, "source block number mismatch");
        require(metadata.sourceBurnAddress.code.length > 0, "source burn has no code");

        bool contractAccountsReviewed = vm.envOr("CONTRACT_ACCOUNTS_REVIEWED", false);
        (address[] memory accounts, uint256[] memory shares) =
            _readFinalShares(IBurn(metadata.sourceBurnAddress), contractAccountsReviewed);
        bytes32[][] memory proofs;
        (root, totalShare, proofs) = build(accounts, shares);
        metadata.root = root;
        metadata.totalShare = totalShare;
        accountCount = accounts.length;

        string memory network = vm.envOr("network", string("snapshot"));
        string memory directory = string.concat("script/network/", network);
        vm.createDir(directory, true);
        string memory output = vm.envOr("SNAPSHOT_OUTPUT", string.concat(directory, "/airdrop-snapshot.json"));
        _writeSnapshot(output, metadata, accounts, shares, proofs);
    }

    function build(address[] memory accounts, uint256[] memory shares)
        public
        pure
        returns (bytes32 root, uint256 totalShare, bytes32[][] memory proofs)
    {
        uint256 count = accounts.length;
        require(count > 0 && count == shares.length, "invalid snapshot entries");

        bytes32[] memory leaves = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            require(accounts[i] != address(0) && shares[i] > 0, "invalid snapshot entry");
            leaves[i] = leafHash(accounts[i], shares[i]);
            totalShare += shares[i];
        }
        require(totalShare <= WAD, "invalid total share");

        bytes32[][] memory layers = _buildLayers(leaves);
        root = layers[layers.length - 1][0];
        proofs = new bytes32[][](count);
        for (uint256 i; i < count; ++i) {
            proofs[i] = _proof(layers, i);
        }
    }

    function leafHash(address account, uint256 share) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, share))));
    }

    function _readFinalShares(IBurn burn, bool contractAccountsReviewed)
        internal
        view
        returns (address[] memory accounts, uint256[] memory shares)
    {
        (, bool finalized) = burn.accountShare(address(0));
        require(finalized, "burn shares not finalized");

        uint256 participantCount = burn.participantsCount();
        accounts = new address[](participantCount);
        shares = new uint256[](participantCount);
        uint256 included;
        uint256 contractAccountCount;

        for (uint256 offset; offset < participantCount; offset += PAGE_SIZE) {
            uint256 limit = _min(PAGE_SIZE, participantCount - offset);
            address[] memory page = burn.participants(offset, limit);
            require(page.length == limit, "incomplete participant page");
            for (uint256 i; i < page.length; ++i) {
                (uint256 share, bool accountFinalized) = burn.accountShare(page[i]);
                require(accountFinalized, "burn shares not finalized");
                if (share > 0) {
                    if (page[i].code.length > 0) {
                        ++contractAccountCount;
                        console2.log("Source contract account requiring target-chain review:", page[i]);
                    }
                    accounts[included] = page[i];
                    shares[included] = share;
                    ++included;
                }
            }
        }

        assembly ("memory-safe") {
            mstore(accounts, included)
            mstore(shares, included)
        }
        require(included > 0, "no positive final shares");
        if (contractAccountCount > 0 && !contractAccountsReviewed) {
            revert ContractAccountsRequireTargetReview(contractAccountCount);
        }
    }

    function _buildLayers(bytes32[] memory leaves) internal pure returns (bytes32[][] memory layers) {
        uint256 levelCount = 1;
        for (uint256 count = leaves.length; count > 1; count = (count + 1) / 2) {
            ++levelCount;
        }

        layers = new bytes32[][](levelCount);
        layers[0] = leaves;
        for (uint256 level = 1; level < levelCount; ++level) {
            bytes32[] memory previous = layers[level - 1];
            bytes32[] memory current = new bytes32[]((previous.length + 1) / 2);
            for (uint256 i; i < current.length; ++i) {
                uint256 left = i * 2;
                current[i] = left + 1 < previous.length ? _hashPair(previous[left], previous[left + 1]) : previous[left];
            }
            layers[level] = current;
        }
    }

    function _proof(bytes32[][] memory layers, uint256 leafIndex) internal pure returns (bytes32[] memory proof) {
        uint256 proofLength;
        uint256 index = leafIndex;
        for (uint256 level; level + 1 < layers.length; ++level) {
            uint256 sibling = index ^ 1;
            if (sibling < layers[level].length) ++proofLength;
            index /= 2;
        }

        proof = new bytes32[](proofLength);
        index = leafIndex;
        uint256 proofIndex;
        for (uint256 level; level + 1 < layers.length; ++level) {
            uint256 sibling = index ^ 1;
            if (sibling < layers[level].length) proof[proofIndex++] = layers[level][sibling];
            index /= 2;
        }
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(bytes.concat(a, b)) : keccak256(bytes.concat(b, a));
    }

    function _writeSnapshot(
        string memory output,
        SnapshotMetadata memory metadata,
        address[] memory accounts,
        uint256[] memory shares,
        bytes32[][] memory proofs
    ) internal {
        vm.writeFile(output, "{\n");
        vm.writeLine(output, string.concat("  \"sourceChainId\": \"", vm.toString(metadata.sourceChainId), "\","));
        vm.writeLine(
            output, string.concat("  \"sourceBlockNumber\": \"", vm.toString(metadata.sourceBlockNumber), "\",")
        );
        vm.writeLine(
            output, string.concat("  \"sourceBurnAddress\": \"", vm.toString(metadata.sourceBurnAddress), "\",")
        );
        vm.writeLine(output, string.concat("  \"merkleRoot\": \"", vm.toString(metadata.root), "\","));
        vm.writeLine(output, string.concat("  \"totalShare\": \"", vm.toString(metadata.totalShare), "\","));
        vm.writeLine(output, string.concat("  \"accountCount\": \"", vm.toString(accounts.length), "\","));
        vm.writeLine(output, "  \"entries\": [");
        for (uint256 i; i < accounts.length; ++i) {
            vm.writeLine(output, _entryJson(accounts[i], shares[i], proofs[i], i + 1 < accounts.length));
        }
        vm.writeLine(output, "  ]");
        vm.writeLine(output, "}");
    }

    function _entryJson(address account, uint256 share, bytes32[] memory proof, bool trailingComma)
        internal
        pure
        returns (string memory json)
    {
        json = string.concat(
            "    {\"account\": \"", vm.toString(account), "\", \"share\": \"", vm.toString(share), "\", \"proof\": ["
        );
        for (uint256 i; i < proof.length; ++i) {
            json = string.concat(json, i == 0 ? "\"" : ", \"", vm.toString(proof[i]), "\"");
        }
        json = string.concat(json, "]}", trailingComma ? "," : "");
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
