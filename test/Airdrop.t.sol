// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Airdrop} from "../src/Airdrop.sol";
import {IAirdrop} from "../src/interface/IAirdrop.sol";
import {MockERC20, MockFailingAirdropToken} from "./mocks/MockProtocol.sol";
import {GenerateAirdropSnapshot} from "../script/GenerateAirdropSnapshot.s.sol";
import {ValidateAirdropSnapshot} from "../script/ValidateAirdropSnapshot.s.sol";

contract AirdropTest is Test {
    uint256 internal constant SOURCE_CHAIN_ID = 70_001;
    uint256 internal constant SOURCE_BLOCK_NUMBER = 12_345;
    address internal constant SOURCE_BURN = address(0xB012);

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA201);
    address internal relayer = address(0x2E1A);

    // Raw pool shares, normalised by the generator to exactly 1e18.
    uint256 internal constant ALICE_RAW = 0.2 ether;
    uint256 internal constant BOB_RAW = 0.3 ether;
    uint256 internal constant CAROL_RAW = 0.4 ether;

    // floor(raw * 1e18 / 0.9e18); the 1 wei floor remainder goes to the largest
    // share (carol), so the leaves sum to exactly TOTAL_SHARE.
    uint256 internal constant ALICE_SHARE = 222222222222222222;
    uint256 internal constant BOB_SHARE = 333333333333333333;
    uint256 internal constant CAROL_SHARE = 444444444444444445;
    uint256 internal constant TOTAL_SHARE = 1 ether;

    Airdrop internal airdrop;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    bytes32 internal aliceLeaf;
    bytes32 internal bobLeaf;
    bytes32 internal carolLeaf;
    bytes32 internal pairAB;
    bytes32 internal root;

    event AirdropClaimed(
        address indexed token, address indexed account, uint256 share, uint256 amount, uint256 remainingShare
    );

    function setUp() public {
        aliceLeaf = _leaf(alice, ALICE_SHARE);
        bobLeaf = _leaf(bob, BOB_SHARE);
        carolLeaf = _leaf(carol, CAROL_SHARE);
        pairAB = _hashPair(aliceLeaf, bobLeaf);
        root = _hashPair(pairAB, carolLeaf);

        airdrop = new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, SOURCE_BURN, root, TOTAL_SHARE);
        tokenA = new MockERC20("Token A", "A");
        tokenB = new MockERC20("Token B", "B");
    }

    function test_ConstructorFreezesSourceSnapshot() public view {
        assertEq(airdrop.sourceChainId(), SOURCE_CHAIN_ID);
        assertEq(airdrop.sourceBlockNumber(), SOURCE_BLOCK_NUMBER);
        assertEq(airdrop.sourceBurnAddress(), SOURCE_BURN);
        assertEq(airdrop.merkleRoot(), root);
        assertEq(airdrop.totalShare(), TOTAL_SHARE);
        assertEq(airdrop.remainingShare(address(tokenA)), TOTAL_SHARE);
        assertEq(airdrop.leafHash(alice, ALICE_SHARE), aliceLeaf);
    }

    function test_ConstructorRejectsInvalidSnapshot() public {
        vm.expectRevert(IAirdrop.InvalidSourceChainId.selector);
        new Airdrop(0, SOURCE_BLOCK_NUMBER, SOURCE_BURN, root, TOTAL_SHARE);

        vm.expectRevert(IAirdrop.InvalidSourceBlock.selector);
        new Airdrop(SOURCE_CHAIN_ID, 0, SOURCE_BURN, root, TOTAL_SHARE);

        vm.expectRevert(IAirdrop.ZeroAddress.selector);
        new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, address(0), root, TOTAL_SHARE);

        vm.expectRevert(IAirdrop.InvalidMerkleRoot.selector);
        new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, SOURCE_BURN, bytes32(0), TOTAL_SHARE);

        vm.expectRevert(IAirdrop.InvalidTotalShare.selector);
        new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, SOURCE_BURN, root, 0);

        vm.expectRevert(IAirdrop.InvalidTotalShare.selector);
        new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, SOURCE_BURN, root, 1 ether + 1);
    }

    function test_ClaimDistributesDynamicPoolAndRequiresSelfClaim() public {
        tokenA.mint(address(airdrop), 900 ether);

        vm.prank(relayer);
        vm.expectRevert(IAirdrop.UnauthorizedClaimer.selector);
        airdrop.claim(address(tokenA), alice, ALICE_SHARE, _aliceProof());
        assertFalse(airdrop.isClaimed(address(tokenA), alice));

        // Shares are normalised to 1e18, so floor(900e18 x share / 1e18) is no
        // longer a round number: 900e18 x 0.222222222222222222e18.
        vm.expectEmit(true, true, false, true);
        emit AirdropClaimed(address(tokenA), alice, ALICE_SHARE, 199_999_999_999_999_999_800, 777_777_777_777_777_778);
        vm.prank(alice);
        assertEq(airdrop.claim(address(tokenA), alice, ALICE_SHARE, _aliceProof()), 199_999_999_999_999_999_800);
        assertEq(tokenA.balanceOf(alice), 199_999_999_999_999_999_800);
        assertTrue(airdrop.isClaimed(address(tokenA), alice));

        tokenA.mint(address(airdrop), 70 ether);
        assertEq(airdrop.claimableAmount(address(tokenA), bob, BOB_SHARE, _bobProof()), 329_999_999_999_999_999_661);
        vm.prank(bob);
        assertEq(airdrop.claim(address(tokenA), bob, BOB_SHARE, _bobProof()), 329_999_999_999_999_999_661);
        vm.prank(carol);
        assertEq(airdrop.claim(address(tokenA), carol, CAROL_SHARE, _carolProof()), 440_000_000_000_000_000_539);
        assertEq(airdrop.claimedShare(address(tokenA)), TOTAL_SHARE);
        assertEq(airdrop.remainingShare(address(tokenA)), 0);
        assertEq(tokenA.balanceOf(address(airdrop)), 0);

        tokenA.mint(address(airdrop), 10 ether);
        assertEq(tokenA.balanceOf(address(airdrop)), 10 ether);
        assertEq(airdrop.remainingShare(address(tokenA)), 0);
    }

    function test_ClaimStateIsIndependentPerToken() public {
        tokenA.mint(address(airdrop), 90 ether);
        tokenB.mint(address(airdrop), 180 ether);

        vm.prank(alice);
        assertEq(airdrop.claim(address(tokenA), alice, ALICE_SHARE, _aliceProof()), 19_999_999_999_999_999_980);
        assertFalse(airdrop.isClaimed(address(tokenB), alice));
        assertEq(
            airdrop.claimableAmount(address(tokenB), alice, ALICE_SHARE, _aliceProof()), 39_999_999_999_999_999_960
        );
        vm.prank(alice);
        assertEq(airdrop.claim(address(tokenB), alice, ALICE_SHARE, _aliceProof()), 39_999_999_999_999_999_960);

        assertEq(airdrop.claimedShare(address(tokenA)), ALICE_SHARE);
        assertEq(airdrop.claimedShare(address(tokenB)), ALICE_SHARE);
    }

    function test_ZeroAmountDoesNotConsumeClaim() public {
        tokenA.mint(address(airdrop), 1);

        vm.expectRevert(IAirdrop.NoClaimableAmount.selector);
        vm.prank(alice);
        airdrop.claim(address(tokenA), alice, ALICE_SHARE, _aliceProof());
        assertFalse(airdrop.isClaimed(address(tokenA), alice));
        assertEq(airdrop.remainingShare(address(tokenA)), TOTAL_SHARE);

        // 5 wei total: floor(5 x 0.222222222222222222e18 / 1e18) == 1.
        tokenA.mint(address(airdrop), 4);
        vm.prank(alice);
        assertEq(airdrop.claim(address(tokenA), alice, ALICE_SHARE, _aliceProof()), 1);
    }

    function test_RejectsInvalidAndDuplicateClaims() public {
        tokenA.mint(address(airdrop), 90 ether);

        // Account authentication is checked before any snapshot/token state, so a
        // zero account and a third-party caller are rejected independently of the
        // proof / token arguments.
        vm.expectRevert(IAirdrop.InvalidAccount.selector);
        airdrop.claim(address(tokenA), address(0), ALICE_SHARE, _aliceProof());

        vm.prank(relayer);
        vm.expectRevert(IAirdrop.UnauthorizedClaimer.selector);
        airdrop.claim(address(tokenA), alice, ALICE_SHARE, _aliceProof());

        vm.prank(relayer);
        vm.expectRevert(IAirdrop.UnauthorizedClaimer.selector);
        airdrop.claim(address(tokenA), alice, ALICE_SHARE, new bytes32[](0));

        vm.prank(alice);
        vm.expectRevert(IAirdrop.InvalidToken.selector);
        airdrop.claim(address(0), alice, ALICE_SHARE, _aliceProof());

        vm.prank(alice);
        vm.expectRevert(IAirdrop.InvalidShare.selector);
        airdrop.claim(address(tokenA), alice, 0, _aliceProof());

        vm.prank(alice);
        vm.expectRevert(IAirdrop.InvalidProof.selector);
        airdrop.claim(address(tokenA), alice, ALICE_SHARE + 1, _aliceProof());
        assertEq(airdrop.claimableAmount(address(tokenA), alice, ALICE_SHARE + 1, _aliceProof()), 0);

        vm.prank(alice);
        airdrop.claim(address(tokenA), alice, ALICE_SHARE, _aliceProof());
        vm.prank(alice);
        vm.expectRevert(IAirdrop.AirdropAlreadyClaimed.selector);
        airdrop.claim(address(tokenA), alice, ALICE_SHARE, _aliceProof());
    }

    function test_TransferFailureRollsBackClaimState() public {
        MockFailingAirdropToken failingToken = new MockFailingAirdropToken();
        failingToken.mint(address(airdrop), 90 ether);
        failingToken.setFailTransfers(true);

        vm.expectRevert(bytes("airdrop transfer failed"));
        vm.prank(alice);
        airdrop.claim(address(failingToken), alice, ALICE_SHARE, _aliceProof());

        assertFalse(airdrop.isClaimed(address(failingToken), alice));
        assertEq(airdrop.remainingShare(address(failingToken)), TOTAL_SHARE);
        assertEq(airdrop.claimedAmount(address(failingToken), alice), 0);
    }

    function test_ClaimedAmountMatchesReturnValueEventAndBalanceDelta() public {
        tokenA.mint(address(airdrop), 900 ether);
        uint256 balanceBefore = tokenA.balanceOf(alice);

        vm.recordLogs();
        vm.prank(alice);
        uint256 amount = airdrop.claim(address(tokenA), alice, ALICE_SHARE, _aliceProof());
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 claimedSig = keccak256("AirdropClaimed(address,address,uint256,uint256,uint256)");
        uint256 eventAmount;
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != claimedSig) continue;
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(tokenA)))));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(alice))));
            (, eventAmount,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            found = true;
        }
        assertTrue(found, "AirdropClaimed not emitted");

        assertEq(amount, 199_999_999_999_999_999_800);
        assertEq(airdrop.claimedAmount(address(tokenA), alice), amount);
        assertEq(eventAmount, amount);
        assertEq(tokenA.balanceOf(alice) - balanceBefore, amount);
    }

    function test_SecondClaimRevertsAndKeepsClaimedAmount() public {
        tokenA.mint(address(airdrop), 900 ether);

        vm.prank(alice);
        uint256 amount = airdrop.claim(address(tokenA), alice, ALICE_SHARE, _aliceProof());
        assertEq(airdrop.claimedAmount(address(tokenA), alice), amount);

        vm.prank(alice);
        vm.expectRevert(IAirdrop.AirdropAlreadyClaimed.selector);
        airdrop.claim(address(tokenA), alice, ALICE_SHARE, _aliceProof());
        assertEq(airdrop.claimedAmount(address(tokenA), alice), amount);
    }

    function test_ClaimedAmountIsZeroForAccountThatNeverClaimed() public {
        tokenA.mint(address(airdrop), 900 ether);

        assertEq(airdrop.claimedAmount(address(tokenA), alice), 0);
        assertEq(airdrop.claimedAmount(address(tokenA), bob), 0);

        vm.prank(alice);
        airdrop.claim(address(tokenA), alice, ALICE_SHARE, _aliceProof());
        assertEq(airdrop.claimedAmount(address(tokenA), alice), 199_999_999_999_999_999_800);
        assertEq(airdrop.claimedAmount(address(tokenA), bob), 0);
    }

    function test_ClaimedAmountIsIsolatedPerToken() public {
        tokenA.mint(address(airdrop), 90 ether);
        tokenB.mint(address(airdrop), 180 ether);

        vm.prank(alice);
        uint256 amountA = airdrop.claim(address(tokenA), alice, ALICE_SHARE, _aliceProof());
        assertEq(amountA, 19_999_999_999_999_999_980);
        assertEq(airdrop.claimedAmount(address(tokenA), alice), amountA);
        assertEq(airdrop.claimedAmount(address(tokenB), alice), 0);

        vm.prank(alice);
        uint256 amountB = airdrop.claim(address(tokenB), alice, ALICE_SHARE, _aliceProof());
        assertEq(amountB, 39_999_999_999_999_999_960);
        assertEq(airdrop.claimedAmount(address(tokenA), alice), amountA);
        assertEq(airdrop.claimedAmount(address(tokenB), alice), amountB);
    }

    function test_RevertedClaimLeavesClaimedAmountZero() public {
        tokenA.mint(address(airdrop), 900 ether);

        vm.prank(alice);
        vm.expectRevert(IAirdrop.InvalidProof.selector);
        airdrop.claim(address(tokenA), alice, ALICE_SHARE + 1, _aliceProof());
        assertEq(airdrop.claimedAmount(address(tokenA), alice), 0);
    }

    function test_SnapshotBuilderProofsClaimAgainstTheContract() public {
        GenerateAirdropSnapshot builder = new GenerateAirdropSnapshot();
        address[] memory accounts = new address[](3);
        uint256[] memory shares = new uint256[](3);
        accounts[0] = alice;
        accounts[1] = bob;
        accounts[2] = carol;
        // `build` normalises, so feed the raw pool shares and expect the
        // same 1e18-scaled leaves and root that `setUp` hand-rolled above.
        shares[0] = ALICE_RAW;
        shares[1] = BOB_RAW;
        shares[2] = CAROL_RAW;

        (bytes32 builtRoot, uint256 builtTotalShare, bytes32[][] memory proofs) = builder.build(accounts, shares);
        assertEq(builtRoot, root);
        assertEq(builtTotalShare, TOTAL_SHARE);

        Airdrop builtAirdrop =
            new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, SOURCE_BURN, builtRoot, builtTotalShare);
        tokenA.mint(address(builtAirdrop), 90 ether);
        vm.prank(carol);
        assertEq(builtAirdrop.claim(address(tokenA), carol, CAROL_SHARE, proofs[2]), 40_000_000_000_000_000_050);
    }

    // Snapshot generation is exercised in one sequential test function: the
    // generator reads SOURCE_* through the process-wide cheatcode environment,
    // so parallel test functions would race with each other. Each scenario also
    // uses its own output path (the previous shared path caused a real
    // write/remove race and made the suite flaky under `forge test`).
    function test_SnapshotGenerationEndToEnd() public {
        _snapshotReadsPagesFiltersZeroSharesAndValidatesProofs();
        _snapshotRejectsUnfinalizedBurn();
        _snapshotRequiresContractAccountReview();
    }

    function _snapshotReadsPagesFiltersZeroSharesAndValidatesProofs() internal {
        MockSnapshotBurn sourceBurn = new MockSnapshotBurn(202, 0, 1e15, true);
        string memory output = "script/network/anvil/.airdrop-snapshot.test.pages.json";
        _setSnapshotEnv(address(sourceBurn), output);
        if (vm.exists(output)) vm.removeFile(output);

        GenerateAirdropSnapshot builder = new GenerateAirdropSnapshot();
        (bytes32 builtRoot, uint256 builtTotalShare, uint256 accountCount) = builder.run();
        assertEq(accountCount, 201);
        // 201 equal raw shares normalise to 1e18 exactly: the 148 wei floor
        // remainder goes to the largest share, and index 0 wins the tie.
        assertEq(builtTotalShare, 1 ether);

        string memory json = vm.readFile(output);
        assertGt(bytes(json).length, 0);
        assertEq(vm.parseJsonUint(json, ".sourceChainId"), SOURCE_CHAIN_ID);
        assertEq(vm.parseJsonUint(json, ".sourceBlockNumber"), SOURCE_BLOCK_NUMBER);
        assertEq(vm.parseJsonAddress(json, ".sourceBurnAddress"), address(sourceBurn));
        assertEq(vm.parseJsonBytes32(json, ".merkleRoot"), builtRoot);
        assertEq(vm.parseJsonUint(json, ".totalShare"), builtTotalShare);
        assertEq(vm.parseJsonUint(json, ".accountCount"), 201);

        address account = vm.parseJsonAddress(json, ".entries[0].account");
        uint256 share = vm.parseJsonUint(json, ".entries[0].share");
        bytes32[] memory proof = vm.parseJsonBytes32Array(json, ".entries[0].proof");
        assertEq(account, address(2));
        assertEq(share, 4975124378109600);

        Airdrop builtAirdrop =
            new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, address(sourceBurn), builtRoot, builtTotalShare);
        tokenA.mint(address(builtAirdrop), 201 ether);
        vm.prank(account);
        assertEq(builtAirdrop.claim(address(tokenA), account, share, proof), 1000000000000029600);

        vm.setEnv("SNAPSHOT_INPUT", output);
        vm.setEnv("MERKLE_ROOT", vm.toString(builtRoot));
        vm.setEnv("TOTAL_SHARE", vm.toString(builtTotalShare));
        vm.setEnv("AIRDROP_ADDRESS", vm.toString(address(builtAirdrop)));
        ValidateAirdropSnapshot validator = new ValidateAirdropSnapshot();
        assertEq(validator.run(), 201);

        vm.removeFile(output);
        // Leave no deployed-instance flag behind for other suites/tests.
        vm.setEnv("AIRDROP_ADDRESS", vm.toString(address(0)));
    }

    function _snapshotRejectsUnfinalizedBurn() internal {
        MockSnapshotBurn sourceBurn = new MockSnapshotBurn(1, type(uint256).max, 1e15, false);
        string memory output = "script/network/anvil/.airdrop-snapshot.test.unfinalized.json";
        _setSnapshotEnv(address(sourceBurn), output);
        if (vm.exists(output)) vm.removeFile(output);
        (, bool finalized) = sourceBurn.accountShare(address(0));
        assertFalse(finalized);

        GenerateAirdropSnapshot builder = new GenerateAirdropSnapshot();
        vm.expectRevert(bytes("burn shares not finalized"));
        builder.run();
        if (vm.exists(output)) vm.removeFile(output);
    }

    function _snapshotRequiresContractAccountReview() internal {
        MockSnapshotBurn sourceBurn = new MockSnapshotBurn(10, type(uint256).max, 1e15, true);
        string memory output = "script/network/anvil/.airdrop-snapshot.test.contracts.json";
        _setSnapshotEnv(address(sourceBurn), output);
        if (vm.exists(output)) vm.removeFile(output);
        vm.etch(address(10), hex"00");
        assertEq(address(10).code.length, 1);

        GenerateAirdropSnapshot builder = new GenerateAirdropSnapshot();
        vm.expectRevert(abi.encodeWithSelector(GenerateAirdropSnapshot.ContractAccountsRequireTargetReview.selector, 1));
        builder.run();

        vm.setEnv("CONTRACT_ACCOUNTS_REVIEWED", "true");
        (,, uint256 accountCount) = builder.run();
        assertEq(accountCount, 10);
        if (vm.exists(output)) vm.removeFile(output);
        vm.setEnv("CONTRACT_ACCOUNTS_REVIEWED", "false");
    }

    function _setSnapshotEnv(address sourceBurn, string memory output) internal {
        vm.chainId(SOURCE_CHAIN_ID);
        vm.roll(SOURCE_BLOCK_NUMBER);
        vm.setEnv("SOURCE_CHAIN_ID", vm.toString(SOURCE_CHAIN_ID));
        vm.setEnv("SOURCE_BLOCK_NUMBER", vm.toString(SOURCE_BLOCK_NUMBER));
        vm.setEnv("SOURCE_BURN", vm.toString(sourceBurn));
        vm.setEnv("network", "anvil");
        vm.setEnv("SNAPSHOT_OUTPUT", output);
        vm.setEnv("CONTRACT_ACCOUNTS_REVIEWED", "false");
    }

    function _aliceProof() internal view returns (bytes32[] memory proof) {
        proof = new bytes32[](2);
        proof[0] = bobLeaf;
        proof[1] = carolLeaf;
    }

    function _bobProof() internal view returns (bytes32[] memory proof) {
        proof = new bytes32[](2);
        proof[0] = aliceLeaf;
        proof[1] = carolLeaf;
    }

    function _carolProof() internal view returns (bytes32[] memory proof) {
        proof = new bytes32[](1);
        proof[0] = pairAB;
    }

    function _leaf(address account, uint256 share) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, share))));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(bytes.concat(a, b)) : keccak256(bytes.concat(b, a));
    }
}

contract MockSnapshotBurn {
    uint256 public immutable participantsCount;
    uint256 public immutable zeroIndex;
    uint256 public immutable share;
    bool public immutable finalized;

    constructor(uint256 participantCount_, uint256 zeroIndex_, uint256 share_, bool finalized_) {
        participantsCount = participantCount_;
        zeroIndex = zeroIndex_;
        share = share_;
        finalized = finalized_;
    }

    function participants(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 length = limit;
        if (offset + length > participantsCount) length = participantsCount - offset;
        page = new address[](length);
        for (uint256 i; i < length; ++i) {
            page[i] = address(uint160(offset + i + 1));
        }
    }

    function accountShare(address account) external view returns (uint256 accountShare_, bool finalized_) {
        uint256 index = uint160(account);
        if (index == 0 || index > participantsCount || index - 1 == zeroIndex) return (0, finalized);
        return (share, finalized);
    }
}
