// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {IAirdrop} from "./interface/IAirdrop.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract Airdrop is IAirdrop, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;

    uint256 public immutable override sourceChainId;
    uint256 public immutable override sourceBlockNumber;
    address public immutable override sourceBurnAddress;
    bytes32 public immutable override merkleRoot;
    uint256 public immutable override totalShare;

    // token => cumulative source share consumed by successful claims
    mapping(address => uint256) public override claimedShare;
    // token => source account => whether this token was successfully claimed
    mapping(address => mapping(address => bool)) private _claimed;

    constructor(
        uint256 sourceChainId_,
        uint256 sourceBlockNumber_,
        address sourceBurnAddress_,
        bytes32 merkleRoot_,
        uint256 totalShare_
    ) {
        if (sourceChainId_ == 0) revert InvalidSourceChainId();
        if (sourceBurnAddress_ == address(0)) revert ZeroAddress();
        if (sourceBlockNumber_ == 0) revert InvalidSourceBlock();
        if (merkleRoot_ == bytes32(0)) revert InvalidMerkleRoot();
        if (totalShare_ == 0 || totalShare_ > WAD) revert InvalidTotalShare();

        sourceChainId = sourceChainId_;
        sourceBlockNumber = sourceBlockNumber_;
        sourceBurnAddress = sourceBurnAddress_;
        merkleRoot = merkleRoot_;
        totalShare = totalShare_;
    }

    function remainingShare(address token) public view override returns (uint256) {
        return totalShare - claimedShare[token];
    }

    function isClaimed(address token, address account) external view override returns (bool) {
        return _claimed[token][account];
    }

    function leafHash(address account, uint256 share) public pure override returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, share))));
    }

    function claimableAmount(address token, address account, uint256 share, bytes32[] calldata proof)
        external
        view
        override
        returns (uint256 amount)
    {
        if (!_isClaimable(token, account, share, proof)) return 0;
        amount = Math.mulDiv(IERC20(token).balanceOf(address(this)), share, remainingShare(token));
    }

    function claim(address token, address account, uint256 share, bytes32[] calldata proof)
        external
        override
        nonReentrant
        returns (uint256 amount)
    {
        _requireClaim(token, account, share, proof);
        if (msg.sender != account) revert UnauthorizedClaimer();

        uint256 remaining = remainingShare(token);
        amount = Math.mulDiv(IERC20(token).balanceOf(address(this)), share, remaining);
        if (amount == 0) revert NoClaimableAmount();

        _claimed[token][account] = true;
        claimedShare[token] += share;
        IERC20(token).safeTransfer(account, amount);

        emit AirdropClaimed({
            token: token,
            account: account,
            share: share,
            amount: amount,
            remainingShare: remaining - share
        });
    }

    function _isClaimable(address token, address account, uint256 share, bytes32[] calldata proof)
        internal
        view
        returns (bool)
    {
        if (token == address(0) || token.code.length == 0 || account == address(0) || share == 0) return false;
        if (_claimed[token][account]) return false;
        uint256 remaining = remainingShare(token);
        return share <= remaining && MerkleProof.verifyCalldata(proof, merkleRoot, leafHash(account, share));
    }

    function _requireClaim(address token, address account, uint256 share, bytes32[] calldata proof) internal view {
        if (token == address(0) || token.code.length == 0) revert InvalidToken();
        if (account == address(0)) revert InvalidAccount();
        if (share == 0) revert InvalidShare();
        if (_claimed[token][account]) revert AirdropAlreadyClaimed();

        uint256 remaining = remainingShare(token);
        if (share > remaining) revert ShareExceedsRemaining(share, remaining);
        if (!MerkleProof.verifyCalldata(proof, merkleRoot, leafHash(account, share))) revert InvalidProof();
    }
}
