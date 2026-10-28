///|
/// 帧号 -> 快照字节的环形缓冲。容量固定、按帧号取模寻址，
/// 槽位记录真实帧号，被覆盖后旧帧查询返回 `None`。
pub struct SnapshotRing {
  capacity : Int32
  frames : Array[Int32]
  items : Array[Bytes?]
}

///|
pub fn SnapshotRing::new(capacity : Int32) -> SnapshotRing {
  let cap = if capacity < 1 { 1 } else { capacity }
  {
    capacity: cap,
    frames: Array::make(cap, -1),
    items: Array::make(cap, None),
  }
}

///|
pub fn SnapshotRing::capacity(self : SnapshotRing) -> Int32 {
  self.capacity
}

///|
fn SnapshotRing::slot(self : SnapshotRing, frame : Int32) -> Int32 {
  let m = frame % self.capacity
  if m < 0 {
    m + self.capacity
  } else {
    m
  }
}

///|
pub fn SnapshotRing::set(
  self : SnapshotRing,
  frame : Int32,
  bytes : Bytes,
) -> Unit {
  let i = self.slot(frame)
  self.frames[i] = frame
  self.items[i] = Some(bytes)
}

///|
pub fn SnapshotRing::get(self : SnapshotRing, frame : Int32) -> Bytes? {
  let i = self.slot(frame)
  if self.frames[i] == frame {
    self.items[i]
  } else {
    None
  }
}

///|
/// 帧号 -> 状态哈希的环形缓冲。
///
/// 快照字节只用于重放，比较两端「已确认帧」的世界是否一致需要历史哈希；
/// 只比较当前帧会把两端各自不同的预测误判成分叉。
pub struct HashRing {
  capacity : Int32
  frames : Array[Int32]
  items : Array[UInt64]
}

///|
pub fn HashRing::new(capacity : Int32) -> HashRing {
  let cap = if capacity < 1 { 1 } else { capacity }
  { capacity: cap, frames: Array::make(cap, -1), items: Array::make(cap, 0UL), }
}

///|
fn HashRing::slot(self : HashRing, frame : Int32) -> Int32 {
  let m = frame % self.capacity
  if m < 0 {
    m + self.capacity
  } else {
    m
  }
}

///|
pub fn HashRing::set(self : HashRing, frame : Int32, hash : UInt64) -> Unit {
  let i = self.slot(frame)
  self.frames[i] = frame
  self.items[i] = hash
}

///|
pub fn HashRing::get(self : HashRing, frame : Int32) -> UInt64? {
  let i = self.slot(frame)
  if self.frames[i] == frame {
    Some(self.items[i])
  } else {
    None
  }
}
