# 使用双哈希叶子和排序 Merkle 节点

来源快照叶子使用 `keccak256(bytes.concat(keccak256(abi.encode(account, share))))`，每对树节点排序后再哈希，单独的尾节点直接提升。双哈希避免叶子编码被误解释为内部节点，排序节点允许使用 OpenZeppelin `MerkleProof` 验证；快照生成器与合约必须永久保持这一编码一致。
