# LOVE20 生态资产销毁与份额合约设计

状态：已实现，待部署验收。

本合约以下简称 `Burn`。部署时指定一个 LOVE20 范围代币，其自身社区和已经完成发射的直接子币社区可以永久锁定 SL/ST 凭证、真实销毁治理与行动激励所铸造代币，并按销毁得分竞争份额。Burn 始终提供份额；可选指定另一种 ERC20 作为空投代币，并由参与地址直接领取。

领域术语以 [CONTEXT.md](../CONTEXT.md) 为准，关键取舍见 [ADR](./adr/)。

## 1. 目标与边界

Burn 必须做到：

- 部署时显式配置的范围代币社区及其已经完成发射的直接子币社区可以参与。
- 四类资产分别竞争份额，并在无人参与时重新分配空池。
- 可销毁激励额度绑定地址当轮实际铸造的激励。
- 提前参与通过得分系数获得更高得分。
- 所有份额、累计值和历史都可被前端及外部空投程序核验。
- 可选使用同链 ERC20 动态剩余池，让参与地址按领取时余额直接领取。
- 合约不可升级、无 owner、无管理员配置、无资产救援入口。

Burn 明确不做：

- 不支持部署后新完成发射的直接子币，也不递归包含范围代币的孙币或更深层代币。
- 不支持 beneficiary、代销毁、额度转让或单独接收地址。
- 不负责未配置空投代币时的外部分配流程。
- 不保存逐笔历史数组，不为未领取地址预存固定空投数量。
- 不快照空投池，不限制后续转入，也不提供空投资产救援入口。
- 不设置最低销毁量、最低参与率或类别激活截止。

## 2. 构造与协议依赖

```solidity
struct CommunityWeight {
    string tokenSymbol;
    uint256 weight;
}

struct BurnRoundConfig {
    uint256 startRound;
    uint256 roundCount;
    uint256 quotaMultiplier;
}

constructor(
    address extensionCenterAddress,
    string memory scopeTokenSymbol,
    address airdropTokenAddress,
    CommunityWeight[] memory communityWeights,
    uint256 slTokenLockWeight,
    uint256 stTokenLockWeight,
    uint256 govRewardBurnWeight,
    uint256 actionRewardBurnWeight,
    BurnRoundConfig memory roundConfig,
    address[] memory supportedExtensionFactories
)
```

构造参数规则：

- `extensionCenterAddress` 不得为零地址。
- `scopeTokenSymbol` 必须由该 ExtensionCenter 对应 Launch 映射到已经完成发射的 LOVE20Token。
- `airdropTokenAddress` 可以为零地址，表示 Burn 只提供份额；非零时必须有合约代码、不得等于 `scopeTokenAddress`，并由部署校验确认它是标准 ERC20。它可以与范围代币之外的参与社区资产地址相同。
- `communityWeights` 不得为空，范围代币必须出现且只能出现一次。
- 每项 `weight > 0`，symbol 经 Launch 解析后的代币地址不得重复；范围代币以外的代币必须是已经完成发射的直接子币。
- 权重是无单位的正整数相对值，Burn 只保存并按比例使用，不定义其链下计算方法。
- `slTokenLockWeight`、`stTokenLockWeight`、`govRewardBurnWeight`、`actionRewardBurnWeight` 为非负整数，且至少一项大于零；为零表示禁用对应类别，分别冻结四类资产的相对权重。
- `roundConfig.roundCount > 0`。
- `roundConfig.quotaMultiplier > 0`，使用整数，例如 `5` 表示五倍。
- `roundConfig.startRound >= LOVE20Vote.currentRound() - 2`。
- `endRound = roundConfig.startRound + roundConfig.roundCount - 1`，溢出则部署回滚。
- Factory 不得为零地址或重复；空数组合法，表示仅支持基础 Mint 行动。

ExtensionCenter 是唯一协议地址入口。Burn 从其不可变 getter 获取 Launch、Vote 和 Mint 等地址，不再接受这些地址的独立配置。实现可以缓存频繁使用的派生地址为 immutable，但不能形成第二套可配置来源。

以下配置通过公开 getter 或只读数组公开（`scoreBase` 和 `totalCommunityWeight` 为构造时派生值，非构造参数）：

