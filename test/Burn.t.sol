// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {Test} from "forge-std/Test.sol";
import {Burn} from "../src/Burn.sol";
import {DeployBurn, BurnDeploymentConfig} from "../script/DeployBurn.s.sol";
import {
    IBurnErrors,
    CommunityWeight,
    BurnStats,
    ActionRewardBurnRequest,
    ActionRewardBurnState,
    TokenShare,
    AirdropState
} from "../src/interface/IBurn.sol";
import {
    MockERC20,
    MockLOVE20Token,
    MockLaunch,
    MockVerify,
    MockVote,
    MockMint,
    MockExtensionCenter,
    MockExtensionFactory,
    MockReward,
    MockRevertingReward,
    MockReentrantAirdropToken,
    MockFailingAirdropToken,
    MockUnreadableAirdropToken
} from "./mocks/MockProtocol.sol";

contract BurnTest is Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000 ether;
    uint256 internal constant MAX_SUPPLY = 10_000_000_000 ether;

    MockLaunch internal launch;
    MockVerify internal verify;
    MockVote internal vote;
    MockMint internal mint;
    MockExtensionCenter internal center;
    MockLOVE20Token internal scopeToken;
    MockLOVE20Token internal childToken;
    MockERC20 internal scopeSL;
    MockERC20 internal scopeST;
    MockERC20 internal childSL;
    MockERC20 internal childST;
    Burn internal burn;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    event CommunityConfigFrozen(
        address indexed tokenAddress,
        string tokenSymbol,
        uint256 weight,
        uint256 scoreBase,
        uint256 totalSupply,
        uint256 deploymentRoundReward
    );
    event SupportedExtensionFactoryFrozen(address indexed factory);
    event SLTokenLocked(
        address indexed tokenAddress,
        address indexed account,
        uint256 indexed round,
        uint256 amount,
        uint256 scoreMultiplier,
        uint256 score,
        uint256 accountTotalAmount,
        uint256 accountTotalScore,
        uint256 communityTotalAmount,
        uint256 communityTotalScore
    );
    event STTokenLocked(
        address indexed tokenAddress,
        address indexed account,
        uint256 indexed round,
        uint256 amount,
        uint256 scoreMultiplier,
        uint256 score,
        uint256 accountTotalAmount,
        uint256 accountTotalScore,
        uint256 communityTotalAmount,
        uint256 communityTotalScore
    );
    event GovRewardTokenBurned(
        address indexed tokenAddress,
        address indexed account,
        uint256 indexed round,
        uint256 amount,
        uint256 scoreMultiplier,
        uint256 score,
        uint256 accountTotalAmount,
        uint256 accountTotalScore,
        uint256 communityTotalAmount,
        uint256 communityTotalScore
    );
    event ActionRewardTokenBurned(
        address indexed tokenAddress,
        address indexed account,
        uint256 indexed round,
        uint256 actionId,
        address extensionAddress,
        uint256 amount,
        uint256 scoreMultiplier,
        uint256 score,
        uint256 accountTotalAmount,
        uint256 accountTotalScore,
        uint256 communityTotalAmount,
        uint256 communityTotalScore
    );

    function setUp() public {
        launch = new MockLaunch();
        verify = new MockVerify();
        vote = new MockVote();
        mint = new MockMint();
        center = new MockExtensionCenter(address(launch), address(vote), address(verify), address(mint));

        MockERC20 parent = new MockERC20("Parent", "PARENT");
        scopeSL = new MockERC20("Scope SL", "slSCOPE");
        scopeST = new MockERC20("Scope ST", "stSCOPE");
        scopeToken = new MockLOVE20Token(
            "SCOPE", INITIAL_SUPPLY, MAX_SUPPLY, address(parent), address(scopeSL), address(scopeST)
        );

        childSL = new MockERC20("Child SL", "slCHILD");
        childST = new MockERC20("Child ST", "stCHILD");
        childToken = new MockLOVE20Token(
            "CHILD", INITIAL_SUPPLY, MAX_SUPPLY, address(scopeToken), address(childSL), address(childST)
        );

        launch.setToken(address(scopeToken), address(parent), true);
        launch.setToken(address(childToken), address(scopeToken), true);
        verify.setCurrentRound(5);

        burn = _deployBurn();
    }

    function test_ConstructorFreezesConfigurationAndScoreBase() public view {
        assertEq(burn.extensionCenter(), address(center));
        assertEq(burn.scopeTokenSymbol(), "SCOPE");
        assertEq(burn.scopeTokenAddress(), address(scopeToken));
        assertEq(burn.airdropTokenAddress(), address(0));
        assertEq(burn.startRound(), 5);
        assertEq(burn.roundCount(), 3);
        assertEq(burn.endRound(), 7);
        assertEq(burn.quotaMultiplier(), 5);

        address[] memory communities = burn.communities();
        assertEq(communities.length, 2);
        assertEq(communities[0], address(scopeToken));
        assertEq(communities[1], address(childToken));
        string[] memory communitySymbols = burn.communitySymbols();
        assertEq(communitySymbols[0], "SCOPE");
        assertEq(communitySymbols[1], "CHILD");
        assertEq(burn.communityWeight(address(scopeToken)), 600);
        assertEq(burn.communityWeight(address(childToken)), 400);
        assertEq(burn.totalCommunityWeight(), 1_000);
        assertEq(burn.scoreBase(address(scopeToken)), 1.018 ether);
        assertEq(burn.scoreBase(address(childToken)), 1.018 ether);
        assertEq(burn.remainingAirdropShare(), 1 ether);
        assertEq(burn.supportedExtensionFactories().length, 0);
    }

    function test_ConstructorEmitsFrozenConfiguration() public {
        MockExtensionFactory factory = new MockExtensionFactory();
        address[] memory factories = new address[](1);
        factories[0] = address(factory);

        vm.expectEmit(true, false, false, true);
        emit CommunityConfigFrozen(address(scopeToken), "SCOPE", 600, 1.018 ether, INITIAL_SUPPLY, 18_000_000 ether);
        vm.expectEmit(true, false, false, true);
        emit CommunityConfigFrozen(address(childToken), "CHILD", 400, 1.018 ether, INITIAL_SUPPLY, 18_000_000 ether);
        vm.expectEmit(true, false, false, false);
        emit SupportedExtensionFactoryFrozen(address(factory));

        _deployBurnWithFactories(factories);
    }

    function test_RoundAndScoreMultiplierFollowVerifyClock() public {
        assertFalse(burn.isRoundOpen(5));
        assertEq(burn.scoreMultiplier(address(scopeToken), 4), 0);
        assertEq(burn.scoreMultiplier(address(scopeToken), 5), 1.036324 ether);
        assertEq(burn.scoreMultiplier(address(scopeToken), 7), 1 ether);
        assertEq(burn.scoreMultiplier(address(scopeToken), 8), 0);

        verify.setCurrentRound(6);
        assertTrue(burn.isRoundOpen(5));
        assertFalse(burn.isRoundOpen(6));

        verify.setCurrentRound(8);
        assertTrue(burn.isRoundOpen(7));

        verify.setCurrentRound(9);
        assertFalse(burn.isRoundOpen(7));

        vm.expectRevert(abi.encodeWithSelector(IBurnErrors.UnsupportedCommunity.selector, address(0xBEEF)));
        burn.scoreMultiplier(address(0xBEEF), 5);
    }

    function test_LockReceiptsTransfersToCommunityAndRecordsStats() public {
        scopeSL.mint(alice, 100 ether);
        scopeST.mint(alice, 50 ether);
        vm.startPrank(alice);
        scopeSL.approve(address(burn), type(uint256).max);
        scopeST.approve(address(burn), type(uint256).max);
        verify.setCurrentRound(6);

        burn.lockSLToken(address(scopeToken), 5, 30 ether);
        burn.lockSLToken(address(scopeToken), 5, 70 ether);
        burn.lockSTToken(address(scopeToken), 5, 50 ether);
        vm.stopPrank();

        assertEq(scopeSL.balanceOf(address(scopeToken)), 100 ether);
        assertEq(scopeST.balanceOf(address(scopeToken)), 50 ether);
        assertEq(scopeSL.balanceOf(address(burn)), 0);
        assertEq(scopeST.balanceOf(address(burn)), 0);

        BurnStats memory accountRound = burn.accountRoundBurnStats(alice, address(scopeToken), 5);
        assertEq(accountRound.slTokenLock.amount, 100 ether);
        assertEq(accountRound.slTokenLock.score, 103.6324 ether);
        assertEq(accountRound.stTokenLock.amount, 50 ether);
        assertEq(accountRound.stTokenLock.score, 51.8162 ether);

        BurnStats memory accountTotal = burn.accountBurnStats(alice, address(scopeToken));
        BurnStats memory communityTotal = burn.communityBurnStats(address(scopeToken));
        assertEq(accountTotal.slTokenLock.score, 103.6324 ether);
        assertEq(communityTotal.slTokenLock.amount, 100 ether);
        assertEq(communityTotal.stTokenLock.amount, 50 ether);

        assertEq(burn.participantsCount(), 1);
        assertTrue(burn.isParticipant(alice));
        address[] memory page = burn.participants(0, 10);
        assertEq(page.length, 1);
        assertEq(page[0], alice);
        assertEq(burn.participants(0, 0).length, 0);
        assertEq(burn.participants(2, 10).length, 0);
    }

    function test_BurnStatsThroughRoundUsesSparseCumulativeCheckpoints() public {
        scopeSL.mint(alice, 6 ether);
        scopeSL.mint(bob, 3 ether);
        scopeST.mint(alice, 4 ether);

        vm.startPrank(alice);
        scopeSL.approve(address(burn), type(uint256).max);
        scopeST.approve(address(burn), type(uint256).max);
        verify.setCurrentRound(6);
        burn.lockSLToken(address(scopeToken), 5, 1 ether);
        burn.lockSLToken(address(scopeToken), 5, 1 ether);
        vm.stopPrank();

        verify.setCurrentRound(7);
        vm.prank(bob);
        scopeSL.approve(address(burn), type(uint256).max);
        vm.prank(bob);
        burn.lockSLToken(address(scopeToken), 6, 3 ether);
        vm.prank(alice);
        burn.lockSTToken(address(scopeToken), 6, 4 ether);

        verify.setCurrentRound(8);
        vm.prank(alice);
        burn.lockSLToken(address(scopeToken), 7, 4 ether);

        BurnStats memory beforeActivity = burn.accountBurnStatsThroughRound(alice, address(scopeToken), 4);
        assertEq(beforeActivity.slTokenLock.amount, 0);

        BurnStats memory aliceRound5 = burn.accountBurnStatsThroughRound(alice, address(scopeToken), 5);
        assertEq(aliceRound5.slTokenLock.amount, 2 ether);
        assertEq(aliceRound5.slTokenLock.score, 2.072648 ether);
        assertEq(aliceRound5.stTokenLock.amount, 0);
        assertEq(aliceRound5.stTokenLock.score, 0);

        BurnStats memory aliceRound6 = burn.accountBurnStatsThroughRound(alice, address(scopeToken), 6);
        assertEq(aliceRound6.slTokenLock.amount, 2 ether);
        assertEq(aliceRound6.slTokenLock.score, 2.072648 ether);
        assertEq(aliceRound6.stTokenLock.amount, 4 ether);
        assertEq(aliceRound6.stTokenLock.score, 4.072 ether);

        BurnStats memory aliceRound7 = burn.accountBurnStatsThroughRound(alice, address(scopeToken), 7);
        assertEq(aliceRound7.slTokenLock.amount, 6 ether);
        assertEq(aliceRound7.slTokenLock.score, 6.072648 ether);
        assertEq(aliceRound7.stTokenLock.amount, 4 ether);
        assertEq(aliceRound7.stTokenLock.score, 4.072 ether);
        assertEq(burn.accountBurnStatsThroughRound(alice, address(scopeToken), 100).slTokenLock.amount, 6 ether);

        assertEq(burn.accountBurnStatsThroughRound(bob, address(scopeToken), 5).slTokenLock.amount, 0);
        assertEq(burn.accountBurnStatsThroughRound(bob, address(scopeToken), 6).slTokenLock.amount, 3 ether);
        assertEq(burn.accountBurnStatsThroughRound(bob, address(scopeToken), 6).slTokenLock.score, 3.054 ether);

        BurnStats memory communityRound5 = burn.communityBurnStatsThroughRound(address(scopeToken), 5);
        assertEq(communityRound5.slTokenLock.amount, 2 ether);
        assertEq(communityRound5.slTokenLock.score, 2.072648 ether);
        assertEq(communityRound5.stTokenLock.amount, 0);

        BurnStats memory communityRound6 = burn.communityBurnStatsThroughRound(address(scopeToken), 6);
        assertEq(communityRound6.slTokenLock.amount, 5 ether);
        assertEq(communityRound6.slTokenLock.score, 5.126648 ether);
        assertEq(communityRound6.stTokenLock.amount, 4 ether);
        assertEq(communityRound6.stTokenLock.score, 4.072 ether);

        BurnStats memory communityRound7 = burn.communityBurnStatsThroughRound(address(scopeToken), 7);
        assertEq(communityRound7.slTokenLock.amount, 9 ether);
        assertEq(communityRound7.slTokenLock.score, 9.126648 ether);
        assertEq(communityRound7.stTokenLock.amount, 4 ether);
        assertEq(communityRound7.stTokenLock.score, 4.072 ether);

        assertEq(burn.accountRoundBurnStats(alice, address(scopeToken), 6).slTokenLock.amount, 0);
        assertEq(burn.accountRoundBurnStats(alice, address(scopeToken), 6).stTokenLock.amount, 4 ether);
    }

    function test_BurnStatsThroughRoundStaysEfficientWith128Rounds() public {
        uint256 rounds = 128;
        Burn longBurn =
            new Burn(address(center), "SCOPE", address(0), _communityWeights(), 5, rounds, 5, new address[](0));
        scopeSL.mint(alice, rounds * 1 ether);

        uint256 earlyWriteGas;
        uint256 lateWriteGas;
        vm.startPrank(alice);
        scopeSL.approve(address(longBurn), type(uint256).max);
        for (uint256 i; i < rounds; ++i) {
            uint256 round = 5 + i;
            verify.setCurrentRound(round + 1);
            uint256 gasBefore = gasleft();
            longBurn.lockSLToken(address(scopeToken), round, 1 ether);
            uint256 gasUsed = gasBefore - gasleft();
            if (i == 1) earlyWriteGas = gasUsed;
            if (i == rounds - 1) lateWriteGas = gasUsed;
        }
        vm.stopPrank();

        uint256 accountGasBefore = gasleft();
        BurnStats memory accountMid = longBurn.accountBurnStatsThroughRound(alice, address(scopeToken), 68);
        uint256 accountQueryGas = accountGasBefore - gasleft();
        assertEq(accountMid.slTokenLock.amount, 64 ether);

        uint256 communityGasBefore = gasleft();
        BurnStats memory communityMid = longBurn.communityBurnStatsThroughRound(address(scopeToken), 68);
        uint256 communityQueryGas = communityGasBefore - gasleft();
        assertEq(communityMid.slTokenLock.amount, 64 ether);

        assertEq(longBurn.accountBurnStatsThroughRound(alice, address(scopeToken), 132).slTokenLock.amount, 128 ether);
        assertEq(
            longBurn.accountBurnStatsThroughRound(alice, address(scopeToken), 1_000_000).slTokenLock.amount, 128 ether
        );
        emit log_named_uint("checkpoint write gas at round 6", earlyWriteGas);
        emit log_named_uint("checkpoint write gas at round 132", lateWriteGas);
        emit log_named_uint("account cumulative query gas at 128 rounds", accountQueryGas);
        emit log_named_uint("community cumulative query gas at 128 rounds", communityQueryGas);
        assertLt(lateWriteGas, earlyWriteGas * 2, "checkpoint writes must remain O(1)");
        assertLt(accountQueryGas, 100_000, "account checkpoint query is too expensive at 128 rounds");
        assertLt(communityQueryGas, 100_000, "community checkpoint query is too expensive at 128 rounds");
    }

    function test_DirectReceiptTransfersDoNotRecordBurnStatsOrParticipants() public {
        scopeSL.mint(alice, 10 ether);
        scopeST.mint(alice, 20 ether);

        vm.startPrank(alice);
        scopeSL.transfer(address(scopeToken), 10 ether);
        scopeST.transfer(address(scopeToken), 20 ether);
        vm.stopPrank();

        assertEq(scopeSL.balanceOf(address(scopeToken)), 10 ether);
        assertEq(scopeST.balanceOf(address(scopeToken)), 20 ether);
        BurnStats memory stats = burn.communityBurnStats(address(scopeToken));
        assertEq(stats.slTokenLock.amount, 0);
        assertEq(stats.slTokenLock.score, 0);
        assertEq(stats.stTokenLock.amount, 0);
        assertEq(stats.stTokenLock.score, 0);
        assertEq(burn.participantsCount(), 0);
        assertFalse(burn.isParticipant(alice));
    }

    function test_SLTokenLockedEventContainsOperationAndLifetimeTotals() public {
        scopeSL.mint(alice, 10 ether);
        verify.setCurrentRound(6);

        vm.startPrank(alice);
        scopeSL.approve(address(burn), 10 ether);
        vm.expectEmit(true, true, true, true, address(burn));
        emit SLTokenLocked(
            address(scopeToken),
            alice,
            5,
            10 ether,
            1.036324 ether,
            10.36324 ether,
            10 ether,
            10.36324 ether,
            10 ether,
            10.36324 ether
        );
        burn.lockSLToken(address(scopeToken), 5, 10 ether);
        vm.stopPrank();
    }

    function test_OtherBurnEventsContainOperationAndLifetimeTotals() public {
        uint256 actionId = 9;
        scopeST.mint(alice, 10 ether);
        scopeToken.transfer(alice, 10 ether);
        mint.setGovReward(address(scopeToken), 5, alice, 1 ether, 1 ether, 0, true);
        mint.setActionReward(address(scopeToken), 5, actionId, alice, 2 ether, true);
        verify.setCurrentRound(6);

        vm.startPrank(alice);
        scopeST.approve(address(burn), 10 ether);
        scopeToken.approve(address(burn), 10 ether);

        vm.expectEmit(true, true, true, true, address(burn));
        emit STTokenLocked(
            address(scopeToken),
            alice,
            5,
            10 ether,
            1.036324 ether,
            10.36324 ether,
            10 ether,
            10.36324 ether,
            10 ether,
            10.36324 ether
        );
        burn.lockSTToken(address(scopeToken), 5, 10 ether);

        vm.expectEmit(true, true, true, true, address(burn));
        emit GovRewardTokenBurned(
            address(scopeToken),
            alice,
            5,
            5 ether,
            1.036324 ether,
            5.18162 ether,
            5 ether,
            5.18162 ether,
            5 ether,
            5.18162 ether
        );
        burn.burnGovRewardToken(address(scopeToken), 5, 5 ether);

        ActionRewardBurnRequest[] memory requests = new ActionRewardBurnRequest[](1);
        requests[0] = ActionRewardBurnRequest(address(scopeToken), actionId, 5 ether);
        vm.expectEmit(true, true, true, true, address(burn));
        emit ActionRewardTokenBurned(
            address(scopeToken),
            alice,
            5,
            actionId,
            address(0),
            5 ether,
            1.036324 ether,
            5.18162 ether,
            5 ether,
            5.18162 ether,
            5 ether,
            5.18162 ether
        );
        burn.burnActionRewardTokens(5, requests);
        vm.stopPrank();

        TokenShare memory share = burn.accountTokenShare(alice, address(scopeToken));
        uint256 third = uint256(1 ether) / 3;
        assertEq(share.stTokenLock, third);
        assertEq(share.govRewardBurn, third);
        assertEq(share.actionRewardBurn, third);
    }

    function test_SplitAndSingleLockProduceSameScore() public {
        scopeSL.mint(alice, 100 ether);
        scopeSL.mint(bob, 100 ether);
        verify.setCurrentRound(6);

        vm.startPrank(alice);
        scopeSL.approve(address(burn), type(uint256).max);
        burn.lockSLToken(address(scopeToken), 5, 30 ether);
        burn.lockSLToken(address(scopeToken), 5, 70 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        scopeSL.approve(address(burn), type(uint256).max);
        burn.lockSLToken(address(scopeToken), 5, 100 ether);
        vm.stopPrank();

        assertEq(
            burn.accountRoundBurnStats(alice, address(scopeToken), 5).slTokenLock.score,
            burn.accountRoundBurnStats(bob, address(scopeToken), 5).slTokenLock.score
        );
        assertEq(burn.participantsCount(), 2);
    }

    function test_GovRewardBurnUsesOnlyActualMintedRewardQuota() public {
        mint.setGovReward(address(scopeToken), 5, alice, 70 ether, 30 ether, 10 ether, false);
        assertEq(burn.govRewardBurnState(alice, address(scopeToken), 5).claimableRewardAmount, 100 ether);
        assertEq(burn.govRewardBurnState(alice, address(scopeToken), 5).burnQuotaAmount, 0);

        mint.setGovReward(address(scopeToken), 5, alice, 70 ether, 30 ether, 10 ether, true);
        scopeToken.transfer(alice, 500 ether);
        verify.setCurrentRound(6);

        vm.startPrank(alice);
        scopeToken.approve(address(burn), type(uint256).max);
        burn.burnGovRewardToken(address(scopeToken), 5, 120 ether);

        vm.expectRevert(abi.encodeWithSelector(IBurnErrors.BurnQuotaExceeded.selector, 380 ether, 381 ether));
        burn.burnGovRewardToken(address(scopeToken), 5, 381 ether);

        burn.burnGovRewardToken(address(scopeToken), 5, 380 ether);
        vm.stopPrank();

        assertEq(scopeToken.balanceOf(alice), 0);
        assertEq(scopeToken.totalSupply(), INITIAL_SUPPLY - 500 ether);

        BurnStats memory stats = burn.accountRoundBurnStats(alice, address(scopeToken), 5);
        assertEq(stats.govRewardBurn.amount, 500 ether);
        assertEq(stats.govRewardBurn.score, 518.162 ether);

        assertTrue(burn.govRewardBurnState(alice, address(scopeToken), 5).isClaimed);
        assertEq(burn.govRewardBurnState(alice, address(scopeToken), 5).claimedRewardAmount, 100 ether);
        assertEq(burn.govRewardBurnState(alice, address(scopeToken), 5).burnedAmount, 500 ether);
        assertEq(burn.govRewardBurnState(alice, address(scopeToken), 5).unusedQuotaAmount, 0);
    }

    function test_RewardQuotaExpiresAcrossRoundsButHistoricalStateRemains() public {
        uint256 actionId = 10;
        mint.setGovReward(address(scopeToken), 5, alice, 100 ether, 0, 0, true);
        mint.setActionReward(address(scopeToken), 5, actionId, alice, 100 ether, true);
        vote.setVotedActionId(address(scopeToken), 5, actionId);
        scopeToken.transfer(alice, 200 ether);
        verify.setCurrentRound(6);

        ActionRewardBurnRequest[] memory requests = new ActionRewardBurnRequest[](1);
        requests[0] = ActionRewardBurnRequest(address(scopeToken), actionId, 100 ether);
        vm.startPrank(alice);
        scopeToken.approve(address(burn), 200 ether);
        burn.burnGovRewardToken(address(scopeToken), 5, 100 ether);
        burn.burnActionRewardTokens(5, requests);

        verify.setCurrentRound(7);
        vm.expectRevert(abi.encodeWithSelector(IBurnErrors.RoundNotOpen.selector, 5, 7));
        burn.burnGovRewardToken(address(scopeToken), 5, 1 ether);
        requests[0].amount = 1 ether;
        vm.expectRevert(abi.encodeWithSelector(IBurnErrors.RoundNotOpen.selector, 5, 7));
        burn.burnActionRewardTokens(5, requests);

        vm.expectRevert(IBurnErrors.NoClaimedReward.selector);
        burn.burnGovRewardToken(address(scopeToken), 6, 1 ether);
        vm.expectRevert(IBurnErrors.NoClaimedReward.selector);
        burn.burnActionRewardTokens(6, requests);
        vm.stopPrank();

        assertEq(burn.govRewardBurnState(alice, address(scopeToken), 5).burnedAmount, 100 ether);
        assertEq(burn.govRewardBurnState(alice, address(scopeToken), 5).unusedQuotaAmount, 400 ether);
        ActionRewardBurnState[] memory states = burn.actionRewardBurnStates(alice, address(scopeToken), 5);
        assertEq(states.length, 1);
        assertEq(states[0].reward.burnedAmount, 100 ether);
        assertEq(states[0].reward.unusedQuotaAmount, 400 ether);
    }

    function test_BaseActionBatchAccumulatesDuplicateSourceQuota() public {
        uint256 actionId = 11;
        vote.setVotedActionId(address(scopeToken), 5, actionId);
        mint.setActionReward(address(scopeToken), 5, actionId, alice, 100 ether, true);
        scopeToken.transfer(alice, 500 ether);
        verify.setCurrentRound(6);

        ActionRewardBurnRequest[] memory requests = new ActionRewardBurnRequest[](2);
        requests[0] = ActionRewardBurnRequest(address(scopeToken), actionId, 200 ether);
        requests[1] = ActionRewardBurnRequest(address(scopeToken), actionId, 300 ether);

        vm.startPrank(alice);
        scopeToken.approve(address(burn), type(uint256).max);
        burn.burnActionRewardTokens(5, requests);
        vm.stopPrank();

        BurnStats memory stats = burn.accountRoundBurnStats(alice, address(scopeToken), 5);
        assertEq(stats.actionRewardBurn.amount, 500 ether);
        assertEq(stats.actionRewardBurn.score, 518.162 ether);

        ActionRewardBurnState[] memory states = burn.actionRewardBurnStates(alice, address(scopeToken), 5);
        assertEq(states.length, 1);
        assertEq(states[0].actionId, actionId);
        assertEq(states[0].extensionAddress, address(0));
        assertTrue(states[0].reward.isClaimed);
        assertEq(states[0].reward.claimedRewardAmount, 100 ether);
        assertEq(states[0].reward.burnQuotaAmount, 500 ether);
        assertEq(states[0].reward.burnedAmount, 500 ether);
        assertEq(states[0].reward.unusedQuotaAmount, 0);
    }

    function test_ExtensionActionUsesClaimedMintRewardAndSkipsUnsupported() public {
        MockExtensionFactory factory = new MockExtensionFactory();
        MockReward reward = new MockReward();
        MockRevertingReward unsupportedReward = new MockRevertingReward();
        uint256 supportedActionId = 22;
        uint256 unsupportedActionId = 23;
        address[] memory factories = new address[](1);
        factories[0] = address(factory);
        Burn extensionBurn = _deployBurnWithFactories(factories);

        center.setExtension(address(scopeToken), supportedActionId, address(reward), address(factory));
        center.setExtension(address(scopeToken), unsupportedActionId, address(unsupportedReward), address(0xBAD));
        vote.setVotedActionId(address(scopeToken), 5, supportedActionId);
        vote.setVotedActionId(address(scopeToken), 5, unsupportedActionId);
        reward.setReward(5, alice, 40 ether, 10 ether, true);
        scopeToken.transfer(alice, 200 ether);
        verify.setCurrentRound(6);

        ActionRewardBurnRequest[] memory requests = new ActionRewardBurnRequest[](1);
        requests[0] = ActionRewardBurnRequest(address(scopeToken), supportedActionId, 200 ether);
        vm.startPrank(alice);
        scopeToken.approve(address(extensionBurn), type(uint256).max);
        extensionBurn.burnActionRewardTokens(5, requests);
        vm.stopPrank();

        ActionRewardBurnState[] memory states = extensionBurn.actionRewardBurnStates(alice, address(scopeToken), 5);
        assertEq(states.length, 1);
        assertEq(states[0].actionId, supportedActionId);
        assertEq(states[0].extensionAddress, address(reward));
        assertEq(states[0].reward.claimedRewardAmount, 40 ether);
        assertEq(states[0].reward.burnQuotaAmount, 200 ether);
        assertEq(states[0].reward.burnedAmount, 200 ether);

        requests[0] = ActionRewardBurnRequest(address(scopeToken), unsupportedActionId, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBurnErrors.UnsupportedExtensionFactory.selector, address(0xBAD)));
        extensionBurn.burnActionRewardTokens(5, requests);
    }

    function test_SharesRenormalizeByActiveCommunityCategoryAndScore() public {
        scopeSL.mint(alice, 100 ether);
        scopeSL.mint(bob, 100 ether);
        childSL.mint(bob, 100 ether);
        verify.setCurrentRound(6);

        vm.startPrank(alice);
        scopeSL.approve(address(burn), type(uint256).max);
        burn.lockSLToken(address(scopeToken), 5, 100 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        scopeSL.approve(address(burn), type(uint256).max);
        childSL.approve(address(burn), type(uint256).max);
        burn.lockSLToken(address(scopeToken), 5, 100 ether);
        burn.lockSLToken(address(childToken), 5, 100 ether);
        vm.stopPrank();

        TokenShare memory aliceScope = burn.accountTokenShare(alice, address(scopeToken));
        TokenShare memory bobScope = burn.accountTokenShare(bob, address(scopeToken));
        TokenShare memory bobChild = burn.accountTokenShare(bob, address(childToken));
        assertEq(aliceScope.slTokenLock, 0.3 ether);
        assertEq(aliceScope.total, 0.3 ether);
        assertEq(bobScope.total, 0.3 ether);
        assertEq(bobChild.total, 0.4 ether);
        assertFalse(aliceScope.finalized);

        (uint256 aliceShare, bool aliceFinalized) = burn.accountShare(alice);
        (uint256 bobShare, bool bobFinalized) = burn.accountShare(bob);
        assertEq(aliceShare, 0.3 ether);
        assertEq(bobShare, 0.7 ether);
        assertFalse(aliceFinalized);
        assertFalse(bobFinalized);

        verify.setCurrentRound(9);
        (aliceShare, aliceFinalized) = burn.accountShare(alice);
        assertEq(aliceShare, 0.3 ether);
        assertTrue(aliceFinalized);
    }

    function test_NoParticipationReturnsZeroSharesAndEmptyParticipants() public {
        TokenShare memory tokenShare = burn.accountTokenShare(alice, address(scopeToken));
        assertEq(tokenShare.slTokenLock, 0);
        assertEq(tokenShare.stTokenLock, 0);
        assertEq(tokenShare.govRewardBurn, 0);
        assertEq(tokenShare.actionRewardBurn, 0);
        assertEq(tokenShare.total, 0);
        assertFalse(tokenShare.finalized);

        (uint256 share, bool finalized) = burn.accountShare(alice);
        assertEq(share, 0);
        assertFalse(finalized);
        assertEq(burn.participantsCount(), 0);
        assertEq(burn.participants(0, 10).length, 0);

        verify.setCurrentRound(9);
        (share, finalized) = burn.accountShare(alice);
        assertEq(share, 0);
        assertTrue(finalized);
    }

    function test_ShareTotalsPreserveRoundedComponentSums() public {
        address carol = address(0xCA401);
        scopeSL.mint(alice, 1 ether);
        scopeSL.mint(bob, 1 ether);
        scopeSL.mint(carol, 1 ether);
        verify.setCurrentRound(6);

        _lockScopeSL(burn, alice, 1 ether);
        _lockScopeSL(burn, bob, 1 ether);
        _lockScopeSL(burn, carol, 1 ether);

        TokenShare memory aliceTokenShare = burn.accountTokenShare(alice, address(scopeToken));
        TokenShare memory bobTokenShare = burn.accountTokenShare(bob, address(scopeToken));
        TokenShare memory carolTokenShare = burn.accountTokenShare(carol, address(scopeToken));
        uint256 roundedThird = uint256(1 ether) / 3;
        assertEq(aliceTokenShare.slTokenLock, roundedThird);
        assertEq(aliceTokenShare.total, aliceTokenShare.slTokenLock);
        assertEq(bobTokenShare.total, roundedThird);
        assertEq(carolTokenShare.total, roundedThird);

        (uint256 aliceShare,) = burn.accountShare(alice);
        (uint256 bobShare,) = burn.accountShare(bob);
        (uint256 carolShare,) = burn.accountShare(carol);
        assertEq(aliceShare, aliceTokenShare.total);
        assertEq(aliceShare + bobShare + carolShare, 1 ether - 1);
    }

    function test_AirdropUsesCurrentBalanceAndRemainingShare() public {
        MockERC20 airdropToken = new MockERC20("Airdrop", "AIR");
        Burn airdropBurn = _deployBurnWithAirdrop(address(airdropToken), new address[](0));
        AirdropState memory disabledState = burn.accountAirdropState(alice);
        assertFalse(disabledState.enabled);
        assertEq(disabledState.claimableAmount, 0);
        scopeSL.mint(alice, 20 ether);
        scopeSL.mint(bob, 80 ether);
        verify.setCurrentRound(6);

        vm.startPrank(alice);
        scopeSL.approve(address(airdropBurn), type(uint256).max);
        airdropBurn.lockSLToken(address(scopeToken), 5, 20 ether);
        vm.stopPrank();
        vm.startPrank(bob);
        scopeSL.approve(address(airdropBurn), type(uint256).max);
        airdropBurn.lockSLToken(address(scopeToken), 5, 80 ether);
        vm.stopPrank();

        AirdropState memory pendingState = airdropBurn.accountAirdropState(alice);
        assertTrue(pendingState.enabled);
        assertFalse(pendingState.shareFinalized);
        assertEq(pendingState.share, 0.2 ether);
        assertEq(pendingState.claimableAmount, 0);

        airdropToken.mint(address(airdropBurn), 1_000 ether);
        verify.setCurrentRound(9);
        AirdropState memory aliceState = airdropBurn.accountAirdropState(alice);
        assertTrue(aliceState.enabled);
        assertTrue(aliceState.shareFinalized);
        assertEq(aliceState.share, 0.2 ether);
        assertEq(aliceState.claimableAmount, 200 ether);

        vm.prank(alice);
        assertEq(airdropBurn.claimAirdrop(), 200 ether);
        assertEq(airdropToken.balanceOf(alice), 200 ether);
        assertEq(airdropBurn.remainingAirdropShare(), 0.8 ether);
        assertTrue(airdropBurn.accountAirdropState(alice).isClaimed);
        assertEq(airdropBurn.accountAirdropState(alice).claimableAmount, 0);
        assertEq(airdropBurn.accountAirdropState(alice).claimedAmount, 200 ether);

        airdropToken.mint(address(airdropBurn), 100 ether);
        assertEq(airdropBurn.accountAirdropState(bob).claimableAmount, 900 ether);
        vm.prank(bob);
        assertEq(airdropBurn.claimAirdrop(), 900 ether);
        assertEq(airdropToken.balanceOf(bob), 900 ether);
        assertEq(airdropBurn.remainingAirdropShare(), 0);

        vm.prank(alice);
        vm.expectRevert(IBurnErrors.AirdropAlreadyClaimed.selector);
        airdropBurn.claimAirdrop();

        vm.expectRevert(IBurnErrors.AirdropDisabled.selector);
        burn.claimAirdrop();
    }

    function test_AirdropTokenCanBeParticipatingChildCommunity() public {
        Burn airdropBurn = _deployBurnWithAirdrop(address(childToken), new address[](0));
        childSL.mint(alice, 1 ether);
        verify.setCurrentRound(6);

        vm.startPrank(alice);
        childSL.approve(address(airdropBurn), 1 ether);
        airdropBurn.lockSLToken(address(childToken), 5, 1 ether);
        vm.stopPrank();

        childToken.transfer(address(airdropBurn), 100 ether);
        verify.setCurrentRound(9);
        assertEq(airdropBurn.accountAirdropState(alice).claimableAmount, 100 ether);

        vm.prank(alice);
        assertEq(airdropBurn.claimAirdrop(), 100 ether);
        assertEq(childToken.balanceOf(alice), 100 ether);
        assertEq(childToken.balanceOf(address(airdropBurn)), 0);
    }

    function test_AirdropClaimOrderOnlyChangesRoundingAndPostClaimFundsRemain() public {
        MockERC20 firstToken = new MockERC20("First Airdrop", "AIR1");
        MockERC20 secondToken = new MockERC20("Second Airdrop", "AIR2");
        Burn firstBurn = _deployBurnWithAirdrop(address(firstToken), new address[](0));
        Burn secondBurn = _deployBurnWithAirdrop(address(secondToken), new address[](0));
        scopeSL.mint(alice, 2 ether);
        scopeSL.mint(bob, 4 ether);
        verify.setCurrentRound(6);

        _lockScopeSL(firstBurn, alice, 1 ether);
        _lockScopeSL(secondBurn, alice, 1 ether);
        _lockScopeSL(firstBurn, bob, 2 ether);
        _lockScopeSL(secondBurn, bob, 2 ether);

        firstToken.mint(address(firstBurn), 10 ether);
        secondToken.mint(address(secondBurn), 10 ether);
        verify.setCurrentRound(9);

        vm.prank(alice);
        uint256 aliceFirst = firstBurn.claimAirdrop();
        vm.prank(bob);
        uint256 bobSecond = firstBurn.claimAirdrop();
        vm.prank(bob);
        uint256 bobFirst = secondBurn.claimAirdrop();
        vm.prank(alice);
        uint256 aliceSecond = secondBurn.claimAirdrop();

        assertApproxEqAbs(aliceFirst, aliceSecond, 10);
        assertApproxEqAbs(bobFirst, bobSecond, 10);
        uint256 strandedBefore = firstToken.balanceOf(address(firstBurn));
        firstToken.mint(address(firstBurn), 1 ether);
        assertEq(firstToken.balanceOf(address(firstBurn)), strandedBefore + 1 ether);
        vm.prank(alice);
        vm.expectRevert(IBurnErrors.AirdropAlreadyClaimed.selector);
        firstBurn.claimAirdrop();
        vm.prank(bob);
        vm.expectRevert(IBurnErrors.AirdropAlreadyClaimed.selector);
        firstBurn.claimAirdrop();
        assertEq(firstToken.balanceOf(address(firstBurn)), strandedBefore + 1 ether);
    }

    function test_AirdropReentrancyRevertsWithoutChangingState() public {
        MockReentrantAirdropToken airdropToken = new MockReentrantAirdropToken();
        Burn airdropBurn = _deployBurnWithAirdrop(address(airdropToken), new address[](0));
        airdropToken.setBurn(address(airdropBurn));
        scopeSL.mint(alice, 1 ether);
        verify.setCurrentRound(6);

        vm.startPrank(alice);
        scopeSL.approve(address(airdropBurn), 1 ether);
        airdropBurn.lockSLToken(address(scopeToken), 5, 1 ether);
        vm.stopPrank();

        airdropToken.mint(address(airdropBurn), 100 ether);
        airdropToken.setReenter(true);
        verify.setCurrentRound(9);

        vm.prank(alice);
        vm.expectRevert(bytes("ReentrancyGuard: reentrant call"));
        airdropBurn.claimAirdrop();

        assertEq(airdropToken.balanceOf(address(airdropBurn)), 100 ether);
        assertEq(airdropToken.balanceOf(alice), 0);
        assertEq(airdropBurn.remainingAirdropShare(), 1 ether);
        assertEq(airdropBurn.accountAirdropState(alice).claimedAmount, 0);
    }

    function test_AirdropTransferFailureAndZeroAmountLeaveStateUnchanged() public {
        MockFailingAirdropToken airdropToken = new MockFailingAirdropToken();
        Burn airdropBurn = _deployBurnWithAirdrop(address(airdropToken), new address[](0));
        scopeSL.mint(alice, 2);
        scopeSL.mint(bob, 1 ether);
        verify.setCurrentRound(6);

        vm.startPrank(alice);
        scopeSL.approve(address(airdropBurn), 2);
        airdropBurn.lockSLToken(address(scopeToken), 5, 2);
        vm.stopPrank();
        vm.startPrank(bob);
        scopeSL.approve(address(airdropBurn), 1 ether);
        airdropBurn.lockSLToken(address(scopeToken), 5, 1 ether);
        vm.stopPrank();

        airdropToken.mint(address(airdropBurn), 1);
        verify.setCurrentRound(9);
        vm.prank(alice);
        vm.expectRevert(IBurnErrors.NoClaimableAirdrop.selector);
        airdropBurn.claimAirdrop();
        assertEq(airdropBurn.remainingAirdropShare(), 1 ether);

        airdropToken.mint(address(airdropBurn), 1 ether);
        airdropToken.setFailTransfers(true);
        vm.prank(bob);
        vm.expectRevert(bytes("airdrop transfer failed"));
        airdropBurn.claimAirdrop();
        assertEq(airdropBurn.remainingAirdropShare(), 1 ether);
        assertEq(airdropBurn.accountAirdropState(bob).claimedAmount, 0);
    }

    function test_ConstructorRejectsInvalidCommunityConfiguration() public {
        CommunityWeight[] memory weights = new CommunityWeight[](1);
        weights[0] = CommunityWeight("CHILD", 1);
        vm.expectRevert(IBurnErrors.MissingScopeCommunity.selector);
        new Burn(address(center), "SCOPE", address(0), weights, 5, 3, 5, new address[](0));

        weights[0] = CommunityWeight("SCOPE", 0);
        vm.expectRevert(abi.encodeWithSelector(IBurnErrors.InvalidCommunityConfig.selector, "SCOPE"));
        new Burn(address(center), "SCOPE", address(0), weights, 5, 3, 5, new address[](0));

        weights = new CommunityWeight[](2);
        weights[0] = CommunityWeight("SCOPE", 1);
        weights[1] = CommunityWeight("SCOPE", 2);
        vm.expectRevert(abi.encodeWithSelector(IBurnErrors.DuplicateCommunity.selector, "SCOPE"));
        new Burn(address(center), "SCOPE", address(0), weights, 5, 3, 5, new address[](0));

        MockLOVE20Token unfinishedToken = new MockLOVE20Token(
            "UNFINISHED", INITIAL_SUPPLY, MAX_SUPPLY, address(scopeToken), address(0x51), address(0x52)
        );
        launch.setToken(address(unfinishedToken), address(scopeToken), false);
        weights[1] = CommunityWeight("UNFINISHED", 2);
        vm.expectRevert(abi.encodeWithSelector(IBurnErrors.InvalidCommunityConfig.selector, "UNFINISHED"));
        new Burn(address(center), "SCOPE", address(0), weights, 5, 3, 5, new address[](0));

        MockLOVE20Token grandchildToken = new MockLOVE20Token(
            "GRANDCHILD", INITIAL_SUPPLY, MAX_SUPPLY, address(childToken), address(0x61), address(0x62)
        );
        launch.setToken(address(grandchildToken), address(childToken), true);
        weights[1] = CommunityWeight("GRANDCHILD", 2);
        vm.expectRevert(abi.encodeWithSelector(IBurnErrors.InvalidCommunityConfig.selector, "GRANDCHILD"));
        new Burn(address(center), "SCOPE", address(0), weights, 5, 3, 5, new address[](0));

        vm.expectRevert(abi.encodeWithSelector(IBurnErrors.InvalidAirdropToken.selector, address(scopeToken)));
        new Burn(address(center), "SCOPE", address(scopeToken), _communityWeights(), 5, 3, 5, new address[](0));
    }

    function test_ConstructorAcceptsChildAsScopeAndRejectsInvalidScopeAndEmptyCommunities() public {
        MockLOVE20Token grandchildToken = new MockLOVE20Token(
            "GRANDCHILD", INITIAL_SUPPLY, MAX_SUPPLY, address(childToken), address(0x71), address(0x72)
        );
        launch.setToken(address(grandchildToken), address(childToken), true);
        CommunityWeight[] memory childScopeWeights = new CommunityWeight[](2);
        childScopeWeights[0] = CommunityWeight("CHILD", 3);
        childScopeWeights[1] = CommunityWeight("GRANDCHILD", 1);
        Burn childScopeBurn =
            new Burn(address(center), "CHILD", address(0), childScopeWeights, 5, 3, 5, new address[](0));
        assertEq(childScopeBurn.scopeTokenSymbol(), "CHILD");
        assertEq(childScopeBurn.scopeTokenAddress(), address(childToken));
        assertEq(childScopeBurn.communities().length, 2);

        vm.expectRevert(abi.encodeWithSelector(IBurnErrors.InvalidScopeToken.selector, "UNKNOWN"));
        new Burn(address(center), "UNKNOWN", address(0), childScopeWeights, 5, 3, 5, new address[](0));

        vm.expectRevert(IBurnErrors.MissingScopeCommunity.selector);
        new Burn(address(center), "SCOPE", address(0), new CommunityWeight[](0), 5, 3, 5, new address[](0));
    }

    function test_DeploymentValidationFailsClosedForMismatchesAndUnreadableAirdrop() public {
        DeployBurn deployer = new DeployBurn();
        BurnDeploymentConfig memory config = _deploymentConfig(address(0));
        assertEq(deployer.validationFailureCount(burn, config), 0);

        config.scopeTokenSymbol = "CHILD";
        assertGt(deployer.validationFailureCount(burn, config), 0);
        config.scopeTokenSymbol = "SCOPE";
        config.communities[0].weight = 601;
        assertGt(deployer.validationFailureCount(burn, config), 0);
        config.communities[0].weight = 600;

        config.startRound = 6;
        assertGt(deployer.validationFailureCount(burn, config), 0);
        config.startRound = 5;
        config.roundCount = 4;
        assertGt(deployer.validationFailureCount(burn, config), 0);
        config.roundCount = 3;
        config.quotaMultiplier = 6;
        assertGt(deployer.validationFailureCount(burn, config), 0);
        config.quotaMultiplier = 5;

        MockExtensionCenter otherCenter =
            new MockExtensionCenter(address(launch), address(vote), address(verify), address(mint));
        config.extensionCenterAddress = address(otherCenter);
        assertGt(deployer.validationFailureCount(burn, config), 0);
        config.extensionCenterAddress = address(center);

        scopeToken.mint(address(this), 1 ether);
        assertEq(deployer.validationFailureCount(burn, config), 0);

        MockUnreadableAirdropToken unreadable = new MockUnreadableAirdropToken();
        Burn unreadableBurn = _deployBurnWithAirdrop(address(unreadable), new address[](0));
        BurnDeploymentConfig memory unreadableConfig = _deploymentConfig(address(unreadable));
        assertGt(deployer.validationFailureCount(unreadableBurn, unreadableConfig), 0);
    }

    function test_WritesRejectZeroAndUnclaimedReward() public {
        scopeSL.mint(alice, 1 ether);
        vm.startPrank(alice);
        scopeSL.approve(address(burn), type(uint256).max);

        vm.expectRevert(IBurnErrors.ZeroAmount.selector);
        burn.lockSLToken(address(scopeToken), 5, 0);

        verify.setCurrentRound(6);
        vm.expectRevert(IBurnErrors.NoClaimedReward.selector);
        burn.burnGovRewardToken(address(scopeToken), 5, 1 ether);
        vm.stopPrank();
    }

    function test_AllRoundWritesRejectFutureAndExpiredRounds() public {
        _expectAllRoundWritesClosed(6, 5);
        verify.setCurrentRound(7);
        _expectAllRoundWritesClosed(5, 7);
    }

    function test_ActionBatchRevertsAtomicallyWhenLaterItemExceedsQuota() public {
        uint256 actionId = 31;
        mint.setActionReward(address(scopeToken), 5, actionId, alice, 100 ether, true);
        scopeToken.transfer(alice, 501 ether);
        verify.setCurrentRound(6);

        ActionRewardBurnRequest[] memory requests = new ActionRewardBurnRequest[](2);
        requests[0] = ActionRewardBurnRequest(address(scopeToken), actionId, 500 ether);
        requests[1] = ActionRewardBurnRequest(address(scopeToken), actionId, 1 ether);

        vm.startPrank(alice);
        scopeToken.approve(address(burn), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IBurnErrors.BurnQuotaExceeded.selector, 0, 1 ether));
        burn.burnActionRewardTokens(5, requests);
        vm.stopPrank();

        assertEq(scopeToken.balanceOf(alice), 501 ether);
        assertEq(burn.accountBurnStats(alice, address(scopeToken)).actionRewardBurn.amount, 0);
        assertFalse(burn.isParticipant(alice));
    }

    function test_ActionBatchSupportsMixedCommunitiesAndRejectsEmptyOrZeroItems() public {
        uint256 actionId = 41;
        mint.setActionReward(address(scopeToken), 5, actionId, alice, 1 ether, true);
        mint.setActionReward(address(childToken), 5, actionId, alice, 1 ether, true);
        scopeToken.transfer(alice, 1 ether);
        childToken.transfer(alice, 1 ether);
        verify.setCurrentRound(6);

        vm.startPrank(alice);
        scopeToken.approve(address(burn), 1 ether);
        childToken.approve(address(burn), 1 ether);
        vm.expectRevert(IBurnErrors.EmptyBatch.selector);
        burn.burnActionRewardTokens(5, new ActionRewardBurnRequest[](0));

        ActionRewardBurnRequest[] memory requests = new ActionRewardBurnRequest[](2);
        requests[0] = ActionRewardBurnRequest(address(scopeToken), actionId, 1 ether);
        requests[1] = ActionRewardBurnRequest(address(childToken), actionId, 1 ether);
        burn.burnActionRewardTokens(5, requests);
        assertEq(burn.accountBurnStats(alice, address(scopeToken)).actionRewardBurn.amount, 1 ether);
        assertEq(burn.accountBurnStats(alice, address(childToken)).actionRewardBurn.amount, 1 ether);

        requests = new ActionRewardBurnRequest[](1);
        requests[0] = ActionRewardBurnRequest(address(scopeToken), actionId, 0);
        vm.expectRevert(IBurnErrors.ZeroAmount.selector);
        burn.burnActionRewardTokens(5, requests);
        vm.stopPrank();
    }

    function _deployBurn() internal returns (Burn deployed) {
        deployed = _deployBurnWithFactories(new address[](0));
    }

    function _deployBurnWithFactories(address[] memory factories) internal returns (Burn deployed) {
        deployed = _deployBurnWithAirdrop(address(0), factories);
    }

    function _deployBurnWithAirdrop(address airdropToken, address[] memory factories)
        internal
        returns (Burn deployed)
    {
        deployed = new Burn(address(center), "SCOPE", airdropToken, _communityWeights(), 5, 3, 5, factories);
    }

    function _communityWeights() internal pure returns (CommunityWeight[] memory weights) {
        weights = new CommunityWeight[](2);
        weights[0] = CommunityWeight("SCOPE", 600);
        weights[1] = CommunityWeight("CHILD", 400);
    }

    function _deploymentConfig(address airdropToken) internal view returns (BurnDeploymentConfig memory config) {
        config.extensionCenterAddress = address(center);
        config.scopeTokenSymbol = "SCOPE";
        config.airdropTokenAddress = airdropToken;
        config.communities = _communityWeights();
        config.startRound = 5;
        config.roundCount = 3;
        config.quotaMultiplier = 5;
        config.supportedExtensionFactories = new address[](0);
    }

    function _lockScopeSL(Burn target, address account, uint256 amount) internal {
        vm.startPrank(account);
        scopeSL.approve(address(target), amount);
        target.lockSLToken(address(scopeToken), 5, amount);
        vm.stopPrank();
    }

    function _expectAllRoundWritesClosed(uint256 round, uint256 currentRound) internal {
        bytes memory reason = abi.encodeWithSelector(IBurnErrors.RoundNotOpen.selector, round, currentRound);
        ActionRewardBurnRequest[] memory requests = new ActionRewardBurnRequest[](1);
        requests[0] = ActionRewardBurnRequest(address(scopeToken), 1, 1 ether);

        vm.expectRevert(reason);
        burn.lockSLToken(address(scopeToken), round, 1 ether);
        vm.expectRevert(reason);
        burn.lockSTToken(address(scopeToken), round, 1 ether);
        vm.expectRevert(reason);
        burn.burnGovRewardToken(address(scopeToken), round, 1 ether);
        vm.expectRevert(reason);
        burn.burnActionRewardTokens(round, requests);
    }
}
