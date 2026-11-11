# 动态空投领取合约设计

状态：已实现，待部署验收。

`Airdrop` 将一条 EVM 来源链上已经结束的 Burn 最终份额带到目标 EVM 链。一份不可变来源快照可以分配领取合约持有的任意标准 ERC20；不同代币独立领取。

领域术语以 [CONTEXT.md](../CONTEXT.md) 为准，关键取舍见 [ADR](./adr/)。

## 1. 边界

合约负责：

- 固定来源链 ID、来源区块号、Burn 地址、Merkle Root 和快照实际总份额。
- 验证地址与 Burn 全局最终份额组成的 Merkle 证明。
- 按每种 ERC20 的当前余额和剩余未领取份额计算领取量。
- 只允许快照地址本人提交证明并领取。

合约不负责：

- 不在目标链验证来源链状态；完整快照必须公开供复算。
- 不登记、枚举或限制 ERC20；领取时由调用者传入代币地址。
- 不支持原生币、转账税、黑名单或其他特殊代币语义。
- 不设置 owner、管理员、暂停、升级、截止时间、Root 更新或资产取回入口。
- 不支持部分领取、同币重复领取或单笔多币领取。

## 2. 来源快照

快照脚本在明确的来源区块：

1. 检查实际链 ID、区块号及 Burn 合约代码。
2. 分页读取 `participants()`。
3. 读取每个地址的 `accountShare()`，要求份额已经最终确定，只保留正份额地址。
4. 把份额归一化到精确 `1e18` 作为 `totalShare`，余数补给最大份额地址。
5. 以归一化后的份额生成 Merkle Root、每个地址的证明和 JSON 文件。

正份额地址在来源区块具有合约代码时，生成器会列出地址并默认停止。逐一确认这些合约账户能够在目标链控制同一地址后，才可通过 `CONTRACT_ACCOUNTS_REVIEWED=true` 显式确认并重新生成；该确认不能替代人工核验。

每个叶子为：

```solidity
keccak256(bytes.concat(keccak256(abi.encode(account, share))))
```

树的每对节点按字节值排序后哈希；某层最后一个无配对节点直接提升到下一层。该格式与合约内 OpenZeppelin `MerkleProof` 的排序证明验证一致。

归一化算法（`GenerateAirdropSnapshot.normalizeShares`）：

```solidity
uint256 rawTotal = Σ shares[i];
uint256 largestIndex = argmax(shares);           // 并列取索引最小者
normalized[i] = Math.mulDiv(shares[i], WAD, rawTotal);   // floor
normalized[largestIndex] += WAD - Σ normalized[i];
```

`floor` 只会丢弃尘埃，因此 `Σ normalized[i] <= 1e18` 恒成立，余数不超过 `地址数 - 1` wei。归一化在**叶子构建之前**完成：叶子哈希、JSON 中的 `share`、`merkleRoot` 三者都基于同一份归一化数组，不可能互相不一致。生成器断言 `Σ normalized == 1e18`，正常不可达失败分支。

生成器同时拒绝任何 `normalized[i] == 0` 的条目。来源份额本身已是 WAD 分数、且 `Σ raw <= 1e18` 时，`normalized[i] >= raw[i] >= 1` 恒成立，截断为 0 只在原始分布远超 `1e18` 量级时才会出现；`build()` 是 public 入口，无法假定调用方满足这条约束。零份额叶子会占用一个证明与一次领取资格却永远付不出任何代币，因此生成器直接拒绝，而不是把它写进快照。

归一化的动机：消费方把总份额硬编码为编译期常量 `1e18`，链下快照必须 `Σleaves == 1e18` 精确相等；若只做上限校验（`Σ <= 1e18`），多次向下取整会留下 `1e18 - Σ` 的份额永久无人可领。

默认通过一键脚本生成快照并部署目标链 Airdrop；可用 `SOURCE_BLOCK_NUMBER` 固定来源区块：

```bash
SOURCE_BLOCK_NUMBER=<来源区块> bash script/deploy/one_click_deploy_airdrop.sh <来源网络> <目标网络>
```

存在已核验的来源合约账户时：

```bash
CONTRACT_ACCOUNTS_REVIEWED=true SOURCE_BLOCK_NUMBER=<来源区块> bash script/deploy/one_click_deploy_airdrop.sh <来源网络> <目标网络>
```

需要独立复核快照时，先单独生成；复核后的一键脚本会直接复用它：

```bash
SOURCE_BLOCK_NUMBER=<来源区块> bash script/deploy/generate_airdrop_snapshot.sh <来源网络> <目标网络>
bash script/deploy/one_click_deploy_airdrop.sh <来源网络> <目标网络>
```

