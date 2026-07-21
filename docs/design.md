# LOVE20 生态销毁获 BSC 空投份额合约设计

状态：已确认，待实现。

本合约以下简称 `Burn`。它在 TKM 链永久锁定 LOVE20 生态的 SL/ST 凭证、真实销毁治理与行动奖励代币，并计算各地址获得 BSC 空投池的份额。Burn 不跨链、不持有 BSC 资产，也不计算具体空投代币数量。

领域术语以 [CONTEXT.md](../CONTEXT.md) 为准，关键取舍见 [ADR](./adr/)。

## 1. 目标与边界

Burn 必须做到：

- LOVE20 根币及部署时已经完成发射的直接子币可以参与。
- 四类资产分别竞争份额，并在无人参与时重新分配空池。
- 可销毁奖励额度绑定地址当轮实际领取的激励。
- 提前参与通过得分系数获得更高得分。
- 所有份额、累计值和历史都可被前端及链下空投程序核验。
- 合约不可升级、无 owner、无管理员配置、无资产救援入口。

Burn 明确不做：

- 不支持部署后的新社区、孙币或更深层代币。
- 不支持 beneficiary、代销毁、额度转让或单独 BSC 接收地址。
- 不处理 BSC 空投资金和跨链消息。
- 不保存逐笔历史数组，不在链上保存具体空投数量。
- 不设置最低销毁量、最低参与率或类别激活截止。

## 2. 构造与协议依赖

```solidity
constructor(
    address extensionCenterAddress,
    uint256 startRound,
    uint256 roundCount,
    uint256 quotaMultiplier,
    address[] memory supportedExtensionFactories
)
```

构造参数规则：

- `extensionCenterAddress` 不得为零地址。
- `roundCount > 0`。
- `quotaMultiplier > 0`，使用整数，例如 `5` 表示五倍。
- `startRound >= LOVE20Verify.currentRound()`。
- `endRound = startRound + roundCount - 1`，溢出则部署回滚。
- Factory 不得为零地址或重复；空数组合法，表示仅支持基础 Mint 行动。

ExtensionCenter 是唯一协议地址入口。Burn 从其不可变 getter 获取 Launch、Stake、Vote、Verify、Mint 和 Uniswap V2 Factory 等地址，不再接受这些地址的独立配置。实现可以缓存频繁使用的派生地址为 immutable，但不能形成第二套可配置来源。

以下配置通过 `public immutable` 或只读数组公开：

```solidity
extensionCenter()
startRound()
roundCount()
endRound()
quotaMultiplier()
supportedExtensionFactories()
isSupportedExtensionFactory(factory)
```

## 3. 参与社区与社区权重

### 3.1 社区发现

部署时按以下顺序发现社区：

1. `LOVE20Launch.tokensAtIndex(0)` 是 LOVE20 根币。
2. 根币必须已经完成公平发射。
3. 通过 `launchedChildTokensCount/AtIndex(LOVE20)` 枚举已经完成发射的直接子币。
4. 分别计算根币及直接子币的社区权重和得分系数基准。
5. 只保留权重大于零的社区并冻结列表。
6. 若没有任何正权重社区，部署回滚 `NoParticipatingCommunities()`。

部署后的新币、孙币、更深层代币和零权重社区不参与。

### 3.2 权重公式

每个社区的 SL 合约对应一个 Uniswap V2 Pair：

```text
weight = floor(
    love20Reserve * pair.balanceOf(slTokenAddress) / pair.totalSupply()
)
```

- 根币社区取 LOVE20/TKM Pair 的 LOVE20 储备，即 SL Pair 的社区代币侧储备。
- 直接子币社区取子币/LOVE20 Pair 的 LOVE20 储备，即 SL Pair 的父币侧储备。
- 使用 SL 合约实际持有的全部 LP，包括可提取 LP、协议手续费对应 LP 和直接转入 LP，不单独拆分。
- ST 中锁定的社区代币或 LOVE20 不计入社区权重；ST 只参与加速质押凭证锁定类别的销毁竞争。
- Pair 总 LP、SL 的 LP 余额或 LOVE20 储备任一为零时，该社区权重为零并被排除，不执行除零运算。
- 权重只在部署时计算一次，之后不随池子变化。

