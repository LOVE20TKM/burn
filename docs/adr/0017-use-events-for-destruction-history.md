# 使用事件保存销毁历史

Burn 不保存逐地址历史数组。当前可销毁资格、已用额度、累计数量和累计得分由 mapping 与 view 提供；逐笔历史由 `SLTokenLocked`、`STTokenLocked`、`GovRewardTokenBurned`、`ActionRewardTokenBurned` 四种明确事件记录，并统一索引社区地址、参与地址和激励轮次。每条事件包含本次数量、得分系数、本次得分，以及地址和社区在该类别内的全周期累计数量与得分；行动事件另含普通字段 actionId 和扩展地址，基础 Mint 行动的扩展地址为零。事件不记录仍会随其他参与者变化的份额。社区代币合约持有的 SL/ST 余额包含直接转入，不能代替事件还原本次 Burn 历史。前端和空投准备程序通过事件查询历史，避免逐笔历史数组和重复 storage。
