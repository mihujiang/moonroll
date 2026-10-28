///|
/// 示例共用的小世界，支持 1..8 个玩家。
///
/// 每个玩家各有 3 个按键，状态是单个 64 位整数，每帧把所有人的输入按下标
/// 混进同一个数：只要漏掉一帧输入、或者重放顺序不对，状态就会立刻分叉。
/// 示例里看到的回滚与分叉检测因此是真实发生的，不是摆拍。
pub struct Scene {
  mut x : UInt64
}

///|
pub fn Scene::new() -> Scene {
  // 选个非零初值，避免「全 0 状态 + 全 0 输入」把问题掩盖掉。
  { x: 0x243F6A8885A308D3UL, }
}

///|
pub fn Scene::state(self : Scene) -> UInt64 {
  self.x
}

///|
pub impl @session.Sim for Scene with fn save(self) -> Bytes {
  Bytes::makei(8, fn(i) { ((self.x >> (i * 8)) & 0xFFUL).to_int().to_byte() })
}

///|
pub impl @session.Sim for Scene with fn restore(self, bytes : Bytes) -> Unit {
  let mut x = 0UL
  let mut i = 0
  while i < 8 {
    x = x | (bytes[i].to_int().to_uint64() << (i * 8))
    i = i + 1
  }
  self.x = x
}

///|
pub impl @session.Sim for Scene with fn step_players(
  self,
  inputs : Array[UInt64],
) -> Unit {
  // 每个玩家的输入乘一个互不相同的常数再加进状态，最后整体做一次乘法与
  // xor-shift：任何一路缺失都会扩散到全部位，玩家之间也不会互相抵消。
  let mut mixed = self.x
  let mut i = 0
  for bits in inputs {
    let salt = 0x9E3779B97F4A7C15UL >> (i * 8)
    mixed = mixed + (bits & 7UL) * salt
    i = i + 1
  }
  let m = mixed * 0xBF58476D1CE4E5B9UL + 0x94D049BB133111EBUL
  self.x = m ^ (m >> 29)
}

///|
pub impl @session.Sim for Scene with fn hash(self) -> UInt64 {
  @digest.hash_u64(self.x)
}

///|
/// 显式声明「把 `Sim` 的方法提升为 `Scene` 的方法」，消除 W0079。
pub extend Scene with @session.Sim::{save, restore, step_players, hash}

///|
/// 确定性的「玩家操作脚本」：每 6 帧换一次按键组合，各玩家相位错开。
///
/// 示例不接键盘，是为了让输出可以逐位复现——`moon run` 两次结果必须一样。
pub fn scripted_input(frame : Int32, player : Int32) -> UInt64 {
  let phase = frame / 6 + player * 3
  match phase % 5 {
    0 => 0b001UL
    1 => 0b011UL
    2 => 0b111UL
    3 => 0b100UL
    _ => 0b010UL
  }
}