只读接口：

```solidity
communities() returns (address[] memory)
communityWeight(address tokenAddress) returns (uint256)
communityBase(address tokenAddress) returns (uint256)
totalCommunityWeight() returns (uint256)
```

`communityWeight(tokenAddress) == 0` 和 `communityBase(tokenAddress) == 0` 表示非参与社区。其他需要社区语义的详细查询和全部写入口遇到非参与社区时回滚 `UnsupportedCommunity(tokenAddress)`。

## 4. 销毁周期

Burn 轮次等于 LOVE20Mint 奖励轮次。奖励轮次 `R` 仅在：

```text
LOVE20Verify.currentRound() == R + 1
```

时开放。因此当前奖励轮次为：

```text
Verify.currentRound() == 0 时：round = 0，open = false
否则：round = Verify.currentRound() - 1
```

开放条件：

```text
open = startRound <= round <= endRound
       且 Verify.currentRound() > 0
       且 round == Verify.currentRound() - 1
```

历史轮次不能补销毁，未使用额度跨轮失效。份额最终确定条件为：

```text
finalized = LOVE20Verify.currentRound() > endRound + 1
```

`Verify.currentRound() == endRound + 1` 正是最后一个轮次的销毁开放窗口；Verify 再推进一次至 `endRound + 2` 时，份额立即最终确定。

不需要 `finalize()` 交易或结算事件。Verify 已进入正数轮次时，前端可默认选择 `Verify.currentRound() - 1`；Verify 仍为第 0 轮时默认选择 0。所有按轮次查询和全部写入口都显式传入 `round`；配置、全周期累计和份额查询不带轮次。

## 5. 销毁类别与份额

四个类别的基础权重相同：

| 类别 | 资产处理 | 基础份额 |
| --- | --- | ---: |
| `SLTokenLock` | 永久锁定流动性质押凭证 | 25% |
| `STTokenLock` | 永久锁定加速质押凭证 | 25% |
| `GovRewardBurn` | 真实销毁治理奖励代币 | 25% |
| `ActionRewardBurn` | 真实销毁行动奖励代币 | 25% |

类别在整个销毁周期内的社区总得分大于零时为活跃类别。社区至少有一个活跃类别时为活跃社区。

### 5.1 社区重新归一化

全局只在活跃社区之间按冻结权重分配：

```text
activeCommunityWeight = 所有活跃社区的冻结权重之和

communityShare = floor(
    communityWeight * 1e18 / activeCommunityWeight
)
```

四类均无得分的社区退出分配。若全局没有活跃社区，所有地址份额为零，链下程序不生成个人空投。

### 5.2 类别重新归一化

因为四类基础权重相同，社区份额在活跃类别之间等分：

```text
categoryShare = floor(communityShare / activeCategoryCount)
```

四、三、二、一个活跃类别时，各活跃类别分别得到社区份额的 `1/4`、`1/3`、`1/2`、全部。

### 5.3 地址份额

地址在某社区、某类别的全局份额贡献为：

```text
accountCategoryShare = floor(
    categoryShare * accountCategoryScore / communityCategoryScore
)
```

`accountTokenShare.total` 是该社区四个类别贡献的和；`accountShare` 是所有参与社区贡献的和。所有阶段均向下取整，余量不分配。

## 6. 得分系数与销毁得分

全部定点数使用 `1e18` 精度。

每个参与社区在 Burn 部署时按当时状态计算并冻结 `base`：

```text
rewardRatePerThousand = LOVE20Mint.ROUND_REWARD_GOV_PER_THOUSAND()
                      + LOVE20Mint.ROUND_REWARD_ACTION_PER_THOUSAND()

deploymentRoundReward = floor(
    (token.maxSupply() - token.totalSupply())
    * rewardRatePerThousand / 1000
)

base = 1e18 + floor(
    deploymentRoundReward * 1e18 / token.totalSupply()
)
scoreMultiplier(R) = powWad(base, endRound - R)
```

