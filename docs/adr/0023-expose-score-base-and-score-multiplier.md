# 暴露销毁得分复利基数与得分系数

Burn 通过 `scoreBase(token)` 返回部署时冻结的销毁得分复利基数，通过 `scoreMultiplier(token, round)` 返回销毁周期内任意轮次的确定性销毁得分系数。系数只依赖 `scoreBase` 和 `endRound - round`，查询不写状态，也不参与可销毁额度计算；额度始终由 `actualMintedReward * quotaMultiplier` 决定。`round < startRound` 或 `round > endRound` 时返回零，非参与社区回滚 `UnsupportedCommunity`。
