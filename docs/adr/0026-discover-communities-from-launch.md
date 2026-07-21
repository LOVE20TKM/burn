# 从 LOVE20Launch 自动发现参与社区

Burn 构造函数只接收 `extensionCenterAddress`、`startRound`、`roundCount`、正整数 `quotaMultiplier` 和 `supportedExtensionFactories`。它通过 ExtensionCenter 的不可变 `launchAddress` 获取 LOVE20Launch，再以 `tokensAtIndex(0)` 确定根币 LOVE20，并枚举其已完成发射、社区权重大于零的直接子币，同时在部署状态下冻结社区权重和 `base`。不再重复传入 Launch、LOVE20 或人工社区数组，避免配置不一致；孙币、未来新币和零权重社区自然排除。若最终没有正权重社区，构造函数回滚 `NoParticipatingCommunities`。合约只保存社区地址、权重、`base` 和总权重，提供一次返回完整列表的 `communities()`、`communityWeight()`、`communityBase()` 和 `totalCommunityWeight()`；权重大于零即代表参与，不重复保存布尔值或社区分页接口。部署时为每个参与社区发出 `CommunityConfigFrozen` 事件。
