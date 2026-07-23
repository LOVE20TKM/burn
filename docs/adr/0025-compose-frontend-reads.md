# 前端批量组合职责单一的查询

Burn 不提供包含轮次、余额、治理、行动和累计数据的万能账户状态 view。社区配置由 `communityWeight(token)` 和 `scoreBase(token)` 返回，轮次得分系数由 `scoreMultiplier(token, round)` 返回，治理和行动额度分别由 `govRewardBurnState(account, token, round)` 与 `actionRewardBurnStates(account, token, round)` 返回，已发生的数量和得分由 `accountRoundBurnStats` 与 `accountBurnStats` 返回，可选同链领取由 `accountAirdropState(account)` 单独返回。社区代币、SL、ST 的钱包余额和对 Burn 的 allowance 直接读取标准 ERC20，不由 Burn 代理；社区历史累计永久锁定量读取 `SL/ST.balanceOf(tokenAddress)`，本次销毁获得计分的锁定量读取 Burn 累计状态和事件。前端通过现有批量读取能力组合这些调用；命名统一使用 `State` 表示当前操作状态、`Stats` 表示已发生累计、`Share` 表示份额。