规则：

- `deploymentRoundReward` 使用未铸造空间和 Mint 的实际奖励比例，不读取 `rewardAvailable`，因此不受当轮奖励是否已经 prepare 或 reserved 影响。
- `base` 和部署时的奖励、供应量只取一次，之后不随领取、原生销毁或协议预留变化。
- 指数只包含当前轮之后的未来销毁轮次。
- 最后一轮 `endRound - R == 0`，系数为 `1e18`。
- `powWad` 使用内部平方求幂，复杂度 O(log n)，每次 `Math.mulDiv` 向下取整。
- 只对正权重社区计算 `base`；正权重社区若 `totalSupply == 0`，部署回滚 `InvalidCommunityBase(token)`。
- 同社区所有销毁轮次和四类操作使用同一部署时 `base`。

地址在同一社区、轮次、类别内分次操作时，按累计值差额计分：

```text
oldScore = floor(oldRoundAmount * scoreMultiplier / 1e18)
newScore = floor(newRoundAmount * scoreMultiplier / 1e18)
operationScore = newScore - oldScore
```

因此同轮 `30 + 70` 与一次操作 `100` 的最终得分完全相同。

查询：

```solidity
scoreMultiplier(address tokenAddress, uint256 round)
    returns (uint256 multiplier)
```

- 销毁周期内的轮次直接按部署时 `base` 计算，查询不写状态。
- `round < startRound` 或 `round > endRound` 时返回零；非参与社区回滚 `UnsupportedCommunity`。

## 7. 资产处理与额度

### 7.1 SL/ST 凭证永久锁定

- Burn 从 `msg.sender` 收取指定社区的 SL 或 ST 凭证并永久持有。
- 合约允许任意正数和同轮、跨轮重复锁定。
- 部署后新产生或新转入的合法凭证也可以参与。
- 标准前端默认提交调用时全部余额，不提供减少数量的交互。
- 直接向 Burn 转入凭证不产生得分、不加入参与地址列表，也不能取回。
- 锁定可能使原地址 `validGovVotes()` 归零，且正常退出原质押可能要求重新获得缺失凭证；这是已接受结果。

### 7.2 治理奖励代币销毁

治理奖励的实际领取量直接读取：

```text
LOVE20Mint.govRewardMintedByAccount(token, round, account)
```

该值只包含实际发给地址的 `verifyReward + boostReward`，不包含协议 `burnReward`。

```text
quota = actualMintedReward * quotaMultiplier
remaining = quota - burnedInThisRound
```

地址可在同轮分多次销毁，但累计不能超过额度。用于销毁的社区代币可以来自原有余额或市场购买，不追踪代币来源。

Burn 先从 `msg.sender` 收取社区代币，再调用该 LOVE20Token 的原生 `burn()`。这会降低 `totalSupply`，并使销毁数量重新进入未来可铸空间。

### 7.3 行动奖励来源

行动奖励按 `token + round + actionId + account` 独立核销额度。基础与扩展来源互斥：

1. `ExtensionCenter.extension(token, actionId) == address(0)`：只读取 LOVE20Mint 基础行动奖励。
2. 扩展地址非零：只读取该扩展的 `rewardByAccount(round, account)`。
3. 扩展的 Factory 必须在部署时冻结的受支持 Factory 列表内；否则状态查询跳过，写入回滚。
4. 扩展奖励只使用已领取记录中的 `mintReward`，不使用扩展的 `burnReward`；该笔额度整体归属于发起领取的地址（claimant），扩展内部向 recipients 的二次分配不再拆分 Burn 额度。
5. 销毁周期内由受支持 Factory 新建并登记的扩展行动可以参与。

基础行动的实际领取量读取 `actionRewardMintedByAccount`；扩展行动以 `rewardByAccount` 返回的 `claimed` 和已经保存的 `mintReward` 为准。未领取奖励只展示，额度和剩余额度均为零。

### 7.4 行动批量销毁

仅行动奖励提供批量入口。批次可以混合多个社区和 actionId，采用全有或全无语义。

