# 冻结不受激励预留状态影响的销毁得分复利基数

Burn 部署时读取 LOVE20Mint 的治理、行动激励比例，并以 `maxSupply - totalSupply` 作为未铸造空间计算 `deploymentRoundReward`，再除以部署时 `totalSupply` 得到社区 `scoreBase`。该口径不读取 `rewardAvailable`，因此不会因某社区当轮激励是否已经 prepare 或 reserved 而改变。每个参与社区只保存一次 `scoreBase`，所有销毁轮次使用 `powWad(scoreBase, endRound - round)` 得到 `scoreMultiplier`；最后一轮系数固定为 1，后续铸造、原生销毁和协议预留均不再影响系数。定点幂使用内部 `Math.mulDiv` 平方求幂，复杂度 O(log n)，不引入新数学库。
