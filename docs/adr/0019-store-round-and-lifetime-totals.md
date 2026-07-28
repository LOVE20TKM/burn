# 保存单轮、截止轮次与全周期累计数据

Burn 使用 mapping 同时保存按地址与社区类别的指定激励轮次实际数量、得分，以及整个销毁周期的累计数量、得分；每个社区类别也保存相同维度的总量。为了直接查询截至任意轮次的累计值，合约按地址、社区和类别保存仅包含发生变化轮次的稀疏累计检查点；同轮操作更新最后一个检查点，跨轮操作追加检查点。查询在合约内二分查找不晚于目标轮次的最后检查点，读取复杂度为 `O(log k)`，其中 `k` 是该地址或社区在该类别发生变化的轮次数；写入检查最后一个检查点，复杂度为 `O(1)`。

查询使用包含四个具名 `CategoryStats(amount, score)` 的 `BurnStats`：`accountRoundBurnStats` 和 `communityRoundBurnStats` 返回单轮值；`accountBurnStatsThroughRound` 和 `communityBurnStatsThroughRound` 返回截至指定轮次累计值；`accountBurnStats` 和 `communityBurnStats` 返回全周期累计值。不同类别的资产单位不做合计，逐笔时间线仍由事件提供，不保存空轮次检查点。