- 每项数量必须大于零。
- 任意项失败，整个批次回滚。
- 同一 `token + actionId` 可以重复出现并按顺序累计。
- 重复项的总效果与合并数量相同，累计额度仍严格限制总量。
- 不设置人为批次长度上限，交易 gas 自然形成上限。

## 8. 写接口

```solidity
struct ActionRewardBurnRequest {
    address tokenAddress;
    uint256 actionId;
    uint256 amount;
}

function lockSLToken(
    address tokenAddress,
    uint256 round,
    uint256 amount
) external;

function lockSTToken(
    address tokenAddress,
    uint256 round,
    uint256 amount
) external;

function burnGovRewardToken(
    address tokenAddress,
    uint256 round,
    uint256 amount
) external;

function burnActionRewardTokens(
    uint256 round,
    ActionRewardBurnRequest[] calldata requests
) external;
```

全部写入口：

- 只为 `msg.sender` 消耗额度并记分。
- 要求社区受支持、传入 `round` 当前开放、数量大于零；交易延迟到其他轮次执行时回滚，不按新轮次记账。
- 在资产永久转移成功后整笔交易才成立。
- 不接受原生币，不提供 permit、beneficiary 或接收地址参数。

## 9. 状态与累计查询

### 9.1 轮次开放状态

```solidity
function isRoundOpen(uint256 round) external view returns (bool);
```

仅当 `startRound <= round <= endRound`、`Verify.currentRound() > 0` 且 `round == Verify.currentRound() - 1` 时返回 `true`。实现先检查 Verify 为正数再做减法，使任意查询参数都不会因 `round + 1` 溢出。前端仍可查询历史轮次状态，但只有返回 `true` 时才启用锁定和销毁交易。

### 9.2 治理与行动奖励状态

```solidity
struct RewardBurnState {
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

function govRewardBurnState(
    address account,
    address tokenAddress,
    uint256 round
) external view returns (RewardBurnState memory);

function actionRewardBurnStates(
    address account,
    address tokenAddress,
    uint256 round
) external view returns (ActionRewardBurnState[] memory);
```

未领取时，`claimableRewardAmount` 表示理论可领取奖励，`claimedRewardAmount`、额度和已用量均为零。领取后，`claimableRewardAmount` 为零，`claimedRewardAmount` 表示实际归属于 claimant 的奖励；`burnQuotaAmount`、`burnedAmount` 和 `unusedQuotaAmount` 分别表示指定轮次的总额度、已销毁量和未使用额度，并满足 `burnedAmount + unusedQuotaAmount == burnQuotaAmount`。历史轮次的未使用额度只用于展示，不能继续销毁；前端必须结合 `isRoundOpen(round)` 决定是否允许操作。活动周期外，治理状态返回全零，行动状态返回空数组。

`actionRewardBurnStates` 遍历 LOVE20Vote 指定轮次的全局 `votedActionIds`，不能使用地址自己的投票列表，因为行动奖励领取者不一定是投票者。结果只保留奖励大于零或已有销毁记录的受支持行动；基础 Mint 行动的 `extensionAddress` 为零，非受支持 Factory 的行动不调用扩展并直接跳过。每个地址每轮最多提交一个行动；当 `SUBMIT_MIN_PER_THOUSAND > 0` 时，已提交行动理论上限不超过 `floor(1000 / SUBMIT_MIN_PER_THOUSAND)`，已投票行动只是其子集。活动周期外返回空数组，不分页，部署校验必须覆盖该上限下的 view gas。

### 9.3 轮次与全周期累计

```solidity
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

function accountRoundBurnStats(
    address account,
    address tokenAddress,
    uint256 round
) external view returns (BurnStats memory);

function accountBurnStats(
    address account,
    address tokenAddress
) external view returns (BurnStats memory);

function communityRoundBurnStats(
    address tokenAddress,
    uint256 round
) external view returns (BurnStats memory);

function communityBurnStats(
    address tokenAddress
) external view returns (BurnStats memory);
```

四类资产单位不同，不提供跨类别 `amount` 合计。

