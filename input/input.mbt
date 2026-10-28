///|
/// 固定容量的输入环形缓冲：帧号 -> 输入位图。
///
/// 回滚需要按帧随机存取历史输入，又不能让历史无限增长，
/// 因此用「帧号取模定槽位 + 槽位记录真实帧号」的方式实现：
/// 覆盖写字面量级的常数开销，且不需要链表或动态扩容。
///
/// 输入用 `UInt64` 位图表示（64 个按键 / 摇杆量化位），
/// 一帧一个玩家 8 字节，便于后续直接序列化进协议包。
pub struct InputRing {
  capacity : Int
  frames : Array[Int]
  bits : Array[UInt64]
}

///|
/// 创建缓冲，`capacity` 至少为 1；实际应设置到回滚窗口的两倍以上。
pub fn InputRing::new(capacity : Int) -> InputRing {
  let cap = if capacity < 1 { 1 } else { capacity }
  { capacity: cap, frames: Array::make(cap, -1), bits: Array::make(cap, 0UL) }
}

///|
/// 环容量。
pub fn InputRing::capacity(self : InputRing) -> Int {
  self.capacity
}

///|
fn InputRing::slot(self : InputRing, frame : Int) -> Int {
  let m = frame % self.capacity
  if m < 0 {
    m + self.capacity
  } else {
    m
  }
}

///|
/// 写入某帧输入，覆盖同槽位的旧帧。
pub fn InputRing::set(self : InputRing, frame : Int, bits : UInt64) -> Unit {
  let i = self.slot(frame)
  self.frames[i] = frame
  self.bits[i] = bits
}

///|
/// 读取某帧输入；未写入或已被覆盖时返回 `None`。
pub fn InputRing::get(self : InputRing, frame : Int) -> UInt64? {
  let i = self.slot(frame)
  if self.frames[i] == frame {
    Some(self.bits[i])
  } else {
    None
  }
}

///|
pub fn InputRing::has(self : InputRing, frame : Int) -> Bool {
  self.get(frame) is Some(_)
}
