// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {Test} from "forge-std/Test.sol";
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

    uint256 internal constant ALICE_SHARE = 0.2 ether;
    uint256 internal constant BOB_SHARE = 0.3 ether;
    uint256 internal constant CAROL_SHARE = 0.4 ether;
    uint256 internal constant TOTAL_SHARE = 0.9 ether;

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

        vm.expectEmit(true, true, false, true);
        emit AirdropClaimed(address(tokenA), alice, ALICE_SHARE, 200 ether, 0.7 ether);
        vm.prank(alice);
        assertEq(airdrop.claim(address(tokenA), alice, ALICE_SHARE, _aliceProof()), 200 ether);
        assertEq(tokenA.balanceOf(alice), 200 ether);
        assertTrue(airdrop.isClaimed(address(tokenA), alice));

        tokenA.mint(address(airdrop), 70 ether);
        assertEq(airdrop.claimableAmount(address(tokenA), bob, BOB_SHARE, _bobProof()), 330 ether);
        vm.prank(bob);
        assertEq(airdrop.claim(address(tokenA), bob, BOB_SHARE, _bobProof()), 330 ether);
        vm.prank(carol);
        assertEq(airdrop.claim(address(tokenA), carol, CAROL_SHARE, _carolProof()), 440 ether);
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
        assertEq(airdrop.claim(address(tokenA), alice, ALICE_SHARE, _aliceProof()), 20 ether);
        assertFalse(airdrop.isClaimed(address(tokenB), alice));
        assertEq(airdrop.claimableAmount(address(tokenB), alice, ALICE_SHARE, _aliceProof()), 40 ether);
        vm.prank(alice);
        assertEq(airdrop.claim(address(tokenB), alice, ALICE_SHARE, _aliceProof()), 40 ether);

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

        tokenA.mint(address(airdrop), 4);
        vm.prank(alice);
        assertEq(airdrop.claim(address(tokenA), alice, ALICE_SHARE, _aliceProof()), 1);
    }

    function test_RejectsInvalidAndDuplicateClaims() public {
        tokenA.mint(address(airdrop), 90 ether);

        vm.expectRevert(IAirdrop.InvalidToken.selector);
        airdrop.claim(address(0), alice, ALICE_SHARE, _aliceProof());

        vm.expectRevert(IAirdrop.InvalidAccount.selector);
        airdrop.claim(address(tokenA), address(0), ALICE_SHARE, _aliceProof());

        vm.expectRevert(IAirdrop.InvalidShare.selector);
        airdrop.claim(address(tokenA), alice, 0, _aliceProof());

        vm.expectRevert(IAirdrop.InvalidProof.selector);
        airdrop.claim(address(tokenA), alice, ALICE_SHARE + 1, _aliceProof());
        assertEq(airdrop.claimableAmount(address(tokenA), alice, ALICE_SHARE + 1, _aliceProof()), 0);

        vm.prank(alice);
        airdrop.claim(address(tokenA), alice, ALICE_SHARE, _aliceProof());
        vm.expectRevert(IAirdrop.AirdropAlreadyClaimed.selector);
        vm.prank(alice);
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
    }

    function test_SnapshotBuilderProofsClaimAgainstTheContract() public {
        GenerateAirdropSnapshot builder = new GenerateAirdropSnapshot();
        address[] memory accounts = new address[](3);
        uint256[] memory shares = new uint256[](3);
        accounts[0] = alice;
        accounts[1] = bob;
        accounts[2] = carol;
        shares[0] = ALICE_SHARE;
        shares[1] = BOB_SHARE;
        shares[2] = CAROL_SHARE;

        (bytes32 builtRoot, uint256 builtTotalShare, bytes32[][] memory proofs) = builder.build(accounts, shares);
        assertEq(builtRoot, root);
        assertEq(builtTotalShare, TOTAL_SHARE);

        Airdrop builtAirdrop =
            new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, SOURCE_BURN, builtRoot, builtTotalShare);
        tokenA.mint(address(builtAirdrop), 90 ether);
        vm.prank(carol);
        assertEq(builtAirdrop.claim(address(tokenA), carol, CAROL_SHARE, proofs[2]), 40 ether);
    }

    function test_SnapshotRunReadsPagesFiltersZeroSharesAndWritesProofs() public {
        MockSnapshotBurn sourceBurn = new MockSnapshotBurn(202, 0, 1e15, true);
        string memory output = "script/network/anvil/.airdrop-snapshot.test.json";
        _setSnapshotEnv(address(sourceBurn), output);
        if (vm.exists(output)) vm.removeFile(output);

        GenerateAirdropSnapshot builder = new GenerateAirdropSnapshot();
        (bytes32 builtRoot, uint256 builtTotalShare, uint256 accountCount) = builder.run();
        assertEq(accountCount, 201);
        assertEq(builtTotalShare, 201e15);

        string memory json = vm.readFile(output);
        assertEq(vm.readLine(output), "{");
        assertEq(vm.parseJsonUint(json, ".sourceChainId"), SOURCE_CHAIN_ID);
        assertEq(vm.parseJsonUint(json, ".sourceBlockNumber"), SOURCE_BLOCK_NUMBER);
        assertEq(vm.parseJsonAddress(json, ".sourceBurnAddress"), address(sourceBurn));
        assertEq(vm.parseJsonBytes32(json, ".merkleRoot"), builtRoot);
        assertEq(vm.parseJsonUint(json, ".totalShare"), builtTotalShare);

        address account = vm.parseJsonAddress(json, ".entries[0].account");
        uint256 share = vm.parseJsonUint(json, ".entries[0].share");
        bytes32[] memory proof = vm.parseJsonBytes32Array(json, ".entries[0].proof");
        assertEq(account, address(2));
        assertEq(share, 1e15);

        Airdrop builtAirdrop =
            new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, address(sourceBurn), builtRoot, builtTotalShare);
        tokenA.mint(address(builtAirdrop), 201 ether);
        vm.prank(account);
        assertEq(builtAirdrop.claim(address(tokenA), account, share, proof), 1 ether);

        vm.setEnv("SNAPSHOT_INPUT", output);
        vm.setEnv("MERKLE_ROOT", vm.toString(builtRoot));
        vm.setEnv("TOTAL_SHARE", vm.toString(builtTotalShare));
        vm.setEnv("AIRDROP_ADDRESS", vm.toString(address(builtAirdrop)));
        ValidateAirdropSnapshot validator = new ValidateAirdropSnapshot();
        assertEq(validator.run(), 201);

        vm.removeFile(output);
    }

    function test_SnapshotRunRejectsUnfinalizedBurn() public {
        MockSnapshotBurn sourceBurn = new MockSnapshotBurn(1, type(uint256).max, 1e15, false);
        string memory output = "script/network/anvil/.airdrop-snapshot.test.json";
        _setSnapshotEnv(address(sourceBurn), output);
        if (vm.exists(output)) vm.removeFile(output);
        (, bool finalized) = sourceBurn.accountShare(address(0));
        assertFalse(finalized);

        GenerateAirdropSnapshot builder = new GenerateAirdropSnapshot();
        vm.expectRevert(bytes("burn shares not finalized"));
        builder.run();
    }

    function test_SnapshotRunRequiresContractAccountReview() public {
        MockSnapshotBurn sourceBurn = new MockSnapshotBurn(10, type(uint256).max, 1e15, true);
        string memory output = "script/network/anvil/.airdrop-snapshot.test.json";
        _setSnapshotEnv(address(sourceBurn), output);
        vm.etch(address(10), hex"00");
        assertEq(address(10).code.length, 1);

        GenerateAirdropSnapshot builder = new GenerateAirdropSnapshot();
        vm.expectRevert(abi.encodeWithSelector(GenerateAirdropSnapshot.ContractAccountsRequireTargetReview.selector, 1));
        builder.run();

        vm.setEnv("CONTRACT_ACCOUNTS_REVIEWED", "true");
        (,, uint256 accountCount) = builder.run();
        assertEq(accountCount, 10);
        vm.removeFile(output);
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
