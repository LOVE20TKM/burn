# 基础与扩展行动激励来源互斥

Burn 根据 ExtensionCenter 的 actionId 登记结果选择唯一行动激励来源：未登记扩展的基础行动只读取 LOVE20Mint，已登记扩展的行动只读取受支持扩展的 claimant `rewardByAccount`。禁止同一 actionId 同时走两条路径；扩展收到整笔激励后向 recipients 的二次分配不再单独生成 Burn 额度，避免重复核销。