脚本从来源网络的 `network.params` 和 `address.burn.params` 读取 RPC、链 ID 和 Burn 地址，默认固定执行时的最新区块；可通过 `SOURCE_BLOCK_NUMBER` 指定已确认区块。输出为：

```text
script/network/<目标网络>/airdrops/<来源链ID>-<来源Burn地址>-<来源区块>/airdrop-snapshot.json
script/network/<目标网络>/airdrops/<来源链ID>-<来源Burn地址>-<来源区块>/airdrop.params
```

快照 JSON 还包含 `accountCount`，必须与 `entries` 实际地址数一致。生成器在 `build()` 阶段拒绝重复地址（与验证器一致）；"每个地址只出现一次"是合约一次性领取资格的结构性前提，重复叶子会导致该份额永久无人可领。

例如：

```bash
SOURCE_BLOCK_NUMBER=123456 bash script/deploy/one_click_deploy_airdrop.sh anvil anvil
```

部署前必须独立复算 JSON 中的 `entries`、`merkleRoot`、`totalShare` 和每个 proof，并确认来源字段与计划一致；部署后还要用目标链合约逐个地址复核叶子和 proof，全部通过后才公布地址。链下校验器做 JSON 自洽性校验（要求 `totalShare == 1e18` 且 `Σentries == 1e18`、按同规则重算 root、逐条验 proof），**不能发现生成器读错来源数据**；来源一致性必须由部署者回读来源链的 `participants()` 与 `accountShare()`（或使用带 `--fork-url`/`--fork-block-number` 的 fork 复核）独立确认。

## 3. 部署配置

```solidity
constructor(
    uint256 sourceChainId,
    uint256 sourceBlockNumber,
    address sourceBurnAddress,
    bytes32 merkleRoot,
    uint256 totalShare
)
```

`totalShare` 必须等于 `1e18`。来源字段和 Root 部署后不可修改。部署脚本读取同名大写环境变量，并在广播后逐项验收公开 getter。

`DeployAirdrop` 在广播前强制要求 `SNAPSHOT_INPUT` 指向待部署的 `airdrop-snapshot.json`，并调用验证器复算 `Σentries`、root 与逐条 proof；缺少 `SNAPSHOT_INPUT` 或快照校验失败时直接回滚。这样即使绕过一键脚本直接调用部署脚本，也不会跳过唯一的快照一致性校验。路径必须位于 `foundry.toml` 的 `fs_permissions` 允许范围内（`./script/network/`），即快照目录中的 JSON。

每份版本化快照目录需要同时保留快照生成器写出的 `airdrop-snapshot.json` 和 `airdrop.params`：

```bash
SNAPSHOT_INPUT=<快照JSON路径>
SOURCE_CHAIN_ID=<来源链ID>
SOURCE_BLOCK_NUMBER=<来源区块号>
SOURCE_BURN=<Burn地址>
MERKLE_ROOT=<快照MerkleRoot>
TOTAL_SHARE=<快照实际总份额>
```

确认目标网络的 `.account`、`network.params`、`airdrop-snapshot.json` 和 `airdrop.params` 后，一键部署并验收：

```bash
bash script/deploy/one_click_deploy_airdrop.sh <来源网络名> <目标网络名>
```

部署脚本在没有候选时生成快照，已有该来源唯一未完成部署的快照时直接复用，不会覆盖其他快照；存在多个候选时会报错。它会核对 JSON 的全部地址、份额、Root、总份额和 proof，并核对参数中的五项来源字段；广播并验收 getter 及逐地址 proof 成功后，在同一版本目录写出地址和 `airdrop-deployment.json`。广播发送失败时，同一命令会通过 Foundry broadcast artifact 的 `--resume` 继续发送；广播成功但验收失败时只继续验收，不会重复部署。Airdrop 不属于 Burn 的普通部署阶段，只有快照生成器确认全部份额已经最终确定后才能进入该部署步骤。

## 4. 领取规则

```text
remainingShare(token) = totalShare - claimedShare(token)
claimAmount = token.balanceOf(airdrop) × accountShare ÷ remainingShare(token)
```

计算使用 `Math.mulDiv` 并向下取整。领取成功前必须满足：

- 代币地址具有合约代码。
- 调用者就是快照中的领取地址。
- 地址和份额能通过不可变 Root 验证。
- 该地址尚未领取这种代币。
- 地址份额不超过这种代币的剩余份额。
- 计算出的领取量大于零。

校验顺序以实现为准：账户非零 → 调用者是账户本人 → 代币地址有代码 → 份额非零 → 未领取 → 份额不超过剩余 → Merkle proof → 金额大于零。第三方调用者总会在 proof 校验之前得到 `UnauthorizedClaimer`，不会因 proof 质量得到不同错误。

