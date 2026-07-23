# 保存轮次与全周期累计数据

Burn 使用 mapping 同时保存按地址与社区类别的指定激励轮次实际数量、得分，以及整个销毁周期的累计数量、得分；每个社区类别也保存相同维度的总量。查询使用包含四个具名 `CategoryStats(amount, score)` 的 `BurnStats`，分别提供 `accountRoundBurnStats`、`accountBurnStats`、`communityRoundBurnStats` 和 `communityBurnStats`，不要求前端传入类别编号。不同类别的资产单位不做合计，逐笔时间线仍由事件提供，不增加历史记录数组。
