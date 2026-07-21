# 暴露社区基准与确定性得分系数

Burn 通过 `communityBase(token)` 返回部署时冻结的社区 `base`，通过 `scoreMultiplier(token, round)` 返回销毁周期内任意轮次的确定性得分系数。系数只依赖部署时 `base` 和 `endRound - round`，查询不写状态，也不返回 `frozen`。`round < startRound` 或 `round > endRound` 时返回零，非参与社区回滚 `UnsupportedCommunity`。`finalized` 只表示整个销毁份额是否已经最终确定，与得分系数无关。
