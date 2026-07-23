# 校验并冻结显式配置的参与社区

Burn 构造函数接收 `extensionCenterAddress`、`scopeTokenAddress`、可为零但不得等于范围代币的 `airdropTokenAddress`、`communityWeights`、`startRound`、`roundCount`、正整数 `quotaMultiplier` 和 `supportedExtensionFactories`。它通过 ExtensionCenter 获取 LOVE20Launch，验证范围代币已经完成发射，并要求社区配置包含范围代币且其他项都是已经完成发射的直接子币；未配置的直接子币、更深层后代和未来新币不参与。合约保存社区地址、传入权重、`scoreBase` 和总权重，提供 `communities()`、`communityWeight()`、`scoreBase()` 和 `totalCommunityWeight()`；部署时为每个参与社区发出 `CommunityConfigFrozen` 事件。
