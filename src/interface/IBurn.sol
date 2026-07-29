// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

struct CommunityWeight {
    string tokenSymbol;
    uint256 weight;
}

struct ActionRewardBurnRequest {
    address tokenAddress;
    uint256 actionId;
    uint256 amount;
}

struct RewardBurnState {
    /// @dev Only claimableRewardAmount is populated before minting; only claimedRewardAmount after minting.
    uint256 claimableRewardAmount;
    uint256 claimedRewardAmount;
    bool isClaimed;
    uint256 burnQuotaAmount;
    uint256 burnedAmount;
    uint256 unusedQuotaAmount;
}

struct ActionRewardBurnState {
    uint256 actionId;
    address extensionAddress;
    RewardBurnState reward;
}

struct CategoryStats {
    uint256 amount;
    uint256 score;
}

struct BurnStats {
    CategoryStats slTokenLock;
    CategoryStats stTokenLock;
    CategoryStats govRewardBurn;
    CategoryStats actionRewardBurn;
}

struct TokenShare {
    uint256 slTokenLock;
    uint256 stTokenLock;
    uint256 govRewardBurn;
    uint256 actionRewardBurn;
    uint256 total;
    bool finalized;
}

struct AirdropState {
    bool enabled;
    bool shareFinalized;
    bool isClaimed;
    uint256 share;
    uint256 claimableAmount;
    uint256 claimedAmount;
}

interface IBurnEvents {
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
    event AirdropClaimed(address indexed account, uint256 share, uint256 amount, uint256 remainingShare);
}

interface IBurnErrors {
    error ZeroAddress();
    error ZeroAmount();
    error EmptyBatch();
    error InvalidScopeToken(string tokenSymbol);
    error InvalidAirdropToken(address tokenAddress);
    error InvalidRoundCount();
    error InvalidQuotaMultiplier();
    error StartRoundTooEarly(uint256 currentVerifyRound, uint256 startRound);
    error DuplicateExtensionFactory(address factory);
    error InvalidCommunityConfig(string tokenSymbol);
    error DuplicateCommunity(string tokenSymbol);
    error MissingScopeCommunity();
    error InvalidScoreBase(address tokenAddress);
    error UnsupportedCommunity(address tokenAddress);
    error RoundNotOpen(uint256 round, uint256 currentVerifyRound);
    error NoClaimedReward();
    error BurnQuotaExceeded(uint256 unusedQuotaAmount, uint256 requestedAmount);
    error UnsupportedExtensionFactory(address factory);
    error AirdropDisabled();
    error ShareNotFinalized();
    error AirdropAlreadyClaimed();
    error NoClaimableAirdrop();
}

interface IBurn is IBurnEvents, IBurnErrors {
    function extensionCenter() external view returns (address);
    function scopeTokenSymbol() external view returns (string memory);
    function scopeTokenAddress() external view returns (address);
    function airdropTokenAddress() external view returns (address);
    function startRound() external view returns (uint256);
    function roundCount() external view returns (uint256);
    function endRound() external view returns (uint256);
    function quotaMultiplier() external view returns (uint256);
    function totalCommunityWeight() external view returns (uint256);
    function remainingAirdropShare() external view returns (uint256);

    function communities() external view returns (address[] memory);
    function communitySymbols() external view returns (string[] memory);
    function communityWeight(address tokenAddress) external view returns (uint256);
    function scoreBase(address tokenAddress) external view returns (uint256);
    function supportedExtensionFactories() external view returns (address[] memory);
    function isSupportedExtensionFactory(address factory) external view returns (bool);

    function isRoundOpen(uint256 round) external view returns (bool);
    function scoreMultiplier(address tokenAddress, uint256 round) external view returns (uint256 multiplier);

    function lockSLToken(address tokenAddress, uint256 round, uint256 amount) external;
    function lockSTToken(address tokenAddress, uint256 round, uint256 amount) external;
    function burnGovRewardToken(address tokenAddress, uint256 round, uint256 amount) external;
    function burnActionRewardTokens(uint256 round, ActionRewardBurnRequest[] calldata requests) external;
    function claimAirdrop() external returns (uint256 amount);

    function govRewardBurnState(address account, address tokenAddress, uint256 round)
        external
        view
        returns (RewardBurnState memory);
    function actionRewardBurnStates(address account, address tokenAddress, uint256 round)
        external
        view
        returns (ActionRewardBurnState[] memory);
    function accountRoundBurnStats(address account, address tokenAddress, uint256 round)
        external
        view
        returns (BurnStats memory);
    function accountBurnStatsThroughRound(address account, address tokenAddress, uint256 round)
        external
        view
        returns (BurnStats memory);
    function accountBurnStats(address account, address tokenAddress) external view returns (BurnStats memory);
    function communityRoundBurnStats(address tokenAddress, uint256 round) external view returns (BurnStats memory);
    function communityBurnStatsThroughRound(address tokenAddress, uint256 round)
        external
        view
        returns (BurnStats memory);
    function communityBurnStats(address tokenAddress) external view returns (BurnStats memory);
    function accountTokenShare(address account, address tokenAddress) external view returns (TokenShare memory);
    function accountShare(address account) external view returns (uint256 share, bool finalized);

    function participantsCount() external view returns (uint256);
    function participants(uint256 offset, uint256 limit) external view returns (address[] memory);
    function isParticipant(address account) external view returns (bool);
    function accountAirdropState(address account) external view returns (AirdropState memory);
}
