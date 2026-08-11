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
4. 以所有保留地址份额之和作为 `totalShare`。
5. 生成 Merkle Root、每个地址的证明和 JSON 文件。

正份额地址在来源区块具有合约代码时，生成器会列出地址并默认停止。逐一确认这些合约账户能够在目标链控制同一地址后，才可通过 `CONTRACT_ACCOUNTS_REVIEWED=true` 显式确认并重新生成；该确认不能替代人工核验。

每个叶子为：

```solidity
keccak256(bytes.concat(keccak256(abi.encode(account, share))))
```

树的每对节点按字节值排序后哈希；某层最后一个无配对节点直接提升到下一层。该格式与合约内 OpenZeppelin `MerkleProof` 的排序证明验证一致。

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

快照 JSON 还包含 `accountCount`，必须与 `entries` 实际地址数一致。

例如：

```bash
SOURCE_BLOCK_NUMBER=123456 bash script/deploy/one_click_deploy_airdrop.sh anvil anvil
```

部署前必须独立复算 JSON 中的 `entries`、`merkleRoot`、`totalShare` 和每个 proof，并确认来源字段与计划一致；部署后还要用目标链合约逐个地址复核叶子和 proof，全部通过后才公布地址。

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

`totalShare` 必须大于零且不超过 `1e18`。来源字段和 Root 部署后不可修改。部署脚本读取同名大写环境变量，并在广播后逐项验收公开 getter。

每份版本化快照目录需要同时保留快照生成器写出的 `airdrop-snapshot.json` 和 `airdrop.params`：

```bash
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

状态在 ERC20 转账前更新，并使用重入保护；转账失败时整笔交易回滚。每种代币分别保存已领取地址和累计已领取份额，领取一种代币不影响其他代币。

## 5. 充值与永久边界

任何人都可直接向领取合约转入标准 ERC20。充值前应检查：

```solidity
remainingShare(token) > 0
```

某地址领取一种代币后，后续转入的同种代币只由尚未领取该代币的地址分配。当 `remainingShare(token) == 0` 后再转入该代币，资产会因没有剩余资格且没有取回入口而永久锁定。
