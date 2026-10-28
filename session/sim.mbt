///|
/// 接入协议：任何可确定性模拟的系统实现这 4 个方法即可接入回滚。
///
/// - `save`：把当前状态编码成字节快照，必须完整
/// - `restore`：从快照恢复，必须与 `save` 严格互逆
/// - `step`：推进一帧，`p0` / `p1` 是两个玩家按玩家索引排列的输入位图
/// - `hash`：状态哈希，用于两端比对，不一致即 desync
///
/// 四个方法都必须是纯确定性的：同样的输入序列必须得到同样的状态与哈希。
/// 这是回滚同步的唯一硬约束，库无法替你检查，但 `Session` 会对每帧调用
/// `save`，所以「忘了恢复某个字段」会立即表现为哈希不一致。
pub(open) trait Sim {
  fn save(Self) -> Bytes
  fn restore(Self, Bytes) -> Unit
  fn step(Self, UInt64, UInt64) -> Unit
  fn hash(Self) -> UInt64
}

///|
/// 把一组整数折叠成 FNV-1a 64 哈希，供 `Sim::hash` 复用。
///
/// ```moonbit nocheck
/// fn hash(self) -> UInt64 {
///   hash_state([self.x.raw(), self.y.raw()])
/// }
/// ```
pub fn hash_state(parts : ArrayView[Int64]) -> UInt64 {
  let d = @digest.Digest::new()
  for p in parts {
    d.feed_i64(p)
  }
  d.finish()
}
