// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {Test} from "forge-std/Test.sol";
import {Airdrop} from "../src/Airdrop.sol";
import {IAirdrop} from "../src/interface/IAirdrop.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockERC20} from "./mocks/MockProtocol.sol";
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
        (bytes32 root,, bytes32[][] memory proofs) = builder.build(accounts, shares);

        Airdrop airdrop = new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, SOURCE_BURN, root, 0.5 ether);
        reentering.mint(address(airdrop), 500 ether);
        reentering.configure(address(airdrop), alice, 0.3 ether, proofs[1]);

        vm.prank(alice);
        vm.expectRevert(bytes("ReentrancyGuard: reentrant call"));
        airdrop.claim(address(reentering), alice, 0.2 ether, proofs[0]);

        assertFalse(airdrop.isClaimed(address(reentering), alice));
        assertEq(airdrop.remainingShare(address(reentering)), 0.5 ether);
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
        (bytes32 root,, bytes32[][] memory proofs) = builder.build(accounts, shares);

        Airdrop airdrop = new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, SOURCE_BURN, root, 0.5 ether);
        falseToken.setBalance(address(airdrop), 100 ether);

        vm.prank(alice);
        vm.expectRevert(bytes("SafeERC20: ERC20 operation did not succeed"));
        airdrop.claim(address(falseToken), alice, 0.5 ether, proofs[0]);

        assertFalse(airdrop.isClaimed(address(falseToken), alice));
        assertEq(airdrop.remainingShare(address(falseToken)), 0.5 ether);
        assertEq(airdrop.claimedAmount(address(falseToken), alice), 0);
    }

    function test_EmptyReturnTokenIsAccepted() public {
        EmptyReturnToken emptyToken = new EmptyReturnToken();

        address[] memory accounts = new address[](1);
        uint256[] memory shares = new uint256[](1);
        accounts[0] = alice;
        shares[0] = 0.5 ether;
        (bytes32 root,, bytes32[][] memory proofs) = builder.build(accounts, shares);

        Airdrop airdrop = new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, SOURCE_BURN, root, 0.5 ether);
        emptyToken.setBalance(address(airdrop), 100 ether);

        vm.prank(alice);
        assertEq(airdrop.claim(address(emptyToken), alice, 0.5 ether, proofs[0]), 100 ether);
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
        (bytes32 root,, bytes32[][] memory proofs) = builder.build(accounts, shares);

        Airdrop airdrop = new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, SOURCE_BURN, root, 0.5 ether);
        token.mint(address(airdrop), 100 ether);

        vm.prank(alice);
        assertEq(airdrop.claim(address(token), alice, 0.5 ether, proofs[0]), 100 ether);
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
        (bytes32 root, uint256 totalShare, bytes32[][] memory proofs) = builder.build(accounts, shares);

        Airdrop airdrop = new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, SOURCE_BURN, root, totalShare);
        token.mint(address(airdrop), 1_000 ether);

        for (uint256 i; i < accounts.length; ++i) {
            vm.prank(accounts[i]);
            airdrop.claim(address(token), accounts[i], shares[i], proofs[i]);
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

        (bytes32 root, uint256 totalShare, bytes32[][] memory proofs) = builder.build(accounts, shares);
        assertEq(totalShare, 1 ether);

        Airdrop airdrop = new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, SOURCE_BURN, root, totalShare);
        token.mint(address(airdrop), 1_000 ether);

        for (uint256 i; i < accounts.length; ++i) {
            vm.prank(accounts[i]);
            airdrop.claim(address(token), accounts[i], shares[i], proofs[i]);
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
            paid += airdrop.claim(address(token), accounts[i], shares[i], proofs[i]);
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
        (bytes32 root,, bytes32[][] memory proofs) = builder.build(accounts, shares);

        Airdrop airdrop = new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, SOURCE_BURN, root, 0.5 ether);
        token.mint(address(airdrop), 1);

        // floor(1 * 0.2e18 / 0.5e18) == 0: eligible, but not claimable yet.
        vm.prank(alice);
        vm.expectRevert(IAirdrop.NoClaimableAmount.selector);
        airdrop.claim(address(token), alice, 0.2 ether, proofs[0]);
        assertFalse(airdrop.isClaimed(address(token), alice));

        token.mint(address(airdrop), 4);
        vm.prank(alice);
        assertEq(airdrop.claim(address(token), alice, 0.2 ether, proofs[0]), 2);
    }

    function test_FullyClaimedPoolKeepsLaterTransfersStuck() public {
        address[] memory accounts = new address[](1);
        uint256[] memory shares = new uint256[](1);
        accounts[0] = alice;
        shares[0] = 0.5 ether;
        (bytes32 root,, bytes32[][] memory proofs) = builder.build(accounts, shares);

        Airdrop airdrop = new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, SOURCE_BURN, root, 0.5 ether);
        token.mint(address(airdrop), 100 ether);
        vm.prank(alice);
        airdrop.claim(address(token), alice, 0.5 ether, proofs[0]);

        token.mint(address(airdrop), 7 ether);
        vm.prank(alice);
        vm.expectRevert(IAirdrop.AirdropAlreadyClaimed.selector);
        airdrop.claim(address(token), alice, 0.5 ether, proofs[0]);
        assertEq(airdrop.claimableAmount(address(token), alice, 0.5 ether, proofs[0]), 0);
        assertEq(token.balanceOf(address(airdrop)), 7 ether);
    }

    // ------------------------------------------------------------------
    // Deployment-parameter mismatch (documented trust boundary)
    // ------------------------------------------------------------------

    function test_MisconfiguredLowerTotalShareBlocksTailClaimer() public {
        address[] memory accounts = new address[](3);
        uint256[] memory shares = new uint256[](3);
        accounts[0] = alice;
        accounts[1] = bob;
        accounts[2] = carol;
        shares[0] = 0.2 ether;
        shares[1] = 0.3 ether;
        shares[2] = 0.4 ether;
        (bytes32 root,, bytes32[][] memory proofs) = builder.build(accounts, shares);

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
        address[] memory accounts = new address[](3);
        uint256[] memory shares = new uint256[](3);
        accounts[0] = alice;
        accounts[1] = bob;
        accounts[2] = carol;
        shares[0] = 0.2 ether;
        shares[1] = 0.3 ether;
        shares[2] = 0.4 ether;
        (bytes32 root,, bytes32[][] memory proofs) = builder.build(accounts, shares);

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
        (bytes32 root,,) = builder.build(accounts, shares);

        Airdrop airdrop = new Airdrop(SOURCE_CHAIN_ID, SOURCE_BLOCK_NUMBER, SOURCE_BURN, root, 0.5 ether);
        token.mint(address(airdrop), 100 ether);

        // An empty/invalid proof would be InvalidProof if the proof were checked
        // first; the unauthorized caller is rejected regardless of proof quality.
        vm.prank(relayer);
        vm.expectRevert(IAirdrop.UnauthorizedClaimer.selector);
        airdrop.claim(address(token), alice, 0.5 ether, new bytes32[](0));

        assertFalse(airdrop.isClaimed(address(token), alice));
        assertEq(airdrop.remainingShare(address(token)), 0.5 ether);
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