### 9.4 份额查询

```solidity
struct TokenShare {
    uint256 slTokenLock;
    uint256 stTokenLock;
    uint256 govRewardBurn;
    uint256 actionRewardBurn;
    uint256 total;
    bool finalized;
}

function accountTokenShare(
    address account,
    address tokenAddress
) external view returns (TokenShare memory);

function accountShare(
    address account
) external view returns (uint256 share, bool finalized);
```

四个类别字段已经包含社区权重、活跃类别权重和地址在类别内的得分比例；`total` 必须严格等于四项之和。销毁期间返回实时预览和 `finalized = false`，结束后同一接口返回最终值。

### 9.5 参与地址索引

```solidity
function participantsCount() external view returns (uint256);

function participants(
    uint256 offset,
    uint256 limit
) external view returns (address[] memory);

function isParticipant(address account) external view returns (bool);
```

地址第一次通过正式入口成功锁定或销毁时加入全局去重列表。`limit == 0` 或 `offset` 越界时返回空数组，末页自动截短；直接转账不加入列表。

## 10. 事件

```solidity
event CommunityConfigFrozen(
    address indexed tokenAddress,
    uint256 weight,
    uint256 base,
    uint256 totalSupply,
    uint256 deploymentRoundReward
);

event SupportedExtensionFactoryFrozen(
    address indexed factory
);

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
```

四种操作事件中的累计数量和得分都是地址或社区在该类别内的全周期累计值。事件不记录份额，因为其他人的后续操作仍会改变份额。

## 11. 错误

建议使用以下最小自定义错误集合：

```solidity
error ZeroAddress();
error ZeroAmount();
error EmptyBatch();
error InvalidRoundCount();
error InvalidQuotaMultiplier();
error StartRoundTooEarly(
    uint256 currentVerifyRound,
    uint256 startRound
);
error DuplicateExtensionFactory(address factory);
error NoParticipatingCommunities();
error InvalidCommunityBase(address tokenAddress);
error UnsupportedCommunity(address tokenAddress);
error RoundNotOpen(uint256 round, uint256 currentVerifyRound);
error NoClaimedReward();
error BurnQuotaExceeded(uint256 unusedQuotaAmount, uint256 requestedAmount);
error UnsupportedExtensionFactory(address factory);
```

不存在的 actionId、无奖励行动或未领取行动都没有已领取奖励额度，统一表现为 `NoClaimedReward()`，不增加同义错误。ERC20 转账失败由 `SafeERC20` 原样回滚。

## 12. 安全约束

- 使用 `SafeERC20.safeTransferFrom` 收取代币和凭证。
- 写入口先完成所有资格、轮次、额度和来源检查，再更新累计状态并执行资产转移；任一外部调用失败时整笔交易回滚。
- 不使用 `ReentrancyGuard`：参与社区代币及其 SL/ST 均由本次 ExtensionCenter 对应 Launch 的 LOVE20TokenFactory 创建，采用未覆盖外部转账 hook 的固定 ERC20 实现；原生 burn 不执行外部调用，扩展 `rewardByAccount` 通过 `STATICCALL` 调用，无法重入 Burn 写入口。
- 受支持扩展的信任边界是部署时冻结的 Factory，不能调用非受支持扩展读取奖励。
- 所有乘除使用 `Math.mulDiv`，全部向下取整；溢出回滚，不使用饱和值。
- 没有 owner、升级入口、提取入口、救援入口、receive 或 payable 写入口。
- 直接或强制转入的任何资产不记分且不可取回。

## 13. 部署与发布校验

部署前：

1. 确认 ExtensionCenter 及其 Launch、Vote、Verify、Mint 等不可变地址正确。
2. 观察 LOVE20 根币和全部直接子币的 SL Pair，排除储备、LP 余额或价格异常。
3. 独立计算每个社区的预期 LOVE20 权重、`base` 和允许偏差。
4. 核对 `startRound`、`roundCount`、派生 `endRound` 和整数 `quotaMultiplier`。
5. 核对所有受支持 Factory 的地址、代码和奖励接口。
6. 在目标链 fork 上模拟部署、最坏批量销毁和主要聚合 view，确认不超过目标链 gas 限制。