```solidity
extensionCenter()
scopeTokenSymbol()
scopeTokenAddress()
airdropTokenAddress()
startRound()
roundCount()
endRound()
quotaMultiplier()
slTokenLockWeight()
stTokenLockWeight()
govRewardBurnWeight()
actionRewardBurnWeight()
supportedExtensionFactories()
isSupportedExtensionFactory(factory)
```

## 3. 参与社区与社区权重

### 3.1 社区配置校验

部署时按以下顺序校验 `communityWeights`：

1. 通过 Launch 将 `scopeTokenSymbol` 解析为已经完成公平发射的 LOVE20Token 地址。
2. 通过 Launch 解析各社区 symbol，逐项拒绝未知 symbol、零权重和重复代币。
3. 范围代币自身合法；其他代币必须已经完成发射，且其 `parentTokenAddress` 必须等于范围代币。
4. 范围代币必须在数组中出现，直接子币可以只配置本次计划支持的子集。
5. 按传入顺序冻结参与社区、权重和各社区的 `scoreBase`，同时累加 `totalCommunityWeight`。

未配置的直接子币、部署后新完成发射的直接子币、范围代币的孙币和更深层代币均不参与。范围代币可以是 LOVE20 根币，也可以是任意已经完成发射的子币；参与范围始终只向下展开一层。

### 3.2 权重语义

Burn 不读取部署时的 SL、LP、储备或价格来计算社区权重：

```text
communityWeight = 构造参数中该社区的 weight
totalCommunityWeight = 所有已配置社区 weight 之和
```

- 权重只表达社区之间的相对比例，不要求使用 `1e18` 精度，也不要求具有代币数量单位。
- 权重如何得出由每次部署自行决定，不属于 Burn 的合约规则。
- 权重在部署时冻结，之后不随任何市场、流动性或质押状态变化。

只读接口：

```solidity
communities() returns (address[] memory)
communitySymbols() returns (string[] memory)
communityWeight(address tokenAddress) returns (uint256)
scoreBase(address tokenAddress) returns (uint256)
totalCommunityWeight() returns (uint256)
```

`communityWeight(tokenAddress) == 0` 和 `scoreBase(tokenAddress) == 0` 表示非参与社区。其他需要社区语义的详细查询和全部写入口遇到非参与社区时回滚 `UnsupportedCommunity(tokenAddress)`。

## 4. 销毁周期

Burn 轮次等于 LOVE20Mint 激励轮次。标准部署中 Vote 比 Verify 提前两个阶段，而激励轮次 `R` 在 Verify 进入 `R + 1` 时可以铸造，因此：

```text
currentBurnRound = LOVE20Vote.currentRound() - 3
```

开放条件：

```text
open = startRound <= round <= endRound
       且 LOVE20Vote.currentRound() > 2
       且 round == currentBurnRound
```

历史轮次不能补销毁，未使用额度跨轮失效。份额最终确定条件为：

```text
finalized = currentBurnRound > endRound
```

`LOVE20Vote.currentRound() == endRound + 3` 正是最后一个轮次的销毁开放窗口；Vote 再推进一次时，份额立即最终确定。

不需要 `finalize()` 交易或结算事件。Vote 已进入第 3 轮时，前端可默认选择 `Vote.currentRound() - 3`；此前默认选择 0。所有按轮次查询和全部写入口都显式传入 `round`；配置、全周期累计和份额查询不带轮次。

## 5. 销毁类别与份额

四个类别的基础权重由四个独立构造参数冻结，当前部署参数可以使用 `1:1:1:1`：

| 类别               | 资产处理               | 构造字段                   |
| ------------------ | ---------------------- | -------------------------- |
| `SLTokenLock`      | 永久锁定流动性质押凭证 | `slTokenLockWeight`        |
| `STTokenLock`      | 永久锁定加速质押凭证   | `stTokenLockWeight`        |
| `GovRewardBurn`    | 真实销毁治理激励代币   | `govRewardBurnWeight`      |
| `ActionRewardBurn` | 真实销毁行动激励代币   | `actionRewardBurnWeight`   |

