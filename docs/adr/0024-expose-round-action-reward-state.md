# 提供指定轮次的行动激励销毁状态

Burn 通过 `actionRewardBurnStates(account, token, round)` 遍历 LOVE20Vote 指定轮次的全局已投票 actionId，一次返回激励大于零或已有销毁记录的相关行动。每项包含 actionId、ExtensionCenter 解析出的扩展地址，以及理论可铸造激励、实际铸造激励、领取状态、总额度、已销毁量和未使用额度；基础 Mint 行动的扩展地址为零。不能使用地址自己的投票行动列表，因为行动激励归属地址不一定是投票者，也不遍历全部 Submit 行动。非受支持 Factory 的扩展行动直接跳过且不调用扩展；活动周期外返回空数组。历史轮次的未使用额度只用于展示，前端必须结合 `isRoundOpen(round)` 决定是否允许操作。每个地址每轮最多提交一个行动；当 `SUBMIT_MIN_PER_THOUSAND > 0` 时，已提交行动理论上限不超过 `floor(1000 / SUBMIT_MIN_PER_THOUSAND)`，已投票行动只是其子集。当前参数和实际参与量下不增加分页，部署校验必须覆盖理论上限下的 view gas。
