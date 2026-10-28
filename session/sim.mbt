///|
/// 接入协议：任何可确定性模拟的系统实现这 3 个方法即可接入回滚。
///
/// - `save`：把当前状态编码成字节快照，必须完整
/// - `restore`：从快照恢复，必须与 `save` 严格互逆
/// - `step_players`：推进一帧，`inputs[i]` 是第 i 个玩家本帧的输入位图，
///   长度等于 `Session` 的玩家数（两人局就是 `[p0, p1]`）
/// - `hash`：状态哈希，用于两端比对，不一致即 desync
///
/// 这几个方法都必须是纯确定性的：同样的输入序列必须得到同样的状态与哈希。
/// 这是回滚同步的唯一硬约束，库无法替你检查，但 `Session` 会对每帧调用
/// `save`，所以「忘了恢复某个字段」会立即表现为哈希不一致。
///
/// `step_players` 收到的数组是会话内部复用的缓冲区，实现里只读不存：
/// 需要留用就把元素拷贝出来。
pub(open) trait Sim {
  fn save(Self) -> Bytes
  fn restore(Self, Bytes) -> Unit
  fn step_players(Self, Array[UInt64]) -> Unit
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