某一类别在该社区的整个销毁周期内累计总得分大于零时，该类别为活跃类别。社区至少有一个活跃类别时为活跃社区。

### 5.1 社区重新归一化

全局只在活跃社区之间按冻结权重分配：

```text
activeCommunityWeight = 所有活跃社区的冻结权重之和

communityShare = floor(
    communityWeight * 1e18 / activeCommunityWeight
)
```

四类均无得分的社区退出分配。若全局没有活跃社区，所有地址份额为零；同链模式无人可以领取，外部空投程序也不生成个人分配。

### 5.2 类别重新归一化

社区份额只在活跃类别之间按构造时冻结的基础权重重新归一化：

```text
activeCategoryWeight = 所有活跃类别的冻结权重之和

categoryShare = floor(
    communityShare * categoryWeight / activeCategoryWeight
)
```

`1:1:1:1` 时保持原有等分结果；非等权配置按相对权重分配，无人参与的类别不计入分母。

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

每个参与社区在 Burn 部署时按当时状态计算并冻结 `scoreBase`：

```text
rewardRatePerThousand = LOVE20Mint.ROUND_REWARD_GOV_PER_THOUSAND()
                      + LOVE20Mint.ROUND_REWARD_ACTION_PER_THOUSAND()

deploymentRoundReward = floor(
    (token.maxSupply() - token.totalSupply())
    * rewardRatePerThousand / 1000
)

scoreBase = 1e18 + floor(
    deploymentRoundReward * 1e18 / token.totalSupply()
)
scoreMultiplier(R) = powWad(scoreBase, endRound - R)
```

`scoreBase` 是提前销毁对应的复利基数，`scoreMultiplier` 是指定轮次实际乘到锁定或销毁数量上的销毁得分系数。二者只参与得分计算，不参与可销毁额度计算；额度仍单独使用 `actualMintedReward * quotaMultiplier`。

规则：

- `deploymentRoundReward` 使用未铸造空间和 Mint 的实际激励比例，不读取 `rewardAvailable`，因此不受当轮激励是否已经 prepare 或 reserved 影响。
- `scoreBase` 和部署时的激励、供应量只取一次，之后不随铸造、原生销毁或协议预留变化。
- 当代币已全量铸造（`maxSupply == totalSupply`）时，`deploymentRoundReward == 0`，`scoreBase == 1e18`，各轮系数均为 `1e18`，提前参与无额外优势；这是数学上自洽的预期结果。
- 指数只包含当前轮之后的未来销毁轮次。
- 最后一轮 `endRound - R == 0`，系数为 `1e18`。
- `powWad` 使用内部平方求幂，复杂度 O(log n)，每次 `Math.mulDiv` 向下取整。
- 只对已配置社区计算 `scoreBase`；社区代币若 `totalSupply == 0`，部署回滚 `InvalidScoreBase(token)`。
- 同社区所有销毁轮次和四类操作使用同一部署时 `scoreBase`。

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

- 销毁周期内的轮次直接按部署时 `scoreBase` 计算，查询不写状态。
- `round < startRound` 或 `round > endRound` 时返回零；非参与社区回滚 `UnsupportedCommunity`。

## 7. 资产处理与额度

### 7.1 SL/ST 凭证永久锁定

- Burn 将 `msg.sender` 的指定社区 SL 或 ST 凭证直接转入该社区的 LOVE20Token 合约地址 `tokenAddress`，自身不持有凭证。
- LOVE20Token 没有转出任意 ERC20 的入口，且无法以凭证持有人身份主动调用 Stake 退出流程，因此转入的 SL/ST 永久锁定。
- 合约允许任意正数和同轮、跨轮重复锁定。
- 部署后新产生或新转入的合法凭证也可以参与。
- 标准前端默认提交调用时全部余额，不提供减少数量的交互。
- 直接向 Burn 或社区代币合约转入凭证不产生得分、不加入参与地址列表，也不能取回。
- `SLToken.balanceOf(tokenAddress)` 和 `STToken.balanceOf(tokenAddress)` 表示该社区历史累计永久锁定量，包含误转和未通过 Burn 的主动转入；本次 Burn 获得计分的锁定量仍以累计状态和事件为准。
- 锁定可能使原地址 `validGovVotes()` 归零，且正常退出原质押可能要求重新获得缺失凭证；这是已接受结果。