部署后、公布地址前：

1. 核对周期及倍数 getter。
2. 核对 `communities()`、每个社区权重、`base` 和总权重。
3. 核对完整 Factory 数组和成员判断。
4. 核对 `CommunityConfigFrozen` 与 `SupportedExtensionFactoryFrozen` 日志，以及每个社区的 `base`。
5. 独立基准超出偏差、名单不完整、参数不符合本次发布计划、gas 超限或任何依赖不匹配时，视为部署失败，不公布地址。
6. 验证合约源码，并在前端和链下空投程序中只登记通过验收的地址。

部署校验脚本必须 fail-closed：任何检查失败都累计失败数并以非零状态退出，不能只打印告警后继续返回成功。

## 14. 前端与空投准备

- 前端以选中的 `round` 为统一参数，通过批量读取同时调用 `isRoundOpen`、`scoreMultiplier`、`govRewardBurnState`、`accountRoundBurnStats` 和 `accountBurnStats`。
- 社区代币、SL、ST 的钱包余额和对 Burn 的 allowance 直接调用各 ERC20 的 `balanceOf/allowance`，Burn 不代理标准代币查询。SL/ST 标准交互默认提交当前全部余额，不提供减少数量控件；合约接口仍允许任意正数。
- 行动区域按需调用 `actionRewardBurnStates(account, token, round)`，用返回值构建批量销毁参数；该动态查询失败时不应阻塞 SL、ST 和治理区域。
- `accountRoundBurnStats` 展示指定轮次四类已锁定或销毁数量与得分，`accountBurnStats` 展示全周期累计；历史页面另按地址、社区和轮次查询四种事件。
- 所有写交易携带页面选中的 `round`；发送前仍由 Burn 校验该轮是否开放，避免跨轮延迟交易按新轮次执行。
- 空投准备程序分页读取参与地址，并要求 `accountShare(account).finalized == true`。
- BSC 具体数量由链下程序按 `airdropPool * share / 1e18` 计算并向下取整。
- TKM 调用地址与 BSC 接收地址相同。合约地址能否在 BSC 接收或控制由链下程序判断，Burn 不处理。

## 15. 最小验收测试

实现至少覆盖：

1. 从 ExtensionCenter 和 Launch 自动发现根币、直接子币，正确排除未来币、孙币和零权重社区。
2. 权重只按 SL 实际 LP 余额计算，并包含手续费及直接转入 LP；ST 资产不计入权重。
3. `isRoundOpen(round)` 在开始前、开始、最后和结束后边界正确，最后开放窗口后推进一次即最终确定。
4. 部署时 `base` 快照、所有轮次确定性系数、最后一轮系数和 O(log n) 定点幂正确。
5. 同轮拆单与合并得到相同累计得分。
6. SL/ST 新凭证、部分及重复锁定正确，直接转账不记分。
7. 治理与行动状态按显式 `round` 查询；奖励只使用实际领取且排除 burnReward，额度跨轮失效，历史未使用额度仅展示；含二次分配的扩展仍将 claimant 的整笔 mintReward 作为其额度，recipient 不产生独立额度。
8. 基础与扩展行动互斥，受支持 Factory 后续扩展可用，非受支持扩展不被调用。
9. 行动批次混合社区、重复来源、零数量和中途失败的全量回滚行为正确；所有写入口传入过期、未来或交易执行时已切换的 `round` 均回滚。
10. 活跃类别和活跃社区重新归一化、全局无人参与、所有舍入余量处理正确。
11. 四种事件字段、指定轮次与全周期累计值、参与地址去重、`limit == 0` 及分页边界正确。
12. 单地址四类明细之和等于 `accountTokenShare.total`，跨社区之和等于 `accountShare.share`，所有地址份额之和允许因向下取整小于 `1e18`。
13. 部署校验脚本注入错误权重、`base`、依赖、参数或 gas 结果时必须以非零状态退出。
