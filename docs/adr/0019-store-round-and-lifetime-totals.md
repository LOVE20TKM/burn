# 保存单轮、截止轮次与全周期累计数据

Burn 按地址、社区和类别保存仅包含发生变化轮次的稀疏累计检查点，并以最新检查点作为全周期累计值，不再单独保存单轮或全周期累计 mapping。地址和社区的单轮数量及得分均由本轮与前一轮累计检查点的差值派生。同轮操作更新最后一个检查点，跨轮操作复制前值后追加检查点。查询在合约内二分查找不晚于目标轮次的最后检查点，读取复杂度为 `O(log k)`，其中 `k` 是该地址或社区在该类别发生变化的轮次数；写入只访问最后一个检查点，复杂度为 `O(1)`。

查询使用包含四个具名 `CategoryStats(amount, score)` 的 `BurnStats`：`accountRoundBurnStats` 和 `communityRoundBurnStats` 返回单轮值；`accountBurnStatsThroughRound` 和 `communityBurnStatsThroughRound` 返回截至指定轮次累计值；`accountBurnStats` 和 `communityBurnStats` 返回全周期累计值。不同类别的资产单位不做合计，逐笔时间线仍由事件提供，不保存空轮次检查点。
