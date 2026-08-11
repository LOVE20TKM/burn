// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

interface IAirdrop {
    event AirdropClaimed(
        address indexed token, address indexed account, uint256 share, uint256 amount, uint256 remainingShare
    );

    error ZeroAddress();
    error InvalidSourceChainId();
    error InvalidSourceBlock();
    error InvalidMerkleRoot();
    error InvalidTotalShare();
    error InvalidToken();
    error InvalidAccount();
    error InvalidShare();
    error InvalidProof();
    error UnauthorizedClaimer();
    error ShareExceedsRemaining(uint256 share, uint256 remainingShare);
    error AirdropAlreadyClaimed();
    error NoClaimableAmount();

    function sourceChainId() external view returns (uint256);
    function sourceBlockNumber() external view returns (uint256);
    function sourceBurnAddress() external view returns (address);
    function merkleRoot() external view returns (bytes32);
    function totalShare() external view returns (uint256);

    function claimedShare(address token) external view returns (uint256);
    function remainingShare(address token) external view returns (uint256);
    function isClaimed(address token, address account) external view returns (bool);

    function leafHash(address account, uint256 share) external pure returns (bytes32);

    function claimableAmount(address token, address account, uint256 share, bytes32[] calldata proof)
        external
        view
        returns (uint256 amount);

    function claim(address token, address account, uint256 share, bytes32[] calldata proof)
        external
        returns (uint256 amount);
}