### 7.2 治理激励代币销毁

治理激励的实际铸造量直接读取：

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

### 7.3 行动激励来源

行动激励按 `token + round + actionId + account` 独立核销额度。基础与扩展来源互斥：

1. `ExtensionCenter.extension(token, actionId) == address(0)`：只读取 LOVE20Mint 基础行动激励。
2. 扩展地址非零：只读取该扩展的 `rewardByAccount(round, account)`。
3. 扩展的 Factory 必须在部署时冻结的受支持 Factory 列表内；否则状态查询跳过，写入回滚。
4. 扩展激励只使用已领取记录中实际铸造的 `mintReward`，不使用扩展的 `burnReward`；该笔额度整体归属于发起领取的地址（claimant），扩展内部向 recipients 的二次分配不再拆分 Burn 额度。
5. 销毁周期内由受支持 Factory 新建并登记的扩展行动可以参与。

基础行动的实际铸造量读取 `actionRewardMintedByAccount`；扩展行动以 `rewardByAccount` 返回的 `claimed` 和已经保存的 `mintReward` 为准。尚未铸造的理论激励只展示，额度和剩余额度均为零。

### 7.4 行动批量销毁

仅行动激励提供批量入口。批次可以混合多个社区和 actionId，采用全有或全无语义。

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

function claimAirdrop() external returns (uint256 amount);
```

全部锁定和销毁入口：

- 只为 `msg.sender` 消耗额度并记分。
- 要求社区受支持、传入 `round` 当前开放、数量大于零；交易延迟到其他轮次执行时回滚，不按新轮次记账。
- 在资产永久转移成功后整笔交易才成立。
- 不接受原生币，不提供 permit、beneficiary 或接收地址参数。

`claimAirdrop()` 只在配置了同链空投代币且份额已经最终确定时可调用。它只向 `msg.sender` 转账，不接收领取地址参数；具体计算及状态见 9.6 节。

## 9. 状态与累计查询

### 9.1 轮次开放状态

```solidity
function isRoundOpen(uint256 round) external view returns (bool);
```

仅当 `startRound <= round <= endRound`、`Vote.currentRound() > 2` 且 `round == Vote.currentRound() - 3` 时返回 `true`。实现先检查 Vote 已进入第 3 轮再做减法，使任意查询参数都不会因 `round + 3` 溢出。前端仍可查询历史轮次状态，但只有返回 `true` 时才启用锁定和销毁交易。

### 9.2 治理与行动激励状态

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

尚未铸造时，`claimableRewardAmount` 表示理论可铸造激励，`claimedRewardAmount`、额度和已用量均为零。实际铸造后，`claimableRewardAmount` 为零（注意：此时字段值归零，不表示"可认领量为零"，而是激励已转入 `claimedRewardAmount`），`claimedRewardAmount` 表示实际归属于 claimant 的激励；`burnQuotaAmount`、`burnedAmount` 和 `unusedQuotaAmount` 分别表示指定轮次的总额度、已销毁量和未使用额度，并满足 `burnedAmount + unusedQuotaAmount == burnQuotaAmount`。历史轮次的未使用额度只用于展示，不能继续销毁；前端必须结合 `isRoundOpen(round)` 决定是否允许操作。活动周期外，治理状态返回全零，行动状态返回空数组。

`actionRewardBurnStates` 遍历 LOVE20Vote 指定轮次的全局 `votedActionIds`，不能使用地址自己的投票列表，因为行动激励归属地址不一定是投票者。结果只保留激励大于零或已有销毁记录的受支持行动；基础 Mint 行动的 `extensionAddress` 为零，非受支持 Factory 的行动不调用扩展并直接跳过。每个地址每轮最多提交一个行动；当 `SUBMIT_MIN_PER_THOUSAND > 0` 时，已提交行动理论上限不超过 `floor(1000 / SUBMIT_MIN_PER_THOUSAND)`，已投票行动只是其子集。活动周期外返回空数组，不分页，部署校验必须覆盖该上限下的 view gas。

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

function accountBurnStatsThroughRound(
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

function communityBurnStatsThroughRound(
    address tokenAddress,
    uint256 round
) external view returns (BurnStats memory);

function communityBurnStats(
    address tokenAddress
) external view returns (BurnStats memory);
```