状态在 ERC20 转账前更新，并使用重入保护；转账失败时整笔交易回滚。每种代币分别保存已领取地址、累计已领取份额和每个账户的实际领取金额，领取一种代币不影响其他代币。

`claimableAmount(token, account, share, proof)` 是只读的"当前可领取量"，不校验调用者，且返回 `0` 有七类不同成因：

- 代币地址为零或无代码；
- 账户为零；
- 份额为零；
- 该账户已领取该代币；
- 份额超过剩余份额；
- Merkle proof 无效；
- 资格有效但 `floor` 后的金额为零（等待充值或更小份额地址先领取）。

前端不能用 `0` 判断"无资格"，应结合 `isClaimed`、`remainingShare` 与转账前后余额差展示；已领取账户的实际金额可直接读 `claimedAmount(token, account)`，无需依赖事件历史；对 `balanceOf` 会 revert 的代币，整个 view 也会 revert，需要 try/catch。

## 5. 充值与永久边界

任何人都可直接向领取合约转入标准 ERC20。充值前应检查：

```solidity
remainingShare(token) > 0
```

但该条件**不是充分条件**：单叶可领当且仅当 `balance × share ≥ remainingShare`；若入账余额 `B < remainingShare / maxShare`，所有地址的 `claimableAmount` 都为 0、`claim` 都回滚 `NoClaimableAmount`，直到继续充值。按最大份额地址抽检一次 `claimableAmount > 0` 更可靠。

某地址领取一种代币后，后续转入的同种代币只由尚未领取该代币的地址分配，且不补发；因此提前领取会永久放弃该代币后续的追加充值。若预期会有后续充值，领取者应等待。价格随领取单调上升（floor 尘埃留在池中），等待不会让先领取者占便宜。

任何转入该合约的 ERC20（包括与本次空投无关的误转代币）都会立刻成为该代币的动态池，被下一个领取者按 `share / remainingShare` 分走；合约不登记代币目录，也没有资产取回入口。误转不会"锁死"，而是分配给尚未领取的地址。

`remainingShare(token) == 0` 后再转入该代币，因没有剩余资格且没有取回入口，资产永久锁定。另外，以下情况下 `remainingShare > 0` 也可能永久锁定对应比例：快照中存在重复地址、来源地址的私钥失联、或来源地址是目标链上无法控制同一地址的合约账户。全部叶子领取后，最后一位领取者获得前面所有人 floor 取整留下的最小单位余量。

新生成的快照由生成器保证 `Σleaves == totalShare == 1e18`，因此不会再出现"快照自身就有不可领取份额"的情形：`remainingShare(token)` 只在所有叶子都被领取后才归零，不存在结构性残留。历史快照（归一化之前生成的）仍可能满足 `Σleaves != totalShare`：此时 `totalShare < Σleaves` 会让尾部地址永久回滚 `ShareExceedsRemaining`，`totalShare > Σleaves` 会让 `totalShare - Σleaves` 的比例永久锁定。链下验证器现在要求 `totalShare == 1e18` 且 `Σentries == 1e18`，这类快照会被直接拒绝，不会再被部署。

同一份来源快照可以在目标链部署多个实例，但每个实例只分配自己持有的余额；若两个实例都被充值，同一地址可各领一次。运营上应保证**同一来源快照在目标链只存在一个官方实例**，并只公布通过验收的地址。

合约没有管理员、没有暂停、没有截止时间、没有 Root 更新或资产取回入口；误转资产、无人领取份额和部署参数错误都无法从合约取回。

## 6. 验收测试清单

仓库现有 `test/Airdrop.t.sol` 与 `test/AirdropEdgeCases.t.sol` 覆盖：

- 构造器冻结五项来源字段并拒绝零值/越界参数。
- 本人领取成功；第三方调用（含有效 proof 与无效 proof）统一回滚 `UnauthorizedClaimer`，状态不变。
- 重入：token 转账回调中再次 `claim` 被 `ReentrancyGuard` 拦下，外层状态一致。
- 非标准 ERC20：`transfer` 返回 `false` 时整笔回滚、资格保留；空返回值（USDT 风格）可正常领取。
- 金额为 0 时不消耗资格；追加充值后按比例可领。
- 单叶树（空 proof）、5 叶与 9 叶奇数树全部可领且末位领取者清零余额。
- 快照生成器拒绝重复地址。
- 全领后 `claimedShare == totalShare`、余额为 0；之后再转入的代币永久留存。
- 领取成功后 `claimedAmount(token, account)` 等于返回值、事件 `amount` 与账户余额增量；重复领取与失败回滚不改变它；不同代币互相隔离。
- 生成器归一化正确性：raw `[1,1,1]` 归一化后 `Σ == 1e18` 且余数落在最大份额（并列取最小索引）地址；raw `[0.2,0.3,0.4]` 归一化为 `[222222222222222222, 333333333333333333, 444444444444444445]`；`build` 的 `totalShare` 恒为 `1e18`；raw 叶子无法通过归一化后的 root。
- 生成器拒绝空快照、零份额条目与全零份额（`normalizeShares` 的 `rawTotal == 0` 分支）。
- 随机份额/余额/领取顺序下 `Σpayout == 初始余额`（fuzz）。

