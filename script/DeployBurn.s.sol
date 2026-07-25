// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {Script} from "forge-std/Script.sol";
import {Burn} from "../src/Burn.sol";
import {CommunityWeight} from "../src/interface/IBurn.sol";
import {IExtensionCenter} from "@extension/interface/IExtensionCenter.sol";
import {ILOVE20Mint} from "@core/interfaces/ILOVE20Mint.sol";
import {ILOVE20Token} from "@core/interfaces/ILOVE20Token.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

struct BurnDeploymentConfig {
    address extensionCenterAddress;
    address scopeTokenAddress;
    address airdropTokenAddress;
    CommunityWeight[] communities;
    uint256 startRound;
    uint256 roundCount;
    uint256 quotaMultiplier;
    address[] supportedExtensionFactories;
}

contract DeployBurn is Script {
    uint256 internal constant WAD = 1e18;

    function run() external returns (Burn deployed) {
        BurnDeploymentConfig memory config = _readConfig();

        vm.startBroadcast();
        deployed = new Burn(
            config.extensionCenterAddress,
            config.scopeTokenAddress,
            config.airdropTokenAddress,
            config.communities,
            config.startRound,
            config.roundCount,
            config.quotaMultiplier,
            config.supportedExtensionFactories
        );
        vm.stopBroadcast();

        require(validationFailureCount(deployed, config) == 0, "deployment validation failed");

        string memory network = vm.envOr("network", string("anvil"));
        vm.writeFile(
            string.concat("script/network/", network, "/address.burn.params"),
            string.concat("burnAddress=", vm.toString(address(deployed)), "\n")
        );
    }

    function validationFailureCount(Burn deployed, BurnDeploymentConfig memory expected)
        public
        view
        returns (uint256 failures)
    {
        if (deployed.extensionCenter() != expected.extensionCenterAddress) ++failures;
        if (deployed.scopeTokenAddress() != expected.scopeTokenAddress) ++failures;
        if (deployed.airdropTokenAddress() != expected.airdropTokenAddress) ++failures;
        if (deployed.startRound() != expected.startRound) ++failures;
        if (deployed.roundCount() != expected.roundCount) ++failures;
        if (deployed.endRound() != expected.startRound + expected.roundCount - 1) ++failures;
        if (deployed.quotaMultiplier() != expected.quotaMultiplier) ++failures;
        if (deployed.remainingAirdropShare() != WAD) ++failures;

        IExtensionCenter center = IExtensionCenter(expected.extensionCenterAddress);
        address mintAddress = center.mintAddress();
        if (
            expected.extensionCenterAddress.code.length == 0 || center.launchAddress().code.length == 0
                || center.voteAddress().code.length == 0 || center.verifyAddress().code.length == 0
                || mintAddress.code.length == 0
        ) ++failures;

        uint256 rewardRate = ILOVE20Mint(mintAddress).ROUND_REWARD_GOV_PER_THOUSAND()
            + ILOVE20Mint(mintAddress).ROUND_REWARD_ACTION_PER_THOUSAND();
        address[] memory actualCommunities = deployed.communities();
        if (actualCommunities.length != expected.communities.length) ++failures;
        uint256 communityCount = Math.min(actualCommunities.length, expected.communities.length);
        uint256 expectedTotalWeight;
        for (uint256 i; i < expected.communities.length; ++i) {
            expectedTotalWeight += expected.communities[i].weight;
        }
        for (uint256 i; i < communityCount; ++i) {
            CommunityWeight memory community = expected.communities[i];
            if (actualCommunities[i] != community.tokenAddress) ++failures;
            if (deployed.communityWeight(community.tokenAddress) != community.weight) ++failures;
            if (deployed.scoreBase(community.tokenAddress) != _scoreBase(community.tokenAddress, rewardRate)) {
                ++failures;
            }
        }
        if (deployed.totalCommunityWeight() != expectedTotalWeight) ++failures;

        address[] memory actualFactories = deployed.supportedExtensionFactories();
        if (actualFactories.length != expected.supportedExtensionFactories.length) ++failures;
        uint256 factoryCount = Math.min(actualFactories.length, expected.supportedExtensionFactories.length);
        for (uint256 i; i < factoryCount; ++i) {
            address factory = expected.supportedExtensionFactories[i];
            if (
                actualFactories[i] != factory || !deployed.isSupportedExtensionFactory(factory)
                    || factory.code.length == 0
            ) {
                ++failures;
            }
        }

        if (expected.airdropTokenAddress != address(0)) {
            (bool success, bytes memory result) =
                expected.airdropTokenAddress.staticcall(abi.encodeCall(IERC20.balanceOf, (address(deployed))));
            if (!success || result.length < 32) ++failures;
        }
    }

    function _readConfig() internal view returns (BurnDeploymentConfig memory config) {
        address[] memory tokens = vm.envAddress("COMMUNITY_TOKENS", ",");
        uint256[] memory weights = vm.envUint("COMMUNITY_WEIGHTS", ",");
        require(tokens.length == weights.length, "community length mismatch");

        config.communities = new CommunityWeight[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            config.communities[i] = CommunityWeight(tokens[i], weights[i]);
        }

        config.extensionCenterAddress = vm.envAddress("EXTENSION_CENTER");
        config.scopeTokenAddress = vm.envAddress("SCOPE_TOKEN");
        config.airdropTokenAddress = vm.envOr("AIRDROP_TOKEN", address(0));
        config.startRound = vm.envUint("START_ROUND");
        config.roundCount = vm.envUint("ROUND_COUNT");
        config.quotaMultiplier = vm.envUint("QUOTA_MULTIPLIER");
        config.supportedExtensionFactories = vm.envOr("SUPPORTED_EXTENSION_FACTORIES", ",", new address[](0));
    }

    function _scoreBase(address tokenAddress, uint256 rewardRate) internal view returns (uint256) {
        ILOVE20Token token = ILOVE20Token(tokenAddress);
        uint256 totalSupply = token.totalSupply();
        uint256 roundReward = Math.mulDiv(token.maxSupply() - totalSupply, rewardRate, 1000);
        return WAD + Math.mulDiv(roundReward, WAD, totalSupply);
    }
}