`accountRoundBurnStats` 和 `communityRoundBurnStats` 返回指定单轮值；`accountBurnStatsThroughRound` 和 `communityBurnStatsThroughRound` 返回截至指定轮次的累计值；不带轮次的 `accountBurnStats` 和 `communityBurnStats` 返回全周期累计值。

截至轮次累计按地址、社区和类别保存稀疏检查点，只记录发生变化的轮次，并以最新检查点作为全周期累计值，不再重复保存累计 mapping。地址单轮只保存数量，得分按该轮冻结系数派生；社区单轮数量和得分由本轮与前一轮累计检查点相减得到。同轮操作更新最后一个检查点，跨轮操作复制前值后追加检查点，写入复杂度为 `O(1)`；读取由合约二分查找不晚于目标轮次的最后检查点，复杂度为 `O(log k)`，`k` 为该地址或社区在该类别发生变化的轮次数。目标轮次早于首个检查点时返回零，晚于最后检查点时返回最新累计值。四类资产单位不同，不提供跨类别 `amount` 合计。

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

地址第一次通过 Burn 入口成功锁定或销毁时加入全局去重列表。`limit == 0` 或 `offset` 越界时返回空数组，末页自动截短；直接转账不加入列表。

### 9.6 可选同链空投

```solidity
struct AirdropState {
    bool enabled;
    bool shareFinalized;
    bool isClaimed;
    uint256 share;
    uint256 claimableAmount;
    uint256 claimedAmount;
}

function remainingAirdropShare() external view returns (uint256);

function accountAirdropState(
    address account
) external view returns (AirdropState memory);
```

`airdropTokenAddress == address(0)` 时，`enabled = false`，Burn 仍正常计算份额，但 `claimableAmount` 和 `claimedAmount` 为零，`claimAirdrop()` 回滚 `AirdropDisabled()`；外部程序可以读取最终份额并自行完成分配。

配置同链空投代币时，`remainingAirdropShare` 初始为 `1e18`。份额最终确定后，尚未领取地址的当前可领取量为：

```text
claimableAmount = floor(
    airdropToken.balanceOf(Burn)
    * accountFinalShare
    / remainingAirdropShare
)
```

成功领取时，Burn 保存该地址的 `claimedAmount`，并从 `remainingAirdropShare` 扣除该地址的最终份额，再向同一地址转账。最终份额已经由 `accountShare` 固定，不重复保存领取时份额；领取事件记录该值。每个地址只能成功领取一次，最终份额或计算金额为零时不能领取。

该模式没有空投池快照：

- 每个地址的数量在其成功领取时确定；领取前的 `claimableAmount` 只是按当前余额计算的实时值。
- 领取期间任何地址都可以继续向 Burn 转入空投代币，新增余额只由尚未领取的地址按剩余份额分配，已经领取的地址不补发。
- 每次计算向下取整，先前留下的最小单位余量会留在余额中并影响后续领取；不同领取顺序可能产生少量最小计量单位差异。
- 地址份额计算本身的舍入余量不会从 `remainingAirdropShare` 扣除。全部参与地址领取后仍可能有余额，之后再转入的代币也无人可以领取，且 Burn 不提供取回入口。
- `accountAirdropState` 在份额最终确定前返回实时份额预览、`shareFinalized = false` 和零可领取量；成功领取后返回零可领取量及实际 `claimedAmount`。

## 10. 事件

```solidity
event CommunityConfigFrozen(
    address indexed tokenAddress,
    string tokenSymbol,
    uint256 weight,
    uint256 scoreBase,
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

event AirdropClaimed(
    address indexed account,
    uint256 share,
    uint256 amount,
    uint256 remainingShare
);
```

四种锁定或销毁事件中的累计数量和得分都是地址或社区在该类别内的全周期累计值。它们不记录份额，因为其他人的后续操作仍会改变份额。`AirdropClaimed` 只在份额已经固定后发出，记录领取所用最终份额、实际数量和领取后的剩余份额。

## 11. 错误

建议使用以下最小自定义错误集合：

