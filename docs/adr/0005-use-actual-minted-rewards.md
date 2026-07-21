# 奖励代币销毁只使用实际铸造激励

治理奖励代币销毁和行动奖励代币销毁的额度只来源于已经实际领取铸造的奖励。基础行动按 ExtensionCenter 登记结果读取 LOVE20Mint；扩展行动读取受支持扩展保存的 claimant `mintReward`。扩展内部向 recipients 的二次分配不拆分 Burn 额度，也不产生 recipient 独立额度。尚未领取的理论奖励不能计入额度；超过当前销毁轮次的额度不再补发。