以下仍属部署前人工复核（当前无自动化测试）：

- 验证器对重复地址、篡改条目与来源不一致快照的拒绝路径（一键脚本会执行 happy path，负向路径需人工构造快照确认）。
- 从来源链回读 `participants()`/`accountShare()` 并与 JSON 做全量比对。
- 目标链浏览器源码验证与带 fork 的部署演练。

测试约定：快照生成相关用例必须在单个测试函数内串行执行，避免 `vm.setEnv` 的进程级全局状态与其他并发测试冲突；fixture 路径必须唯一；CI 建议使用 `forge test -j 1`。

## 7. 接口、事件与错误

### 7.1 只读接口

| 接口 | 语义 |
| --- | --- |
| `sourceChainId()` / `sourceBlockNumber()` / `sourceBurnAddress()` | 来源快照的链 ID、区块号与 Burn 地址，仅用于溯源，不参与领取验证 |
| `merkleRoot()` / `totalShare()` | 不可变的 Merkle Root 与快照份额总和（`Σleaves`，新快照恒为 `1e18`） |
| `claimedShare(token)` | 该代币已被成功领取消耗的来源份额累计值 |
| `claimedAmount(token, account)` | 该地址在该代币上成功领取时实际铸造到的金额；从未领取为 0 |
| `remainingShare(token)` | `totalShare - claimedShare(token)`，即该代币剩余未领取份额 |
| `isClaimed(token, account)` | 该地址是否已成功领取过该代币 |
| `leafHash(account, share)` | 快照叶子编码，必须与生成器/验证器保持一致 |
| `claimableAmount(token, account, share, proof)` | 当前可领取金额；返回 0 的七类成因见 §4 |

### 7.2 事件

```solidity
event AirdropClaimed(
    address indexed token,
    address indexed account,
    uint256 share,
    uint256 amount,
    uint256 remainingShare
);
```

- `token`：本次领取的 ERC20；`account`：快照账户，必然等于 `msg.sender`；`share`：快照中的来源份额；`amount`：合约按 `balance × share ÷ remainingShare` 记账的金额（标准 ERC20 下等于实收）；`remainingShare`：领取后的 `totalShare - claimedShare[token]`。
- 与 Burn 的同名事件不同：Burn 的 `AirdropClaimed(address indexed account, uint256 share, uint256 amount, uint256 remainingShare)` 是 4 字段、没有 `token`，两者 topic0 不同。索引器必须按合约地址/事件签名分流，不能按事件名跨实例聚合。

### 7.3 错误

| 错误 | 触发条件 |
| --- | --- |
| `ZeroAddress()` | 构造器 `sourceBurnAddress == address(0)` |
| `InvalidSourceChainId()` | 构造器 `sourceChainId == 0` |
| `InvalidSourceBlock()` | 构造器 `sourceBlockNumber == 0` |
| `InvalidMerkleRoot()` | 构造器 `merkleRoot == bytes32(0)` |
| `InvalidTotalShare()` | 构造器 `totalShare == 0` 或 `> 1e18`（历史部署约束；新快照恒传 `1e18`） |
| `InvalidToken()` | 代币地址为零或没有合约代码 |
| `InvalidAccount()` | 账户为零地址（在调用者校验之前） |
| `InvalidShare()` | 份额为零 |
| `InvalidProof()` | 地址与份额无法通过不可变 Root 验证 |
| `UnauthorizedClaimer()` | `msg.sender != account`（在 proof 校验之前） |
| `ShareExceedsRemaining(share, remainingShare)` | 份额超过该代币剩余份额（一致快照下不可达） |
| `AirdropAlreadyClaimed()` | 该 `(token, account)` 已成功领取 |
| `NoClaimableAmount()` | 计算出的领取量为零，状态不变 |

`claimableAmount` 对无效输入返回 0 而不是回滚；但 `balanceOf` 会 revert 的代币会让整个 view revert。