```solidity
error ZeroAddress();
error ZeroAmount();
error EmptyBatch();
error InvalidScopeToken(string tokenSymbol);
error InvalidAirdropToken(address tokenAddress);
error InvalidRoundCount();
error InvalidQuotaMultiplier();
error StartRoundTooEarly(
    uint256 minimumStartRound,
    uint256 startRound
);
error DuplicateExtensionFactory(address factory);
error InvalidCommunityConfig(string tokenSymbol);
error DuplicateCommunity(string tokenSymbol);
error MissingScopeCommunity();
error InvalidScoreBase(address tokenAddress);
error UnsupportedCommunity(address tokenAddress);
error RoundNotOpen(uint256 round, uint256 currentBurnRound);
error NoClaimedReward();
error BurnQuotaExceeded(uint256 unusedQuotaAmount, uint256 requestedAmount);
error UnsupportedExtensionFactory(address factory);
error AirdropDisabled();
error ShareNotFinalized();
error AirdropAlreadyClaimed();
error NoClaimableAirdrop();
```

不存在的 actionId、无激励行动或尚未完成激励铸造的行动均没有可销毁额度，统一表现为 `NoClaimedReward()`，不增加同义错误（合约无法在不调用外部扩展的情况下区分"行动不存在"与"行动激励为零"，因此统一归类为此错误）。ERC20 转账失败由 `SafeERC20` 原样回滚。

范围代币 symbol 未映射到已完成发射的 LOVE20Token 时回滚 `InvalidScopeToken(tokenSymbol)`；社区配置包含未知 symbol、零权重、尚未完成发射或非直接子币时回滚 `InvalidCommunityConfig(tokenSymbol)`，重复代币和缺少范围代币分别回滚对应错误。非零空投地址没有合约代码或等于范围代币时回滚 `InvalidAirdropToken()`。空投未启用、份额尚未最终确定、地址已经领取或当前计算金额为零时，分别使用对应的单一错误。

## 12. 安全约束

- 使用 `SafeERC20.safeTransferFrom` 将 SL/ST 凭证从参与地址直接转入对应社区代币合约；治理与行动激励代币先转入 Burn，再调用原生 `burn()`；同链空投使用 `SafeERC20.safeTransfer`。
- 写入口先完成所有资格、轮次、额度和来源检查，再更新累计状态并执行资产转移；任一外部调用失败时整笔交易回滚。
- 锁定和销毁入口不使用 `ReentrancyGuard`：参与社区代币及其 SL/ST 均由本次 ExtensionCenter 对应 Launch 的 LOVE20TokenFactory 创建，采用未覆盖外部转账 hook 的固定 ERC20 实现；原生 burn 不执行外部调用，扩展 `rewardByAccount` 通过 `STATICCALL` 调用，无法重入 Burn 写入口。
- 可选空投代币不属于 LOVE20TokenFactory 信任边界，因此 `claimAirdrop` 单独使用 `nonReentrant`，并在转账前保存领取数量和扣减剩余份额；转账失败时整笔交易回滚。
- 同链空投只支持余额稳定、发送方余额按转账数量减少且无转账税、无 rebase 的标准 ERC20。部署校验负责验证该假设；Burn 不尝试兼容任意非标准代币。
- 受支持扩展的信任边界是部署时冻结的 Factory，不能调用非受支持扩展读取激励。
- 定点比例计算使用 `Math.mulDiv` 并向下取整，整数额度乘法使用 Solidity 检查算术；溢出回滚，不使用饱和值。
- 没有 owner、升级入口、提取入口、救援入口、receive 或 payable 写入口。
- 直接或强制转入 Burn 的资产不记分且 Burn 不提供取回入口；若资产正是配置的空投代币，则按 9.6 节进入当前动态剩余池。直接转入社区代币合约的 SL/ST 不记分且无法取回。

## 13. 部署与发布校验

部署前：

