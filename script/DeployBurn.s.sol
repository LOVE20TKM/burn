// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {Script} from "forge-std/Script.sol";
import {Burn} from "../src/Burn.sol";
import {CommunityWeight, BurnRoundConfig} from "../src/interface/IBurn.sol";
import {IExtensionCenter} from "@extension/interface/IExtensionCenter.sol";
import {ILOVE20Launch} from "@core/interfaces/ILOVE20Launch.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

struct BurnDeploymentConfig {
    address extensionCenterAddress;
    string scopeTokenSymbol;
    address airdropTokenAddress;
    CommunityWeight[] communities;
    uint256 slTokenLockWeight;
    uint256 stTokenLockWeight;
    uint256 govRewardBurnWeight;
    uint256 actionRewardBurnWeight;
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
            config.scopeTokenSymbol,
            config.airdropTokenAddress,
            config.communities,
            config.slTokenLockWeight,
            config.stTokenLockWeight,
            config.govRewardBurnWeight,
            config.actionRewardBurnWeight,
            BurnRoundConfig(config.startRound, config.roundCount, config.quotaMultiplier),
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
        if (keccak256(bytes(deployed.scopeTokenSymbol())) != keccak256(bytes(expected.scopeTokenSymbol))) ++failures;
        if (deployed.airdropTokenAddress() != expected.airdropTokenAddress) ++failures;
        if (deployed.startRound() != expected.startRound) ++failures;
        if (deployed.roundCount() != expected.roundCount) ++failures;
        if (deployed.endRound() != expected.startRound + expected.roundCount - 1) ++failures;
        if (deployed.quotaMultiplier() != expected.quotaMultiplier) ++failures;
        if (
            deployed.slTokenLockWeight() != expected.slTokenLockWeight
                || deployed.stTokenLockWeight() != expected.stTokenLockWeight
                || deployed.govRewardBurnWeight() != expected.govRewardBurnWeight
                || deployed.actionRewardBurnWeight() != expected.actionRewardBurnWeight
        ) ++failures;
        if (deployed.remainingAirdropShare() != WAD) ++failures;

        failures += _protocolAndCommunityFailureCount(deployed, expected);

        address[] memory actualFactories = deployed.supportedExtensionFactories();
        if (actualFactories.length != expected.supportedExtensionFactories.length) ++failures;
        uint256 factoryCount = Math.min(actualFactories.length, expected.supportedExtensionFactories.length);
        for (uint256 i; i < factoryCount; ++i) {
            address factory = expected.supportedExtensionFactories[i];
            if (actualFactories[i] != factory || factory.code.length == 0) {
                ++failures;
            }
        }

        if (expected.airdropTokenAddress != address(0)) {
            (bool success, bytes memory result) =
                expected.airdropTokenAddress.staticcall(abi.encodeCall(IERC20.balanceOf, (address(deployed))));
            if (!success || result.length < 32) ++failures;
        }
    }

    function _protocolAndCommunityFailureCount(Burn deployed, BurnDeploymentConfig memory expected)
        internal
        view
        returns (uint256 failures)
    {
        IExtensionCenter center = IExtensionCenter(expected.extensionCenterAddress);
        ILOVE20Launch launch = ILOVE20Launch(center.launchAddress());
        if (deployed.scopeTokenAddress() != launch.tokenAddressBySymbol(expected.scopeTokenSymbol)) ++failures;
        address mintAddress = center.mintAddress();
        if (
            expected.extensionCenterAddress.code.length == 0 || center.launchAddress().code.length == 0
                || center.voteAddress().code.length == 0 || center.verifyAddress().code.length == 0
                || mintAddress.code.length == 0
        ) ++failures;

        address[] memory actualCommunities = deployed.communities();
        string[] memory actualSymbols = deployed.communitySymbols();
        if (
            actualCommunities.length != expected.communities.length
                || actualSymbols.length != expected.communities.length
        ) ++failures;
        uint256 communityCount = Math.min(actualCommunities.length, expected.communities.length);
        for (uint256 i; i < communityCount; ++i) {
            CommunityWeight memory community = expected.communities[i];
            address tokenAddress = launch.tokenAddressBySymbol(community.tokenSymbol);
            if (
                actualCommunities[i] != tokenAddress
                    || keccak256(bytes(actualSymbols[i])) != keccak256(bytes(community.tokenSymbol))
            ) ++failures;
            if (deployed.communityWeight(tokenAddress) != community.weight) ++failures;
        }
    }

    function _readConfig() internal view returns (BurnDeploymentConfig memory config) {
        string[] memory symbols = vm.envString("COMMUNITY_SYMBOLS", ",");
        uint256[] memory communityWeights = vm.envUint("COMMUNITY_WEIGHTS", ",");
        require(symbols.length == communityWeights.length, "community length mismatch");

        config.communities = new CommunityWeight[](symbols.length);
        for (uint256 i; i < symbols.length; ++i) {
            config.communities[i] = CommunityWeight(symbols[i], communityWeights[i]);
        }

        uint256[] memory categoryWeights = vm.envUint("CATEGORY_WEIGHTS", ":");
        require(categoryWeights.length == 4, "category weights must have four values");
        config.slTokenLockWeight = categoryWeights[0];
        config.stTokenLockWeight = categoryWeights[1];
        config.govRewardBurnWeight = categoryWeights[2];
        config.actionRewardBurnWeight = categoryWeights[3];

        config.extensionCenterAddress = vm.envAddress("EXTENSION_CENTER");
        config.scopeTokenSymbol = vm.envString("SCOPE_TOKEN_SYMBOL");
        config.airdropTokenAddress = vm.envOr("AIRDROP_TOKEN", address(0));
        config.startRound = vm.envUint("START_ROUND");
        config.roundCount = vm.envUint("ROUND_COUNT");
        config.quotaMultiplier = vm.envUint("QUOTA_MULTIPLIER");
        config.supportedExtensionFactories = vm.envOr("SUPPORTED_EXTENSION_FACTORIES", ",", new address[](0));
    }
}
