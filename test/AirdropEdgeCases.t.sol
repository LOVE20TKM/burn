// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {Test} from "forge-std/Test.sol";
import {Airdrop} from "../src/Airdrop.sol";
import {IAirdrop} from "../src/interface/IAirdrop.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockERC20} from "./mocks/MockProtocol.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {GenerateAirdropSnapshot} from "../script/GenerateAirdropSnapshot.s.sol";

/// @notice Regression tests for the review findings that the original
///         `test/Airdrop.t.sol` did not cover (reentrancy, non-standard ERC20,
///         tree shapes, deployment-parameter mismatch, claim-order conservation).
contract AirdropEdgeCasesTest is Test {
    uint256 internal constant SOURCE_CHAIN_ID = 70_001;
    uint256 internal constant SOURCE_BLOCK_NUMBER = 12_345;
    address internal constant SOURCE_BURN = address(0xB012);

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA201);
    address internal relayer = address(0x2E1A);

    GenerateAirdropSnapshot internal builder;
    MockERC20 internal token;

    function setUp() public {
        builder = new GenerateAirdropSnapshot();
        token = new MockERC20("Token", "TKN");
    }

    // ------------------------------------------------------------------
    // Snapshot generator
    // ------------------------------------------------------------------

    function test_GeneratorRejectsDuplicateAccounts() public {
        address[] memory accounts = new address[](3);
        uint256[] memory shares = new uint256[](3);
        accounts[0] = alice;
        accounts[1] = alice;
        accounts[2] = bob;
        shares[0] = 0.2 ether;
        shares[1] = 0.3 ether;
        shares[2] = 0.5 ether;

        vm.expectRevert(bytes("duplicate snapshot account"));
        builder.build(accounts, shares);
    }

    function test_GeneratorNormalizesSharesToExactlyOneWad() public view {
        // Raw [1, 1, 1] flooring: 3 * (1e18 / 3) == 3 * 333333333333333333
        // == 999999999999999999, i.e. 1 wei short. The remainder must land on the
        // largest share; with a three-way tie the lowest index wins.
        uint256[] memory shares = new uint256[](3);
        shares[0] = 1;
        shares[1] = 1;
        shares[2] = 1;

        uint256[] memory normalized = builder.normalizeShares(shares);
        assertEq(normalized[0], 333333333333333334);
        assertEq(normalized[1], 333333333333333333);
        assertEq(normalized[2], 333333333333333333);
        assertEq(normalized[0] + normalized[1] + normalized[2], 1 ether);
    }

    function test_GeneratorPutsRemainderOnLargestShare() public view {
        // 0.2 / 0.3 / 0.4 ether floor to 999999999999999999 wei; carol holds the
        // largest share, so she absorbs the leftover 1 wei.
        uint256[] memory shares = new uint256[](3);
        shares[0] = 0.2 ether;
        shares[1] = 0.3 ether;
        shares[2] = 0.4 ether;

        uint256[] memory normalized = builder.normalizeShares(shares);
        assertEq(normalized[0], 222222222222222222);
        assertEq(normalized[1], 333333333333333333);
        assertEq(normalized[2], 444444444444444445);
        assertEq(normalized[0] + normalized[1] + normalized[2], 1 ether);
    }

    function test_GeneratorNormalizedSumIsAlwaysExactlyOneWad() public view {
        address[] memory accounts = new address[](3);
        uint256[] memory shares = new uint256[](3);
        accounts[0] = alice;
        accounts[1] = bob;
        accounts[2] = carol;
        shares[0] = 0.2 ether;
        shares[1] = 0.3 ether;
        shares[2] = 0.4 ether;

        (bytes32 root, uint256 totalShare, bytes32[][] memory proofs) = builder.build(accounts, shares);
        assertEq(totalShare, 1 ether);

        // `build` hashes the normalised shares, so the returned proofs only verify
        // against the 1e18-scaled leaves: an internal-consistency check that the
        // pre-normalisation 0.9e18 leaves are gone.
        uint256[] memory normalized = builder.normalizeShares(shares);
        bytes32[] memory leaves = new bytes32[](3);
        uint256 leafSum;
        for (uint256 i; i < 3; ++i) {
            leaves[i] = keccak256(bytes.concat(keccak256(abi.encode(accounts[i], normalized[i]))));
            leafSum += normalized[i];
            assertTrue(MerkleProof.verify(proofs[i], root, leaves[i]));
        }
        assertEq(leafSum, 1 ether);

        // The raw leaves are rejected against the same root.
        bytes32 rawLeaf = keccak256(bytes.concat(keccak256(abi.encode(alice, shares[0]))));
        assertFalse(MerkleProof.verify(proofs[0], root, rawLeaf));
    }

    function test_GeneratorRejectsZeroShareEntry() public {
        address[] memory accounts = new address[](2);
        uint256[] memory shares = new uint256[](2);
        accounts[0] = alice;
        accounts[1] = bob;
        shares[0] = 1;
        shares[1] = 0;

        vm.expectRevert(bytes("invalid snapshot entry"));
        builder.build(accounts, shares);
    }

    function test_GeneratorRejectsShareThatNormalisesToZero() public {
        // `build` is public and takes raw shares, so it also has to survive a distribution
        // whose total is far above the 1e18 scale the consumer expects. A share that floors
        // to zero would become a leaf that occupies a proof and a claim slot yet can never
        // pay out, so the generator refuses to emit the snapshot instead of shipping it.
        address[] memory accounts = new address[](2);
        uint256[] memory shares = new uint256[](2);
        accounts[0] = alice;
        accounts[1] = bob;
        shares[0] = 1;
        shares[1] = 1e30;

        vm.expectRevert(bytes("normalized share rounded to zero"));
        builder.build(accounts, shares);
    }

    function test_NormalizeSharesRejectsEmptyAndZeroTotals() public {
        uint256[] memory empty = new uint256[](0);
        vm.expectRevert(bytes("invalid snapshot entries"));
        builder.normalizeShares(empty);

        uint256[] memory zeros = new uint256[](2);
        vm.expectRevert(bytes("no positive snapshot share"));
        builder.normalizeShares(zeros);
    }

    // ------------------------------------------------------------------
    // Reentrancy
    // ------------------------------------------------------------------

    function test_ReentrancyThroughTokenTransferCallbackIsBlocked() public {
        ReenteringAirdropToken reentering = new ReenteringAirdropToken();

        address[] memory accounts = new address[](2);
        uint256[] memory shares = new uint256[](2);
        accounts[0] = alice;
        accounts[1] = bob;
        shares[0] = 0.2 ether;
        shares[1] = 0.3 ether;
        uint256[] memory normalized = builder.normalizeShares(shares);
        (bytes32 root,, bytes32[][] memory proofs) = builder.build(accounts, shares);

        Airdrop airdrop = new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, SOURCE_BURN, root, 1 ether);
        reentering.mint(address(airdrop), 500 ether);
        reentering.configure(address(airdrop), alice, normalized[1], proofs[1]);

        vm.prank(alice);
        vm.expectRevert(bytes("ReentrancyGuard: reentrant call"));
        airdrop.claim(address(reentering), alice, normalized[0], proofs[0]);

        assertFalse(airdrop.isClaimed(address(reentering), alice));
        assertEq(airdrop.remainingShare(address(reentering)), 1 ether);
        assertEq(reentering.balanceOf(alice), 0);
    }

    // ------------------------------------------------------------------
    // Non-standard ERC20
    // ------------------------------------------------------------------

    function test_FalseReturnTokenRevertsAndRollsBack() public {
        FalseReturnToken falseToken = new FalseReturnToken();

        address[] memory accounts = new address[](1);
        uint256[] memory shares = new uint256[](1);
        accounts[0] = alice;
        shares[0] = 0.5 ether;
        uint256[] memory normalized = builder.normalizeShares(shares);
        (bytes32 root,, bytes32[][] memory proofs) = builder.build(accounts, shares);

        Airdrop airdrop = new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, SOURCE_BURN, root, 1 ether);
        falseToken.setBalance(address(airdrop), 100 ether);

        vm.prank(alice);
        vm.expectRevert(bytes("SafeERC20: ERC20 operation did not succeed"));
        airdrop.claim(address(falseToken), alice, normalized[0], proofs[0]);

        assertFalse(airdrop.isClaimed(address(falseToken), alice));
        assertEq(airdrop.remainingShare(address(falseToken)), 1 ether);
        assertEq(airdrop.claimedAmount(address(falseToken), alice), 0);
    }

    function test_EmptyReturnTokenIsAccepted() public {
        EmptyReturnToken emptyToken = new EmptyReturnToken();

        address[] memory accounts = new address[](1);
        uint256[] memory shares = new uint256[](1);
        accounts[0] = alice;
        shares[0] = 0.5 ether;
        uint256[] memory normalized = builder.normalizeShares(shares);
        (bytes32 root,, bytes32[][] memory proofs) = builder.build(accounts, shares);

        Airdrop airdrop = new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, SOURCE_BURN, root, 1 ether);
        emptyToken.setBalance(address(airdrop), 100 ether);

        vm.prank(alice);
        assertEq(airdrop.claim(address(emptyToken), alice, normalized[0], proofs[0]), 100 ether);
        assertEq(emptyToken.balanceOf(alice), 100 ether);
        assertEq(emptyToken.balanceOf(address(airdrop)), 0);
    }

    // ------------------------------------------------------------------
    // Tree shapes
    // ------------------------------------------------------------------

    function test_SingleLeafTreeClaims() public {
        address[] memory accounts = new address[](1);
        uint256[] memory shares = new uint256[](1);
        accounts[0] = alice;
        shares[0] = 0.5 ether;
        uint256[] memory normalized = builder.normalizeShares(shares);
        (bytes32 root,, bytes32[][] memory proofs) = builder.build(accounts, shares);

        Airdrop airdrop = new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, SOURCE_BURN, root, 1 ether);
        token.mint(address(airdrop), 100 ether);

        vm.prank(alice);
        assertEq(airdrop.claim(address(token), alice, normalized[0], proofs[0]), 100 ether);
        assertEq(token.balanceOf(address(airdrop)), 0);
    }

    function test_OddTreeOfFiveLeavesDrainsPool() public {
        address[] memory accounts = new address[](5);
        uint256[] memory shares = new uint256[](5);
        accounts[0] = address(0x10001);
        accounts[1] = address(0x10002);
        accounts[2] = address(0x10003);
        accounts[3] = address(0x10004);
        accounts[4] = address(0x10005);
        shares[0] = 0.1 ether;
        shares[1] = 0.2 ether;
        shares[2] = 0.3 ether;
        shares[3] = 0.15 ether;
        shares[4] = 0.25 ether;
        uint256[] memory normalized = builder.normalizeShares(shares);
        (bytes32 root, uint256 totalShare, bytes32[][] memory proofs) = builder.build(accounts, shares);

        Airdrop airdrop = new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, SOURCE_BURN, root, totalShare);
        token.mint(address(airdrop), 1_000 ether);

        for (uint256 i; i < accounts.length; ++i) {
            vm.prank(accounts[i]);
            airdrop.claim(address(token), accounts[i], normalized[i], proofs[i]);
        }

        assertEq(airdrop.claimedShare(address(token)), totalShare);
        assertEq(airdrop.remainingShare(address(token)), 0);
        assertEq(token.balanceOf(address(airdrop)), 0);
    }

    function test_NineLeafTreeDrainsPool() public {
        address[] memory accounts = new address[](9);
        uint256[] memory shares = new uint256[](9);
        uint256[9] memory values = [
            uint256(0.05 ether),
            0.1 ether,
            0.15 ether,
            0.2 ether,
            0.1 ether,
            0.15 ether,
            0.05 ether,
            0.1 ether,
            0.1 ether
        ];

        for (uint256 i; i < 9; ++i) {
            accounts[i] = address(uint160(0x30000 + i));
            shares[i] = values[i];
        }

        uint256[] memory normalized = builder.normalizeShares(shares);
        (bytes32 root, uint256 totalShare, bytes32[][] memory proofs) = builder.build(accounts, shares);
        // Raw shares already sum to 1e18 here, so normalisation is a no-op.
        assertEq(totalShare, 1 ether);
        for (uint256 i; i < 9; ++i) {
            assertEq(normalized[i], shares[i]);
        }

        Airdrop airdrop = new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, SOURCE_BURN, root, totalShare);
        token.mint(address(airdrop), 1_000 ether);

        for (uint256 i; i < accounts.length; ++i) {
            vm.prank(accounts[i]);
            airdrop.claim(address(token), accounts[i], normalized[i], proofs[i]);
        }

        assertEq(airdrop.claimedShare(address(token)), totalShare);
        assertEq(airdrop.remainingShare(address(token)), 0);
        assertEq(token.balanceOf(address(airdrop)), 0);
    }

    // ------------------------------------------------------------------
    // Accounting / rounding
    // ------------------------------------------------------------------

    function testFuzz_ClaimOrderConservesPool(uint256 seed) public {
        uint256 n = 2 + (seed % 7);
        address[] memory accounts = new address[](n);
        uint256[] memory shares = new uint256[](n);
        uint256 cap = 1e18 / n;

        for (uint256 i; i < n; ++i) {
            accounts[i] = address(uint160(0x20000 + i));
            shares[i] = 1 + (uint256(keccak256(abi.encode(seed, i))) % (cap - 1));
        }

        uint256[] memory normalized = builder.normalizeShares(shares);
        (bytes32 root, uint256 totalShare, bytes32[][] memory proofs) = builder.build(accounts, shares);
        Airdrop airdrop = new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, SOURCE_BURN, root, totalShare);

        uint256 balance = totalShare + (seed % 1e9);
        token.mint(address(airdrop), balance);

        uint256[] memory order = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            order[i] = i;
        }
        for (uint256 i = n; i > 1; --i) {
            uint256 j = uint256(keccak256(abi.encode(seed, i))) % i;
            (order[i - 1], order[j]) = (order[j], order[i - 1]);
        }

        uint256 paid;
        for (uint256 k; k < n; ++k) {
            uint256 i = order[k];
            vm.prank(accounts[i]);
            paid += airdrop.claim(address(token), accounts[i], normalized[i], proofs[i]);
        }

        assertEq(paid, balance);
        assertEq(token.balanceOf(address(airdrop)), 0);
        assertEq(airdrop.claimedShare(address(token)), totalShare);
    }

    function test_ZeroAmountDoesNotConsumeEligibility() public {
        address[] memory accounts = new address[](2);
        uint256[] memory shares = new uint256[](2);
        accounts[0] = alice;
        accounts[1] = bob;
        shares[0] = 0.2 ether;
        shares[1] = 0.3 ether;
        uint256[] memory normalized = builder.normalizeShares(shares);
        (bytes32 root,, bytes32[][] memory proofs) = builder.build(accounts, shares);

        Airdrop airdrop = new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, SOURCE_BURN, root, 1 ether);
        token.mint(address(airdrop), 1);

        // floor(1 * 0.4e18 / 1e18) == 0: eligible, but not claimable yet.
        vm.prank(alice);
        vm.expectRevert(IAirdrop.NoClaimableAmount.selector);
        airdrop.claim(address(token), alice, normalized[0], proofs[0]);
        assertFalse(airdrop.isClaimed(address(token), alice));

        token.mint(address(airdrop), 4);
        vm.prank(alice);
        assertEq(airdrop.claim(address(token), alice, normalized[0], proofs[0]), 2);
    }

    function test_FullyClaimedPoolKeepsLaterTransfersStuck() public {
        address[] memory accounts = new address[](1);
        uint256[] memory shares = new uint256[](1);
        accounts[0] = alice;
        shares[0] = 0.5 ether;
        uint256[] memory normalized = builder.normalizeShares(shares);
        (bytes32 root,, bytes32[][] memory proofs) = builder.build(accounts, shares);

        Airdrop airdrop = new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, SOURCE_BURN, root, 1 ether);
        token.mint(address(airdrop), 100 ether);
        vm.prank(alice);
        airdrop.claim(address(token), alice, normalized[0], proofs[0]);

        token.mint(address(airdrop), 7 ether);
        vm.prank(alice);
        vm.expectRevert(IAirdrop.AirdropAlreadyClaimed.selector);
        airdrop.claim(address(token), alice, normalized[0], proofs[0]);
        assertEq(airdrop.claimableAmount(address(token), alice, normalized[0], proofs[0]), 0);
        assertEq(token.balanceOf(address(airdrop)), 7 ether);
    }

    // ------------------------------------------------------------------
    // Deployment-parameter mismatch (documented trust boundary)
    // ------------------------------------------------------------------

    function test_MisconfiguredLowerTotalShareBlocksTailClaimer() public {
        // The generator now normalises to exactly 1e18, so a snapshot whose leaf
        // sum differs from `totalShare` can only be produced by a hand-rolled
        // deployment. This regression pins the consequence of that misconfiguration.
        (bytes32 root, bytes32[][] memory proofs) = _legacyRawTree();

        // totalShare (0.8e18) is intentionally smaller than the leaf sum (0.9e18).
        Airdrop airdrop = new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, SOURCE_BURN, root, 0.8 ether);
        token.mint(address(airdrop), 800 ether);

        vm.prank(alice);
        airdrop.claim(address(token), alice, 0.2 ether, proofs[0]);
        vm.prank(bob);
        airdrop.claim(address(token), bob, 0.3 ether, proofs[1]);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IAirdrop.ShareExceedsRemaining.selector, 0.4 ether, 0.3 ether));
        airdrop.claim(address(token), carol, 0.4 ether, proofs[2]);

        // No top-up can ever unblock the tail claimer.
        token.mint(address(airdrop), 100 ether);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IAirdrop.ShareExceedsRemaining.selector, 0.4 ether, 0.3 ether));
        airdrop.claim(address(token), carol, 0.4 ether, proofs[2]);
    }

    function test_MisconfiguredHigherTotalShareLocksResidue() public {
        (bytes32 root, bytes32[][] memory proofs) = _legacyRawTree();

        // totalShare (1e18) is intentionally larger than the leaf sum (0.9e18).
        Airdrop airdrop = new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, SOURCE_BURN, root, 1 ether);
        token.mint(address(airdrop), 900 ether);

        vm.prank(alice);
        airdrop.claim(address(token), alice, 0.2 ether, proofs[0]);
        vm.prank(bob);
        airdrop.claim(address(token), bob, 0.3 ether, proofs[1]);
        vm.prank(carol);
        airdrop.claim(address(token), carol, 0.4 ether, proofs[2]);

        assertEq(airdrop.remainingShare(address(token)), 0.1 ether);
        assertEq(token.balanceOf(address(airdrop)), 90 ether);
        token.mint(address(airdrop), 10 ether);
        assertEq(token.balanceOf(address(airdrop)), 100 ether);
    }

    // ------------------------------------------------------------------
    // Error precedence
    // ------------------------------------------------------------------

    function test_ThirdPartyIsRejectedBeforeProofValidation() public {
        address[] memory accounts = new address[](1);
        uint256[] memory shares = new uint256[](1);
        accounts[0] = alice;
        shares[0] = 0.5 ether;
        uint256[] memory normalized = builder.normalizeShares(shares);
        (bytes32 root,,) = builder.build(accounts, shares);

        Airdrop airdrop = new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, SOURCE_BURN, root, 1 ether);
        token.mint(address(airdrop), 100 ether);

        // An empty/invalid proof would be InvalidProof if the proof were checked
        // first; the unauthorized caller is rejected regardless of proof quality.
        vm.prank(relayer);
        vm.expectRevert(IAirdrop.UnauthorizedClaimer.selector);
        airdrop.claim(address(token), alice, normalized[0], new bytes32[](0));

        assertFalse(airdrop.isClaimed(address(token), alice));
        assertEq(airdrop.remainingShare(address(token)), 1 ether);
    }

    /// @dev Three-leaf tree over the raw (0.2, 0.3, 0.4 ether) shares, i.e. a leaf
    ///      sum of 0.9e18 that no longer matches the normalised 1e18 totalShare.
    ///      Only the pre-normalisation deployment could produce such a snapshot.
    function _legacyRawTree() internal view returns (bytes32 root, bytes32[][] memory proofs) {
        bytes32 leaf0 = _leaf(alice, 0.2 ether);
        bytes32 leaf1 = _leaf(bob, 0.3 ether);
        bytes32 leaf2 = _leaf(carol, 0.4 ether);
        bytes32 pair01 = _hashPair(leaf0, leaf1);
        root = _hashPair(pair01, leaf2);

        proofs = new bytes32[][](3);
        proofs[0] = new bytes32[](2);
        proofs[0][0] = leaf1;
        proofs[0][1] = leaf2;
        proofs[1] = new bytes32[](2);
        proofs[1][0] = leaf0;
        proofs[1][1] = leaf2;
        proofs[2] = new bytes32[](1);
        proofs[2][0] = pair01;
    }

    function _leaf(address account, uint256 share) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, share))));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(bytes.concat(a, b)) : keccak256(bytes.concat(b, a));
    }
}

/// @dev Token that reenters `Airdrop.claim` from its transfer hook.
contract ReenteringAirdropToken is ERC20 {
    Airdrop internal target;
    address internal claimer;
    uint256 internal attackShare;
    bytes32[] internal attackProof;
    bool internal attack;

    constructor() ERC20("Reenter", "RE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configure(address target_, address claimer_, uint256 share_, bytes32[] calldata proof_) external {
        target = Airdrop(target_);
        claimer = claimer_;
        attackShare = share_;
        attackProof = proof_;
        attack = true;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        super._transfer(from, to, amount);
        if (attack) {
            attack = false;
            target.claim(address(this), claimer, attackShare, attackProof);
        }
    }
}

/// @dev USDT-style ERC20 whose `transfer` returns no data.
contract EmptyReturnToken {
    mapping(address => uint256) internal _balances;

    function setBalance(address account, uint256 amount) external {
        _balances[account] = amount;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external {
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
    }
}

/// @dev Non-standard ERC20 whose `transfer` returns false without moving funds.
contract FalseReturnToken {
    mapping(address => uint256) internal _balances;

    function setBalance(address account, uint256 amount) external {
        _balances[account] = amount;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}