1. 确认 ExtensionCenter 及其 Launch、Vote、Mint 等不可变地址正确。
2. 确认范围代币已经完成发射，逐项核对社区配置只包含范围代币和本次支持的已完成发射直接子币。
3. 确定并复核每个社区的权重。权重计算方法由部署者决定；例如可以采用最近七个完整轮次中，SL 所对应范围代币数量的中位数，但这只是示例，不属于合约规则。
4. 核对 `startRound`、`roundCount`、派生 `endRound` 和整数 `quotaMultiplier`；`START_ROUND` 必须在部署前确定为非负整数，不接受 `current`、`currentRound` 等动态别名。
5. 核对所有受支持 Factory 的地址、代码和激励接口。
6. 若配置同链空投代币，确认它不等于范围代币，并验证其代码、`balanceOf/transfer` 行为及无转账税、无 rebase 假设；只需要份额时传零地址。
7. 运行合约自动化测试和 gas 报告，确认 `scoreBase`、派生总权重、Factory 成员映射和部署事件；在目标链 fork 上按本次发布可构造的状态模拟部署、最坏批量、顺序领取和主要聚合 view，记录无法在当前轮次构造的项目及其替代证据。

部署后、公布地址前：

1. 确认目标链、部署地址和部署字节码或验证源码对应本次通过测试的版本。
2. 核对范围代币、可选空投代币、周期及倍数 getter。
3. 核对 `communities()`、`communitySymbols()`、每个社区权重和完整 Factory 数组与部署参数一致。
4. 读取并记录部署时派生的 `scopeTokenAddress`、`scoreBase` 和 `totalCommunityWeight`，不使用部署后可能已经变化的供应量重新计算。
5. 独立基准超出偏差、名单不完整、参数不符合本次发布计划、空投代币不符合假设、gas 超限或任何依赖不匹配时，视为部署失败，不公布地址。
6. 在前端及需要的外部空投程序中只登记通过验收的地址。

部署脚本对构造参数、依赖代码和外部接口等能够确定的输入检查必须 fail-closed：任何检查失败都累计失败数并以回滚或非零状态退出，不能只打印告警后继续返回成功。`scoreBase`、总权重、Factory 成员映射和部署事件由合约测试保障；部署后只记录派生值，不重复验证已经测试过的构造逻辑。空投代币行为、完整生命周期和目标链 gas 由自动化测试及本次发布的 fork 验收，不伪装成部署脚本能够自动证明的性质。

部署入口从配置读取 `EXTENSION_CENTER`、`SCOPE_TOKEN_SYMBOL`、可选的
`AIRDROP_TOKEN`、逗号分隔的 `COMMUNITY_SYMBOLS/COMMUNITY_WEIGHTS`、四项类别权重
`SL_TOKEN_LOCK_WEIGHT`、`ST_TOKEN_LOCK_WEIGHT`、`GOV_REWARD_BURN_WEIGHT`、
`ACTION_REWARD_BURN_WEIGHT`、`START_ROUND`、
`ROUND_COUNT`、`QUOTA_MULTIPLIER` 和可选的 `SUPPORTED_EXTENSION_FACTORIES`。`00_init.sh` 通过
ExtensionCenter 指向的 Launch 将社区 symbol 解析为其发射的代币地址，再交给 `DeployBurn.s.sol` 部署并
核对依赖代码、全部构造参数、社区顺序与权重、Factory 数组和代码及空投代币
`balanceOf` 接口；任一不一致即回滚。目标链最坏批量 gas、空投代币转账行为及部署后的链上地址仍必须
在本次发布的 fork 和部署后校验中确认。

## 14. 前端与空投准备

