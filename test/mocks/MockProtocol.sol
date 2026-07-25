// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {LaunchInfo} from "@core/interfaces/ILOVE20Launch.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

interface IAirdropClaim {
    function claimAirdrop() external returns (uint256 amount);
}

contract MockReentrantAirdropToken is MockERC20 {
    address public burn;
    bool public reenter;

    constructor() MockERC20("Reentrant Airdrop", "RAIR") {}

    function setBurn(address burn_) external {
        burn = burn_;
    }

    function setReenter(bool reenter_) external {
        reenter = reenter_;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        super._transfer(from, to, amount);
        if (reenter && from == burn) IAirdropClaim(burn).claimAirdrop();
    }
}

contract MockFailingAirdropToken is MockERC20 {
    bool public failTransfers;

    constructor() MockERC20("Failing Airdrop", "FAIL") {}

    function setFailTransfers(bool failTransfers_) external {
        failTransfers = failTransfers_;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        require(!failTransfers, "airdrop transfer failed");
        super._transfer(from, to, amount);
    }
}

contract MockUnreadableAirdropToken {
    fallback() external {
        revert("unreadable airdrop");
    }
}

contract MockLOVE20Token is ERC20 {
    uint256 public immutable maxSupply;
    address public parentTokenAddress;
    address public slAddress;
    address public stAddress;

    constructor(
        string memory symbol_,
        uint256 initialSupply,
        uint256 maxSupply_,
        address parentTokenAddress_,
        address slAddress_,
        address stAddress_
    ) ERC20(symbol_, symbol_) {
        maxSupply = maxSupply_;
        parentTokenAddress = parentTokenAddress_;
        slAddress = slAddress_;
        stAddress = stAddress_;
        _mint(msg.sender, initialSupply);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

contract MockLaunch {
    mapping(address => bool) public isLOVE20Token;
    mapping(address => LaunchInfo) internal _launchInfo;

    function setToken(address token, address parent, bool hasEnded) external {
        isLOVE20Token[token] = true;
        _launchInfo[token].parentTokenAddress = parent;
        _launchInfo[token].hasEnded = hasEnded;
    }

    function launchInfo(address token) external view returns (LaunchInfo memory) {
        return _launchInfo[token];
    }
}

contract MockVerify {
    uint256 public currentRound;

    function setCurrentRound(uint256 round) external {
        currentRound = round;
    }
}

contract MockVote {
    mapping(address => mapping(uint256 => uint256[])) internal _actionIds;

    function setVotedActionId(address tokenAddress, uint256 round, uint256 actionId) external {
        _actionIds[tokenAddress][round].push(actionId);
    }

    function votedActionIdsCount(address tokenAddress, uint256 round) external view returns (uint256) {
        return _actionIds[tokenAddress][round].length;
    }

    function votedActionIdsAtIndex(address tokenAddress, uint256 round, uint256 index)
        external
        view
        returns (uint256)
    {
        return _actionIds[tokenAddress][round][index];
    }
}

contract MockMint {
    uint256 public ROUND_REWARD_GOV_PER_THOUSAND = 1;
    uint256 public ROUND_REWARD_ACTION_PER_THOUSAND = 1;

    struct GovRewardData {
        uint256 verifyReward;
        uint256 boostReward;
        uint256 burnReward;
        bool isMinted;
    }

    mapping(address => mapping(uint256 => mapping(address => GovRewardData))) internal _govReward;
    mapping(address => mapping(uint256 => mapping(address => uint256))) public govRewardMintedByAccount;
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(address => uint256)))) public
        actionRewardMintedByAccount;
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(address => uint256)))) internal _actionReward;

    function setGovReward(
        address tokenAddress,
        uint256 round,
        address account,
        uint256 verifyReward,
        uint256 boostReward,
        uint256 burnReward,
        bool isMinted
    ) external {
        _govReward[tokenAddress][round][account] = GovRewardData(verifyReward, boostReward, burnReward, isMinted);
        govRewardMintedByAccount[tokenAddress][round][account] = isMinted ? verifyReward + boostReward : 0;
    }

    function govRewardByAccount(address tokenAddress, uint256 round, address account)
        external
        view
        returns (uint256 verifyReward, uint256 boostReward, uint256 burnReward, bool isMinted)
    {
        GovRewardData memory data = _govReward[tokenAddress][round][account];
        return (data.verifyReward, data.boostReward, data.burnReward, data.isMinted);
    }

    function setActionReward(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        address account,
        uint256 reward,
        bool isMinted
    ) external {
        _actionReward[tokenAddress][round][actionId][account] = reward;
        actionRewardMintedByAccount[tokenAddress][round][actionId][account] = isMinted ? reward : 0;
    }

    function actionRewardByActionIdByAccount(address tokenAddress, uint256 round, uint256 actionId, address account)
        external
        view
        returns (uint256 reward, bool isMinted)
    {
        reward = _actionReward[tokenAddress][round][actionId][account];
        isMinted = actionRewardMintedByAccount[tokenAddress][round][actionId][account] > 0;
    }
}

contract MockExtensionCenter {
    address public launchAddress;
    address public stakeAddress;
    address public voteAddress;
    address public verifyAddress;
    address public mintAddress;
    mapping(address => mapping(uint256 => address)) public extension;
    mapping(address => mapping(uint256 => address)) public factory;

    constructor(address launch_, address vote_, address verify_, address mint_) {
        launchAddress = launch_;
        voteAddress = vote_;
        verifyAddress = verify_;
        mintAddress = mint_;
        stakeAddress = address(1);
    }

    function setExtension(address tokenAddress, uint256 actionId, address extensionAddress, address factoryAddress)
        external
    {
        extension[tokenAddress][actionId] = extensionAddress;
        factory[tokenAddress][actionId] = factoryAddress;
    }
}

contract MockExtensionFactory {}

contract MockReward {
    struct RewardData {
        uint256 mintReward;
        uint256 burnReward;
        bool claimed;
    }

    mapping(uint256 => mapping(address => RewardData)) internal _reward;

    function setReward(uint256 round, address account, uint256 mintReward, uint256 burnReward, bool claimed) external {
        _reward[round][account] = RewardData(mintReward, burnReward, claimed);
    }

    function rewardByAccount(uint256 round, address account) external view returns (uint256, uint256, bool) {
        RewardData memory data = _reward[round][account];
        return (data.mintReward, data.burnReward, data.claimed);
    }
}

contract MockRevertingReward {
    function rewardByAccount(uint256, address) external pure returns (uint256, uint256, bool) {
        revert("unsupported reward called");
    }
}
