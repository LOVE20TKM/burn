// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {
    IBurn,
    CommunityWeight,
    BurnRoundConfig,
    CategoryStats,
    BurnStats,
    RewardBurnState,
    ActionRewardBurnRequest,
    ActionRewardBurnState,
    TokenShare,
    AirdropState
} from "./interface/IBurn.sol";
import {IExtensionCenter} from "@extension/interface/IExtensionCenter.sol";
import {IReward} from "@extension/interface/IReward.sol";
import {ILOVE20Launch, LaunchInfo} from "@core/interfaces/ILOVE20Launch.sol";
import {ILOVE20Mint} from "@core/interfaces/ILOVE20Mint.sol";
import {ILOVE20Token} from "@core/interfaces/ILOVE20Token.sol";
import {ILOVE20Vote} from "@core/interfaces/ILOVE20Vote.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {ArrayUtils} from "@core/lib/ArrayUtils.sol";

contract Burn is IBurn, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ArrayUtils for uint256[];

    uint256 internal constant WAD = 1e18;

    enum Category {
        SLTokenLock,
        STTokenLock,
        GovRewardBurn,
        ActionRewardBurn
    }

    struct CategoryStatsHistory {
        uint256[] changeRounds;
        // round => cumulativeStats
        mapping(uint256 => CategoryStats) statsByRound;
    }

    struct BurnStatsHistory {
        CategoryStatsHistory slTokenLock;
        CategoryStatsHistory stTokenLock;
        CategoryStatsHistory govRewardBurn;
        CategoryStatsHistory actionRewardBurn;
    }

    address public immutable override extensionCenter;
    string public override scopeTokenSymbol;
    address public immutable override scopeTokenAddress;
    address public immutable override airdropTokenAddress;
    uint256 public immutable override startRound;
    uint256 public immutable override roundCount;
    uint256 public immutable override endRound;
    uint256 public immutable override quotaMultiplier;
    uint256 public immutable override slTokenLockWeight;
    uint256 public immutable override stTokenLockWeight;
    uint256 public immutable override govRewardBurnWeight;
    uint256 public immutable override actionRewardBurnWeight;

    uint256 public override totalCommunityWeight;
    uint256 public override remainingAirdropShare = WAD;

    ILOVE20Launch internal immutable _launch;
    ILOVE20Mint internal immutable _mint;
    ILOVE20Vote internal immutable _vote;
    IExtensionCenter internal immutable _center;

    address[] internal _communities;
    string[] internal _communitySymbols;
    // tokenAddress => weight
    mapping(address => uint256) internal _communityWeight;
    // tokenAddress => scoreBase
    mapping(address => uint256) internal _scoreBase;

    address[] internal _supportedExtensionFactories;
    // factory => isSupported
    mapping(address => bool) internal _isSupportedExtensionFactory;

    // account => tokenAddress => cumulativeHistory
    mapping(address => mapping(address => BurnStatsHistory)) internal _accountBurnStatsHistory;
    // tokenAddress => cumulativeHistory
    mapping(address => BurnStatsHistory) internal _communityBurnStatsHistory;
    // account => tokenAddress => round => actionId => burnedAmount
    mapping(address => mapping(address => mapping(uint256 => mapping(uint256 => uint256)))) internal _actionRewardBurned;

    // tokenAddress => slTokenAddress
    mapping(address => address) internal _slTokenAddress;
    // tokenAddress => stTokenAddress
    mapping(address => address) internal _stTokenAddress;

    address[] internal _participants;
    // account => isParticipant
    mapping(address => bool) internal _isParticipant;
    // account => claimedAmount
    mapping(address => uint256) internal _claimedAirdropAmount;

    constructor(
        address extensionCenterAddress,
        string memory scopeTokenSymbol_,
        address airdropTokenAddress_,
        CommunityWeight[] memory communityWeights,
        uint256 slTokenLockWeight_,
        uint256 stTokenLockWeight_,
        uint256 govRewardBurnWeight_,
        uint256 actionRewardBurnWeight_,
        BurnRoundConfig memory roundConfig,
        address[] memory supportedExtensionFactories_
    ) {
        if (extensionCenterAddress == address(0)) revert ZeroAddress();
        if (roundConfig.roundCount == 0) revert InvalidRoundCount();
        if (roundConfig.quotaMultiplier == 0) revert InvalidQuotaMultiplier();
        _validateCategoryWeights(slTokenLockWeight_, stTokenLockWeight_, govRewardBurnWeight_, actionRewardBurnWeight_);

        IExtensionCenter center = IExtensionCenter(extensionCenterAddress);
        ILOVE20Launch launch = ILOVE20Launch(center.launchAddress());
        ILOVE20Vote vote = ILOVE20Vote(center.voteAddress());
        address scopeTokenAddress_ = launch.tokenAddressBySymbol(scopeTokenSymbol_);
        if (!_isEndedLOVE20Token(launch, scopeTokenAddress_)) {
            revert InvalidScopeToken(scopeTokenSymbol_);
        }
        if (
            airdropTokenAddress_ != address(0)
                && (airdropTokenAddress_ == scopeTokenAddress_ || airdropTokenAddress_.code.length == 0)
        ) {
            revert InvalidAirdropToken(airdropTokenAddress_);
        }
        uint256 minimumStartRound = vote.currentRound() - 2;
        if (roundConfig.startRound < minimumStartRound) {
            revert StartRoundTooEarly(minimumStartRound, roundConfig.startRound);
        }

        extensionCenter = extensionCenterAddress;
        scopeTokenSymbol = scopeTokenSymbol_;
        scopeTokenAddress = scopeTokenAddress_;
        airdropTokenAddress = airdropTokenAddress_;
        startRound = roundConfig.startRound;
        roundCount = roundConfig.roundCount;
        endRound = roundConfig.startRound + roundConfig.roundCount - 1;
        quotaMultiplier = roundConfig.quotaMultiplier;
        slTokenLockWeight = slTokenLockWeight_;
        stTokenLockWeight = stTokenLockWeight_;
        govRewardBurnWeight = govRewardBurnWeight_;
        actionRewardBurnWeight = actionRewardBurnWeight_;
        _launch = launch;
        _mint = ILOVE20Mint(center.mintAddress());
        _vote = vote;
        _center = center;

        _freezeCommunities(scopeTokenAddress_, communityWeights);
        _freezeExtensionFactories(supportedExtensionFactories_);
    }

    function _validateCategoryWeights(uint256 slWeight, uint256 stWeight, uint256 govWeight, uint256 actionWeight)
        internal
        pure
    {
        if (slWeight == 0 && stWeight == 0 && govWeight == 0 && actionWeight == 0) {
            revert InvalidCategoryWeights();
        }
        uint256 total = slWeight;
        if (stWeight > type(uint256).max - total) revert InvalidCategoryWeights();
        total += stWeight;
        if (govWeight > type(uint256).max - total) revert InvalidCategoryWeights();
        total += govWeight;
        if (actionWeight > type(uint256).max - total) revert InvalidCategoryWeights();
    }

    function _freezeCommunities(address scopeTokenAddress_, CommunityWeight[] memory communityWeights) internal {
        bool scopeCommunityFound;
        uint256 totalWeight;
        uint256 rewardRatePerThousand = _mint.ROUND_REWARD_GOV_PER_THOUSAND() + _mint.ROUND_REWARD_ACTION_PER_THOUSAND();
        uint256 communityCount = communityWeights.length;
        for (uint256 i; i < communityCount;) {
            CommunityWeight memory config = communityWeights[i];
            address tokenAddress = _launch.tokenAddressBySymbol(config.tokenSymbol);
            if (tokenAddress == address(0) || config.weight == 0) {
                revert InvalidCommunityConfig(config.tokenSymbol);
            }
            if (_communityWeight[tokenAddress] != 0) {
                revert DuplicateCommunity(config.tokenSymbol);
            }
            if (tokenAddress == scopeTokenAddress_) {
                scopeCommunityFound = true;
            } else {
                LaunchInfo memory info = _launch.launchInfo(tokenAddress);
                if (
                    !_launch.isLOVE20Token(tokenAddress) || !info.hasEnded
                        || info.parentTokenAddress != scopeTokenAddress_
                ) {
                    revert InvalidCommunityConfig(config.tokenSymbol);
                }
            }

            ILOVE20Token token = ILOVE20Token(tokenAddress);
            uint256 totalSupply = token.totalSupply();
            uint256 maxSupply = token.maxSupply();
            if (totalSupply == 0 || totalSupply > maxSupply) {
                revert InvalidScoreBase(tokenAddress);
            }
            uint256 deploymentRoundReward = Math.mulDiv(maxSupply - totalSupply, rewardRatePerThousand, 1000);
            uint256 scoreBase_ = WAD + Math.mulDiv(deploymentRoundReward, WAD, totalSupply);

            _communities.push(tokenAddress);
            _communitySymbols.push(config.tokenSymbol);
            _communityWeight[tokenAddress] = config.weight;
            _scoreBase[tokenAddress] = scoreBase_;
            if (slTokenLockWeight > 0) _slTokenAddress[tokenAddress] = token.slAddress();
            if (stTokenLockWeight > 0) _stTokenAddress[tokenAddress] = token.stAddress();
            totalWeight += config.weight;

            emit CommunityConfigFrozen(
                tokenAddress, config.tokenSymbol, config.weight, scoreBase_, totalSupply, deploymentRoundReward
            );
            unchecked {
                ++i;
            }
        }
        if (!scopeCommunityFound) revert MissingScopeCommunity();
        totalCommunityWeight = totalWeight;
    }

    function _freezeExtensionFactories(address[] memory supportedExtensionFactories_) internal {
        uint256 factoryCount = supportedExtensionFactories_.length;
        for (uint256 i; i < factoryCount;) {
            address factory = supportedExtensionFactories_[i];
            if (factory == address(0)) revert ZeroAddress();
            if (_isSupportedExtensionFactory[factory]) {
                revert DuplicateExtensionFactory(factory);
            }
            _supportedExtensionFactories.push(factory);
            _isSupportedExtensionFactory[factory] = true;
            emit SupportedExtensionFactoryFrozen(factory);
            unchecked {
                ++i;
            }
        }
    }

    function communities() external view override returns (address[] memory) {
        return _communities;
    }

    function communitySymbols() external view override returns (string[] memory) {
        return _communitySymbols;
    }

    function communityWeight(address tokenAddress) external view override returns (uint256) {
        return _communityWeight[tokenAddress];
    }

    function scoreBase(address tokenAddress) external view override returns (uint256) {
        return _scoreBase[tokenAddress];
    }

    function supportedExtensionFactories() external view override returns (address[] memory) {
        return _supportedExtensionFactories;
    }

    function isSupportedExtensionFactory(address factory) external view override returns (bool) {
        return _isSupportedExtensionFactory[factory];
    }

    function isRoundOpen(uint256 round) public view override returns (bool) {
        uint256 currentVoteRound = _vote.currentRound();
        return currentVoteRound > 2 && _isRoundOpen(round, currentVoteRound - 3);
    }

    function scoreMultiplier(address tokenAddress, uint256 round) public view override returns (uint256 multiplier) {
        return _scoreMultiplier(_requireCommunity(tokenAddress), round);
    }

    function lockSLToken(address tokenAddress, uint256 round, uint256 amount) external override {
        _lockReceipt(tokenAddress, round, amount, Category.SLTokenLock);
    }

    function lockSTToken(address tokenAddress, uint256 round, uint256 amount) external override {
        _lockReceipt(tokenAddress, round, amount, Category.STTokenLock);
    }

    function burnGovRewardToken(address tokenAddress, uint256 round, uint256 amount) external override {
        uint256 multiplier = _validateOperation(tokenAddress, round, amount, govRewardBurnWeight);
        uint256 actualMintedReward = _mint.govRewardMintedByAccount(tokenAddress, round, msg.sender);
        if (actualMintedReward == 0) revert NoClaimedReward();

        uint256 quota = actualMintedReward * quotaMultiplier;
        uint256 burned = _latestRoundAmount(_accountBurnStatsHistory[msg.sender][tokenAddress].govRewardBurn, round);
        uint256 unusedQuota = quota - burned;
        if (amount > unusedQuota) {
            revert BurnQuotaExceeded(unusedQuota, amount);
        }

        uint256 operationScore =
            _recordBurnStats(msg.sender, tokenAddress, round, Category.GovRewardBurn, amount, multiplier);
        IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), amount);
        ILOVE20Token(tokenAddress).burn(amount);
        _addParticipant(msg.sender);
        _emitGovRewardBurned(tokenAddress, round, amount, multiplier, operationScore);
    }

    function burnActionRewardTokens(uint256 round, ActionRewardBurnRequest[] calldata requests) external override {
        uint256 length = requests.length;
        if (length == 0) revert EmptyBatch();
        if (actionRewardBurnWeight == 0) revert CategoryDisabled();
        _requireOpenRound(round);
        for (uint256 i; i < length;) {
            _burnActionRewardToken(round, requests[i]);
            unchecked {
                ++i;
            }
        }
        _addParticipant(msg.sender);
    }

    function govRewardBurnState(address account, address tokenAddress, uint256 round)
        external
        view
        override
        returns (RewardBurnState memory state)
    {
        _requireCommunity(tokenAddress);
        if (round < startRound || round > endRound) return state;

        uint256 actualMintedReward = _mint.govRewardMintedByAccount(tokenAddress, round, account);
        if (actualMintedReward == 0) {
            (uint256 verifyReward, uint256 boostReward,,) = _mint.govRewardByAccount(tokenAddress, round, account);
            state.claimableRewardAmount = verifyReward + boostReward;
            return state;
        }

        state.isClaimed = true;
        state.claimedRewardAmount = actualMintedReward;
        state.burnQuotaAmount = actualMintedReward * quotaMultiplier;
        state.burnedAmount =
            _categoryStatsAtRound(_accountBurnStatsHistory[account][tokenAddress].govRewardBurn, round).amount;
        state.unusedQuotaAmount = state.burnQuotaAmount - state.burnedAmount;
    }

    function actionRewardBurnStates(address account, address tokenAddress, uint256 round)
        external
        view
        override
        returns (ActionRewardBurnState[] memory states)
    {
        _requireCommunity(tokenAddress);
        if (round < startRound || round > endRound) {
            return new ActionRewardBurnState[](0);
        }

        uint256 actionCount = _vote.votedActionIdsCount(tokenAddress, round);
        states = new ActionRewardBurnState[](actionCount);
        uint256 included;
        for (uint256 i; i < actionCount;) {
            uint256 actionId = _vote.votedActionIdsAtIndex(tokenAddress, round, i);
            (ActionRewardBurnState memory state, bool supported) =
                _actionRewardBurnState(account, tokenAddress, round, actionId);
            if (
                supported
                    && (
                        state.reward.claimableRewardAmount > 0 || state.reward.claimedRewardAmount > 0
                            || state.reward.burnedAmount > 0
                    )
            ) {
                states[included] = state;
                unchecked {
                    ++included;
                }
            }
            unchecked {
                ++i;
            }
        }
        assembly ("memory-safe") {
            mstore(states, included)
        }
    }

    function accountTokenShare(address account, address tokenAddress)
        external
        view
        override
        returns (TokenShare memory share)
    {
        _requireCommunity(tokenAddress);
        return _accountTokenShare(account, tokenAddress, _activeCommunityWeight(), _isFinalized());
    }

    function accountShare(address account) public view override returns (uint256 share, bool finalized) {
        uint256 activeWeight = _activeCommunityWeight();
        finalized = _isFinalized();
        uint256 length = _communities.length;
        for (uint256 i; i < length;) {
            share += _accountTokenShare(account, _communities[i], activeWeight, finalized).total;
            unchecked {
                ++i;
            }
        }
    }

    function accountAirdropState(address account) external view override returns (AirdropState memory state) {
        state.enabled = airdropTokenAddress != address(0);
        (state.share, state.shareFinalized) = accountShare(account);
        state.claimedAmount = _claimedAirdropAmount[account];
        state.isClaimed = state.claimedAmount > 0;
        if (
            !state.enabled || !state.shareFinalized || state.isClaimed || state.share == 0 || remainingAirdropShare == 0
        ) return state;

        state.claimableAmount =
            Math.mulDiv(IERC20(airdropTokenAddress).balanceOf(address(this)), state.share, remainingAirdropShare);
    }

    function claimAirdrop() external override nonReentrant returns (uint256 amount) {
        if (airdropTokenAddress == address(0)) revert AirdropDisabled();
        (uint256 share, bool finalized) = accountShare(msg.sender);
        if (!finalized) revert ShareNotFinalized();
        if (_claimedAirdropAmount[msg.sender] > 0) {
            revert AirdropAlreadyClaimed();
        }
        if (share == 0 || remainingAirdropShare == 0) {
            revert NoClaimableAirdrop();
        }

        amount = Math.mulDiv(IERC20(airdropTokenAddress).balanceOf(address(this)), share, remainingAirdropShare);
        if (amount == 0) revert NoClaimableAirdrop();

        _claimedAirdropAmount[msg.sender] = amount;
        remainingAirdropShare -= share;
        IERC20(airdropTokenAddress).safeTransfer(msg.sender, amount);
        emit AirdropClaimed(msg.sender, share, amount, remainingAirdropShare);
    }

    function accountRoundBurnStats(address account, address tokenAddress, uint256 round)
        external
        view
        override
        returns (BurnStats memory)
    {
        _requireCommunity(tokenAddress);
        return _burnStatsAtRound(_accountBurnStatsHistory[account][tokenAddress], round);
    }

    function accountBurnStats(address account, address tokenAddress)
        external
        view
        override
        returns (BurnStats memory)
    {
        _requireCommunity(tokenAddress);
        return _latestBurnStats(_accountBurnStatsHistory[account][tokenAddress]);
    }

    function accountBurnStatsThroughRound(address account, address tokenAddress, uint256 round)
        external
        view
        override
        returns (BurnStats memory)
    {
        _requireCommunity(tokenAddress);
        return _burnStatsThroughRound(_accountBurnStatsHistory[account][tokenAddress], round);
    }

    function communityRoundBurnStats(address tokenAddress, uint256 round)
        external
        view
        override
        returns (BurnStats memory)
    {
        _requireCommunity(tokenAddress);
        return _burnStatsAtRound(_communityBurnStatsHistory[tokenAddress], round);
    }

    function communityBurnStats(address tokenAddress) external view override returns (BurnStats memory) {
        _requireCommunity(tokenAddress);
        return _latestBurnStats(_communityBurnStatsHistory[tokenAddress]);
    }

    function communityBurnStatsThroughRound(address tokenAddress, uint256 round)
        external
        view
        override
        returns (BurnStats memory)
    {
        _requireCommunity(tokenAddress);
        return _burnStatsThroughRound(_communityBurnStatsHistory[tokenAddress], round);
    }

    function participantsCount() external view override returns (uint256) {
        return _participants.length;
    }

    function participants(uint256 offset, uint256 limit) external view override returns (address[] memory page) {
        uint256 length = _participants.length;
        if (limit == 0 || offset >= length) return new address[](0);
        uint256 count = Math.min(limit, length - offset);
        page = new address[](count);
        for (uint256 i; i < count;) {
            page[i] = _participants[offset + i];
            unchecked {
                ++i;
            }
        }
    }

    function isParticipant(address account) external view override returns (bool) {
        return _isParticipant[account];
    }

    function _lockReceipt(address tokenAddress, uint256 round, uint256 amount, Category category) internal {
        uint256 multiplier = _validateOperation(
            tokenAddress, round, amount, category == Category.SLTokenLock ? slTokenLockWeight : stTokenLockWeight
        );
        uint256 operationScore = _recordBurnStats(msg.sender, tokenAddress, round, category, amount, multiplier);

        address receiptToken =
            category == Category.SLTokenLock ? _slTokenAddress[tokenAddress] : _stTokenAddress[tokenAddress];
        IERC20(receiptToken).safeTransferFrom(msg.sender, tokenAddress, amount);
        _addParticipant(msg.sender);

        CategoryStats memory accountTotal =
            _latestCategoryStats(_categoryHistory(_accountBurnStatsHistory[msg.sender][tokenAddress], category));
        CategoryStats memory communityTotal =
            _latestCategoryStats(_categoryHistory(_communityBurnStatsHistory[tokenAddress], category));

        if (category == Category.SLTokenLock) {
            emit SLTokenLocked(
                tokenAddress,
                msg.sender,
                round,
                amount,
                multiplier,
                operationScore,
                accountTotal.amount,
                accountTotal.score,
                communityTotal.amount,
                communityTotal.score
            );
        } else {
            emit STTokenLocked(
                tokenAddress,
                msg.sender,
                round,
                amount,
                multiplier,
                operationScore,
                accountTotal.amount,
                accountTotal.score,
                communityTotal.amount,
                communityTotal.score
            );
        }
    }

    function _emitGovRewardBurned(
        address tokenAddress,
        uint256 round,
        uint256 amount,
        uint256 multiplier,
        uint256 operationScore
    ) internal {
        CategoryStats memory accountTotal =
            _latestCategoryStats(_accountBurnStatsHistory[msg.sender][tokenAddress].govRewardBurn);
        CategoryStats memory communityTotal =
            _latestCategoryStats(_communityBurnStatsHistory[tokenAddress].govRewardBurn);
        emit GovRewardTokenBurned(
            tokenAddress,
            msg.sender,
            round,
            amount,
            multiplier,
            operationScore,
            accountTotal.amount,
            accountTotal.score,
            communityTotal.amount,
            communityTotal.score
        );
    }

    function _burnActionRewardToken(uint256 round, ActionRewardBurnRequest calldata request) internal {
        address tokenAddress = request.tokenAddress;
        uint256 scoreBase_ = _requireCommunity(tokenAddress);
        if (request.amount == 0) revert ZeroAmount();

        address extensionAddress = _center.extension(tokenAddress, request.actionId);
        uint256 actualMintedReward;
        if (extensionAddress == address(0)) {
            actualMintedReward = _mint.actionRewardMintedByAccount(tokenAddress, round, request.actionId, msg.sender);
        } else {
            address factory = _center.factory(tokenAddress, request.actionId);
            if (!_isSupportedExtensionFactory[factory]) {
                revert UnsupportedExtensionFactory(factory);
            }
            (uint256 mintReward,, bool claimed) = IReward(extensionAddress).rewardByAccount(round, msg.sender);
            if (claimed) actualMintedReward = mintReward;
        }
        if (actualMintedReward == 0) revert NoClaimedReward();

        uint256 quota = actualMintedReward * quotaMultiplier;
        uint256 burned = _actionRewardBurned[msg.sender][tokenAddress][round][request.actionId];
        uint256 unusedQuota = quota - burned;
        if (request.amount > unusedQuota) {
            revert BurnQuotaExceeded(unusedQuota, request.amount);
        }
        _actionRewardBurned[msg.sender][tokenAddress][round][request.actionId] = burned + request.amount;

        uint256 multiplier = _scoreMultiplier(scoreBase_, round);
        uint256 operationScore =
            _recordBurnStats(msg.sender, tokenAddress, round, Category.ActionRewardBurn, request.amount, multiplier);
        IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), request.amount);
        ILOVE20Token(tokenAddress).burn(request.amount);
        _emitActionRewardBurned(request, round, extensionAddress, multiplier, operationScore);
    }

    function _accountTokenShare(address account, address tokenAddress, uint256 activeWeight, bool finalized)
        internal
        view
        returns (TokenShare memory share)
    {
        share.finalized = finalized;
        BurnStatsHistory storage communityHistory = _communityBurnStatsHistory[tokenAddress];
        uint256 communitySLScore = _latestCategoryScore(communityHistory.slTokenLock);
        uint256 communitySTScore = _latestCategoryScore(communityHistory.stTokenLock);
        uint256 communityGovScore = _latestCategoryScore(communityHistory.govRewardBurn);
        uint256 communityActionScore = _latestCategoryScore(communityHistory.actionRewardBurn);
        uint256 activeCategoryWeight =
            _activeCategoryWeight(communitySLScore, communitySTScore, communityGovScore, communityActionScore);
        if (activeWeight == 0 || activeCategoryWeight == 0) return share;

        uint256 communityShare = Math.mulDiv(_communityWeight[tokenAddress], WAD, activeWeight);
        BurnStatsHistory storage accountHistory = _accountBurnStatsHistory[account][tokenAddress];
        share.slTokenLock = _weightedScoreShare(
            communityShare,
            slTokenLockWeight,
            activeCategoryWeight,
            _latestCategoryScore(accountHistory.slTokenLock),
            communitySLScore
        );
        share.stTokenLock = _weightedScoreShare(
            communityShare,
            stTokenLockWeight,
            activeCategoryWeight,
            _latestCategoryScore(accountHistory.stTokenLock),
            communitySTScore
        );
        share.govRewardBurn = _weightedScoreShare(
            communityShare,
            govRewardBurnWeight,
            activeCategoryWeight,
            _latestCategoryScore(accountHistory.govRewardBurn),
            communityGovScore
        );
        share.actionRewardBurn = _weightedScoreShare(
            communityShare,
            actionRewardBurnWeight,
            activeCategoryWeight,
            _latestCategoryScore(accountHistory.actionRewardBurn),
            communityActionScore
        );
        share.total = share.slTokenLock + share.stTokenLock + share.govRewardBurn + share.actionRewardBurn;
    }

    function _activeCommunityWeight() internal view returns (uint256 weight) {
        uint256 length = _communities.length;
        for (uint256 i; i < length;) {
            address tokenAddress = _communities[i];
            BurnStatsHistory storage history = _communityBurnStatsHistory[tokenAddress];
            if (
                _activeCategoryWeight(
                    _latestCategoryScore(history.slTokenLock),
                    _latestCategoryScore(history.stTokenLock),
                    _latestCategoryScore(history.govRewardBurn),
                    _latestCategoryScore(history.actionRewardBurn)
                ) > 0
            ) {
                weight += _communityWeight[tokenAddress];
            }
            unchecked {
                ++i;
            }
        }
    }

    function _activeCategoryWeight(uint256 slScore, uint256 stScore, uint256 govScore, uint256 actionScore)
        internal
        view
        returns (uint256 weight)
    {
        if (slScore > 0) weight += slTokenLockWeight;
        if (stScore > 0) weight += stTokenLockWeight;
        if (govScore > 0) weight += govRewardBurnWeight;
        if (actionScore > 0) weight += actionRewardBurnWeight;
    }

    function _weightedScoreShare(
        uint256 communityShare,
        uint256 categoryWeight,
        uint256 activeCategoryWeight,
        uint256 accountScore,
        uint256 communityScore
    ) internal pure returns (uint256) {
        if (accountScore == 0 || communityScore == 0) return 0;
        uint256 categoryShare = Math.mulDiv(communityShare, categoryWeight, activeCategoryWeight);
        return Math.mulDiv(categoryShare, accountScore, communityScore);
    }

    function _isFinalized() internal view returns (bool) {
        uint256 currentVoteRound = _vote.currentRound();
        return currentVoteRound > 2 && currentVoteRound - 3 > endRound;
    }

    function _actionRewardBurnState(address account, address tokenAddress, uint256 round, uint256 actionId)
        internal
        view
        returns (ActionRewardBurnState memory state, bool supported)
    {
        state.actionId = actionId;
        state.extensionAddress = _center.extension(tokenAddress, actionId);
        if (state.extensionAddress != address(0)) {
            address factory = _center.factory(tokenAddress, actionId);
            if (!_isSupportedExtensionFactory[factory]) return (state, false);
            (uint256 mintReward,, bool claimed) = IReward(state.extensionAddress).rewardByAccount(round, account);
            state.reward.burnedAmount = _actionRewardBurned[account][tokenAddress][round][actionId];
            if (!claimed) {
                state.reward.claimableRewardAmount = mintReward;
                return (state, true);
            }
            state.reward.isClaimed = true;
            state.reward.claimedRewardAmount = mintReward;
            state.reward.burnQuotaAmount = mintReward * quotaMultiplier;
            state.reward.unusedQuotaAmount = state.reward.burnQuotaAmount - state.reward.burnedAmount;
            return (state, true);
        }

        uint256 actualMintedReward = _mint.actionRewardMintedByAccount(tokenAddress, round, actionId, account);
        state.reward.burnedAmount = _actionRewardBurned[account][tokenAddress][round][actionId];
        if (actualMintedReward == 0) {
            (uint256 expectedReward,) = _mint.actionRewardByActionIdByAccount(tokenAddress, round, actionId, account);
            state.reward.claimableRewardAmount = expectedReward;
            return (state, true);
        }
        state.reward.isClaimed = true;
        state.reward.claimedRewardAmount = actualMintedReward;
        state.reward.burnQuotaAmount = actualMintedReward * quotaMultiplier;
        state.reward.unusedQuotaAmount = state.reward.burnQuotaAmount - state.reward.burnedAmount;
        return (state, true);
    }

    function _emitActionRewardBurned(
        ActionRewardBurnRequest calldata request,
        uint256 round,
        address extensionAddress,
        uint256 multiplier,
        uint256 operationScore
    ) internal {
        CategoryStats memory accountTotal =
            _latestCategoryStats(_accountBurnStatsHistory[msg.sender][request.tokenAddress].actionRewardBurn);
        CategoryStats memory communityTotal =
            _latestCategoryStats(_communityBurnStatsHistory[request.tokenAddress].actionRewardBurn);
        emit ActionRewardTokenBurned(
            request.tokenAddress,
            msg.sender,
            round,
            request.actionId,
            extensionAddress,
            request.amount,
            multiplier,
            operationScore,
            accountTotal.amount,
            accountTotal.score,
            communityTotal.amount,
            communityTotal.score
        );
    }

    function _recordBurnStats(
        address account,
        address tokenAddress,
        uint256 round,
        Category category,
        uint256 amount,
        uint256 multiplier
    ) internal returns (uint256 operationScore) {
        CategoryStatsHistory storage accountHistory =
            _categoryHistory(_accountBurnStatsHistory[account][tokenAddress], category);
        uint256 oldRoundAmount = _latestRoundAmount(accountHistory, round);
        uint256 newRoundAmount = oldRoundAmount + amount;
        uint256 newRoundScore = Math.mulDiv(newRoundAmount, multiplier, WAD);
        operationScore = newRoundScore - Math.mulDiv(oldRoundAmount, multiplier, WAD);

        _recordCategoryStats(accountHistory, round, amount, operationScore);
        _recordCategoryStats(
            _categoryHistory(_communityBurnStatsHistory[tokenAddress], category), round, amount, operationScore
        );
    }

    function _recordCategoryStats(CategoryStatsHistory storage history, uint256 round, uint256 amount, uint256 score)
        internal
    {
        uint256 length = history.changeRounds.length;
        CategoryStats storage checkpoint = history.statsByRound[round];
        if (length == 0 || round > history.changeRounds[length - 1]) {
            if (length > 0) {
                CategoryStats storage previous = history.statsByRound[history.changeRounds[length - 1]];
                checkpoint.amount = previous.amount;
                checkpoint.score = previous.score;
            }
            history.changeRounds.push(round);
        } else {
            assert(round == history.changeRounds[length - 1]);
        }
        checkpoint.amount += amount;
        checkpoint.score += score;
    }

    function _burnStatsThroughRound(BurnStatsHistory storage history, uint256 round)
        internal
        view
        returns (BurnStats memory stats)
    {
        stats.slTokenLock = _categoryStatsThroughRound(history.slTokenLock, round);
        stats.stTokenLock = _categoryStatsThroughRound(history.stTokenLock, round);
        stats.govRewardBurn = _categoryStatsThroughRound(history.govRewardBurn, round);
        stats.actionRewardBurn = _categoryStatsThroughRound(history.actionRewardBurn, round);
    }

    function _burnStatsAtRound(BurnStatsHistory storage history, uint256 round)
        internal
        view
        returns (BurnStats memory stats)
    {
        stats = _burnStatsThroughRound(history, round);
        if (round > 0) stats = _subtractBurnStats(stats, _burnStatsThroughRound(history, round - 1));
    }

    function _latestBurnStats(BurnStatsHistory storage history) internal view returns (BurnStats memory stats) {
        stats.slTokenLock = _latestCategoryStats(history.slTokenLock);
        stats.stTokenLock = _latestCategoryStats(history.stTokenLock);
        stats.govRewardBurn = _latestCategoryStats(history.govRewardBurn);
        stats.actionRewardBurn = _latestCategoryStats(history.actionRewardBurn);
    }

    function _latestCategoryStats(CategoryStatsHistory storage history) internal view returns (CategoryStats memory) {
        uint256 length = history.changeRounds.length;
        return length == 0 ? CategoryStats(0, 0) : history.statsByRound[history.changeRounds[length - 1]];
    }

    function _latestCategoryScore(CategoryStatsHistory storage history) internal view returns (uint256) {
        uint256 length = history.changeRounds.length;
        return length == 0 ? 0 : history.statsByRound[history.changeRounds[length - 1]].score;
    }

    function _categoryStatsThroughRound(CategoryStatsHistory storage history, uint256 round)
        internal
        view
        returns (CategoryStats memory)
    {
        (bool found, uint256 checkpointRound) = history.changeRounds.findLeftNearestOrEqualValue(round);
        return found ? history.statsByRound[checkpointRound] : CategoryStats(0, 0);
    }

    function _categoryStatsAtRound(CategoryStatsHistory storage history, uint256 round)
        internal
        view
        returns (CategoryStats memory stats)
    {
        stats = _categoryStatsThroughRound(history, round);
        if (round > 0) {
            CategoryStats memory previous = _categoryStatsThroughRound(history, round - 1);
            stats.amount -= previous.amount;
            stats.score -= previous.score;
        }
    }

    function _latestRoundAmount(CategoryStatsHistory storage history, uint256 round)
        internal
        view
        returns (uint256 amount)
    {
        uint256 length = history.changeRounds.length;
        if (length == 0 || history.changeRounds[length - 1] != round) return 0;
        amount = history.statsByRound[round].amount;
        if (length > 1) amount -= history.statsByRound[history.changeRounds[length - 2]].amount;
    }

    function _subtractBurnStats(BurnStats memory value, BurnStats memory previous)
        internal
        pure
        returns (BurnStats memory)
    {
        value.slTokenLock.amount -= previous.slTokenLock.amount;
        value.slTokenLock.score -= previous.slTokenLock.score;
        value.stTokenLock.amount -= previous.stTokenLock.amount;
        value.stTokenLock.score -= previous.stTokenLock.score;
        value.govRewardBurn.amount -= previous.govRewardBurn.amount;
        value.govRewardBurn.score -= previous.govRewardBurn.score;
        value.actionRewardBurn.amount -= previous.actionRewardBurn.amount;
        value.actionRewardBurn.score -= previous.actionRewardBurn.score;
        return value;
    }

    function _categoryHistory(BurnStatsHistory storage stats, Category category)
        internal
        view
        returns (CategoryStatsHistory storage value)
    {
        if (category == Category.SLTokenLock) return stats.slTokenLock;
        if (category == Category.STTokenLock) return stats.stTokenLock;
        if (category == Category.GovRewardBurn) return stats.govRewardBurn;
        return stats.actionRewardBurn;
    }

    function _validateOperation(address tokenAddress, uint256 round, uint256 amount, uint256 categoryWeight)
        internal
        view
        returns (uint256 multiplier)
    {
        uint256 scoreBase_ = _requireCommunity(tokenAddress);
        if (categoryWeight == 0) revert CategoryDisabled();
        if (amount == 0) revert ZeroAmount();
        _requireOpenRound(round);
        return _scoreMultiplier(scoreBase_, round);
    }

    function _requireOpenRound(uint256 round) internal view {
        uint256 currentVoteRound = _vote.currentRound();
        uint256 currentBurnRound = currentVoteRound > 2 ? currentVoteRound - 3 : 0;
        if (currentVoteRound <= 2 || !_isRoundOpen(round, currentBurnRound)) {
            revert RoundNotOpen(round, currentBurnRound);
        }
    }

    function _isRoundOpen(uint256 round, uint256 currentBurnRound) internal view returns (bool) {
        return round >= startRound && round <= endRound && round == currentBurnRound;
    }

    function _scoreMultiplier(uint256 scoreBase_, uint256 round) internal view returns (uint256) {
        if (round < startRound || round > endRound) return 0;
        return _powWad(scoreBase_, endRound - round);
    }

    function _addParticipant(address account) internal {
        if (_isParticipant[account]) return;
        _isParticipant[account] = true;
        _participants.push(account);
    }

    function _powWad(uint256 base, uint256 exponent) internal pure returns (uint256 result) {
        result = WAD;
        while (exponent > 0) {
            if (exponent & 1 != 0) {
                result = Math.mulDiv(result, base, WAD);
            }
            exponent >>= 1;
            if (exponent > 0) {
                base = Math.mulDiv(base, base, WAD);
            }
        }
    }

    function _requireCommunity(address tokenAddress) internal view returns (uint256 scoreBase_) {
        scoreBase_ = _scoreBase[tokenAddress];
        if (scoreBase_ == 0) revert UnsupportedCommunity(tokenAddress);
    }

    function _isEndedLOVE20Token(ILOVE20Launch launch, address tokenAddress) internal view returns (bool) {
        return launch.isLOVE20Token(tokenAddress) && launch.launchInfo(tokenAddress).hasEnded;
    }
}