- 前端以选中的 `round` 为统一参数，分别调用 `isRoundOpen`、`scoreMultiplier`、`govRewardBurnState`、`accountBurnStatsThroughRound` 和 `communityBurnStatsThroughRound`；不得按轮次循环读取后临时求和。
- 社区代币、SL、ST 的钱包余额和对 Burn 的 allowance 直接调用各 ERC20 的 `balanceOf/allowance`，Burn 不代理标准代币查询。SL/ST 标准交互默认提交当前全部余额，不提供减少数量控件；合约接口仍允许任意正数。
- 社区历史累计永久锁定量直接读取 `SLToken.balanceOf(tokenAddress)` 和 `STToken.balanceOf(tokenAddress)`；本次空投获得计分的锁定量读取 Burn 累计状态和事件，前端必须用不同标签展示。
- 行动区域按需调用 `actionRewardBurnStates(account, token, round)`，用返回值构建批量销毁参数；该动态查询失败时不应阻塞 SL、ST 和治理区域。
- `accountRoundBurnStats` 展示指定单轮四类已锁定或销毁数量与得分，`accountBurnStatsThroughRound` 展示截至指定轮次累计，`accountBurnStats` 展示全周期累计；社区查询使用对应的三个 `community` 函数，历史页面另按地址、社区和轮次查询四种事件。
- 所有写交易携带页面选中的 `round`；发送前仍由 Burn 校验该轮是否开放，避免跨轮延迟交易按新轮次执行。
- `airdropTokenAddress == address(0)` 时，外部空投程序分页读取参与地址，并要求 `accountShare(account).finalized == true`；接收资格和具体数量由该外部流程决定。
- 配置同链空投代币时，前端通过 `accountAirdropState` 展示是否可领取、领取时使用的最终份额、当前可领取数量和已经领取数量。领取前的数量会随其他领取及后续转入变化，必须标注为“当前可领取”。
- 前端不提供空投池快照、补充资金或救援操作；任何地址直接向 Burn 转入配置的空投代币都会进入尚未领取地址的动态剩余池。

## 15. 最小验收测试

实现至少覆盖：

1. 范围代币为根币或普通子币时，正确接受显式配置的范围代币及已完成发射直接子币，并拒绝空数组、缺少范围代币、零权重、重复代币、未完成发射代币、其他代币和更深层后代。
2. `communityWeight` 和四个类别权重 getter 与构造参数完全一致，`totalCommunityWeight` 正确求和；部署时的 SL、LP、储备和价格变化不影响链上冻结权重。
3. `isRoundOpen(round)` 在开始前、开始、最后和结束后边界正确，最后开放窗口后推进一次即最终确定。
4. 部署时 `scoreBase` 冻结、所有轮次确定性 `scoreMultiplier`、最后一轮系数和 O(log n) 定点幂正确。
5. 同轮拆单与合并得到相同累计得分。
6. SL/ST 新凭证、部分及重复锁定正确，凭证进入对应社区代币合约而非 Burn；直接转入社区代币合约只增加社区累计永久锁定量，直接转入任一地址都不产生 Burn 得分。
7. 治理与行动状态按显式 `round` 查询；激励只使用实际铸造量且排除 burnReward，额度跨轮失效，历史未使用额度仅展示；含二次分配的扩展仍将 claimant 的整笔 mintReward 作为其额度，recipient 不产生独立额度。
8. 基础与扩展行动互斥，受支持 Factory 后续扩展可用，非受支持扩展不被调用。
9. 行动批次混合社区、重复来源、零数量和中途失败的全量回滚行为正确；所有写入口传入过期、未来或交易执行时已切换的 `round` 均回滚。
10. 等权和非等权配置下，活跃类别和活跃社区重新归一化、全局无人参与、所有舍入余量处理正确。
11. 四种事件字段、指定单轮、截止轮次与全周期累计值、参与地址去重、`limit == 0` 及分页边界正确；百轮连续检查点下写入保持 `O(1)`，截止轮次查询保持 `O(log k)` 并低于测试 gas 上限。
12. 单地址四类明细之和等于 `accountTokenShare.total`，跨社区之和等于 `accountShare.share`，所有地址份额之和允许因向下取整小于 `1e18`。
13. 零空投代币地址模式只提供份额且所有领取调用回滚；空投代币等于范围代币时部署回滚；同链模式只允许最终份额为正的地址成功领取一次。
14. 同链空投按当前余额和剩余份额计算：固定余额下不同领取顺序只产生少量最小计量单位差异，领取中新增余额只分给尚未领取地址，全部地址领取后新增余额及份额舍入对应余额无法领取。
15. `claimAirdrop` 在空投代币回调重入、转账失败和计算结果为零时正确回滚且不改变状态；`accountAirdropState` 在禁用、销毁中、可领取和已领取状态下字段一致。
16. 部署校验逻辑注入错误范围、权重、依赖、参数或不可读空投代币时必须失败，部署后供应量变化不产生校验误报；转账失败、回调重入、零领取量和主要 gas 路径分别由对应合约测试覆盖。
