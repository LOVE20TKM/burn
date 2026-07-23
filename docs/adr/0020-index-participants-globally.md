# 维护全局参与地址索引

地址第一次通过 Burn 入口成功锁定或销毁资产时加入全局去重参与者列表，后续操作不重复写入；直接向 Burn 或社区代币合约转账不计入。空投准备程序通过 `participantsCount` 和 `participants(offset, limit)` 批量分页发现地址；`limit == 0` 或偏移量越界时返回空数组，末页自动截短。`isParticipant` 提供成员判断，不增加逐项 getter，也不维护按社区或类别重复的参与者数组。
