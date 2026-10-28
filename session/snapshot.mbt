///|
/// 帧号 -> 快照字节的环形缓冲。容量固定、按帧号取模寻址，
/// 槽位记录真实帧号，被覆盖后旧帧查询返回 `None`。
pub struct SnapshotRing {
  capacity : Int
  frames : Array[Int]
  items : Array[Bytes?]
}

///|
pub fn SnapshotRing::new(capacity : Int) -> SnapshotRing {
  let cap = if capacity < 1 { 1 } else { capacity }
  { capacity: cap, frames: Array::make(cap, -1), items: Array::make(cap, None) }
}

///|
pub fn SnapshotRing::capacity(self : SnapshotRing) -> Int {
  self.capacity
}

///|
fn SnapshotRing::slot(self : SnapshotRing, frame : Int) -> Int {
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
  frame : Int,
  bytes : Bytes,
) -> Unit {
  let i = self.slot(frame)
  self.frames[i] = frame
  self.items[i] = Some(bytes)
}

///|
pub fn SnapshotRing::get(self : SnapshotRing, frame : Int) -> Bytes? {
  let i = self.slot(frame)
  if self.frames[i] == frame {
    self.items[i]
  } else {
    None
  }
}
