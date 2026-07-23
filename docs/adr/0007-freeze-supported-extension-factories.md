# 冻结受支持的扩展 Factory

行动激励代币销毁只接受 LOVE20Mint 基础行动激励，以及 Burn 部署时列入受支持列表的扩展 Factory 所创建并由 ExtensionCenter 登记的扩展激励。冻结的是可信 Factory，不是当时已有扩展地址；销毁周期内由受支持 Factory 新建并登记的扩展行动同样参与。未来新增 Factory 和任意自声明激励接口的合约不参与，避免伪造 `rewardByAccount` 返回值扩大销毁额度。状态查询直接跳过非受支持 Factory 的行动且不调用其 `rewardByAccount`；手工提交该行动销毁时明确回滚。`supportedExtensionFactories()` 一次返回完整冻结数组，`isSupportedExtensionFactory()` 提供成员判断，不增加分页接口；构造函数拒绝零地址和重复项，允许空数组表示仅支持基础 Mint 行动，并为每项发出 `SupportedExtensionFactoryFrozen`。
