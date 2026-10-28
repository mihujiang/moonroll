///|
/// 回滚会话：持有模拟器、双玩家输入环、窗口内快照，负责预测、确认与重放。
///
/// 帧号从 1 开始，0 表示初始状态。`frame` 是本地已模拟到的最新帧，
/// `confirmed` 是双方输入都已到达的最大帧（其之前的帧不会再回滚）。
///
/// 典型循环（每帧一次）：
/// 1. 本地推进：`advance(本地输入)`
/// 2. 把 `player_input(本地玩家, 帧)` 发给对端
/// 3. 收到对端输入时调用 `receive(帧, 输入)`
pub struct Session[T] {
  sim : T
  local_id : Int32
  window : Int32
  mut frame : Int32
  mut confirmed : Int32
  mut rollbacks : Int32
  p0 : @input.InputRing
  p1 : @input.InputRing
  snaps : SnapshotRing
  hashes : HashRing
}

///|
/// 默认回滚窗口（帧）。
pub const DEFAULT_WINDOW : Int32 = 64

///|
pub fn[T : Sim] Session::new(sim : T, local_id : Int32) -> Session[T] {
  Session::with_window(sim, local_id, DEFAULT_WINDOW)
}

///|
/// `local_id` 是本地玩家索引（0 或 1），`window` 是可回滚的最大帧数。
pub fn[T : Sim] Session::with_window(
  sim : T,
  local_id : Int32,
  window : Int32,
) -> Session[T] {
  let w = if window < 1 { 1 } else { window }
  let cap = w * 2 + 2
  let snaps = SnapshotRing::new(cap)
  let hashes = HashRing::new(cap)
  // 帧 0 是初始状态，必须留下快照，否则第一次回滚没有可恢复点
  snaps.set(0, sim.save())
  hashes.set(0, sim.hash())
  {
    sim,
    local_id: if local_id == 0 {
      0
    } else {
      1
    },
    window: w,
    frame: 0,
    confirmed: 0,
    rollbacks: 0,
    p0: @input.InputRing::new(cap),
    p1: @input.InputRing::new(cap),
    snaps,
    hashes,
  }
}

///|
pub fn[T] Session::local_player(self : Session[T]) -> Int32 {
  self.local_id
}

///|
pub fn[T] Session::frame(self : Session[T]) -> Int32 {
  self.frame
}

///|
pub fn[T] Session::confirmed(self : Session[T]) -> Int32 {
  self.confirmed
}

///|
pub fn[T] Session::rollbacks(self : Session[T]) -> Int32 {
  self.rollbacks
}

///|
pub fn[T : Sim] Session::hash(self : Session[T]) -> UInt64 {
  self.sim.hash()
}

///|
/// 取某一帧模拟后的状态哈希（超出快照窗口、从未模拟过时为 `None`）。
///
/// 两端在同一个**已确认帧**上比对这个哈希，才是「世界是否一致」的判据；
/// 比对当前帧会把两端各自不同的预测误判成分叉。
pub fn[T] Session::hash_at(self : Session[T], frame : Int32) -> UInt64? {
  self.hashes.get(frame)
}

///|
/// 取某个玩家在某一帧的已知输入（未到达或已被覆盖时为 `None`）。
pub fn[T] Session::player_input(
  self : Session[T],
  player : Int32,
  frame : Int32,
) -> UInt64? {
  if player == 0 {
    self.p0.get(frame)
  } else {
    self.p1.get(frame)
  }
}

///|
/// 本地推进一帧，返回新的帧号。
pub fn[T : Sim] Session::advance(
  self : Session[T],
  local_input : UInt64,
) -> Int32 {
  self.frame = self.frame + 1
  if self.local_id == 0 {
    self.p0.set(self.frame, local_input)
  } else {
    self.p1.set(self.frame, local_input)
  }
  self.simulate(self.frame)
  self.update_confirmed()
  self.frame
}

///|
/// 收到对端在 `frame` 帧的输入。
///
/// 若该帧已模拟过（`frame <= self.frame`）且尚未确认，就从 `frame - 1`
/// 的快照恢复并重放 `frame..self.frame`，即发生一次回滚。
pub fn[T : Sim] Session::receive(
  self : Session[T],
  frame : Int32,
  remote_input : UInt64,
) -> Unit {
  if frame < 1 || frame > self.frame + self.window {
    return
  }
  if frame < self.frame - self.window * 2 {
    return
  }
  if self.local_id == 0 {
    self.p1.set(frame, remote_input)
  } else {
    self.p0.set(frame, remote_input)
  }
  if frame <= self.frame && frame > self.confirmed {
    self.replay_from(frame - 1)
  }
  self.update_confirmed()
}

///|
/// 预测某玩家在 `frame` 的输入：取窗口内最近一次已知值，都没有则 0。
fn[T] Session::predict(
  self : Session[T],
  player : Int32,
  frame : Int32,
) -> UInt64 {
  let ring = if player == 0 { self.p0 } else { self.p1 }
  let floor = if frame - self.window < 0 { 0 } else { frame - self.window }
  let mut f = frame - 1
  while f >= floor {
    match ring.get(f) {
      Some(v) => return v
      None => ()
    }
    f = f - 1
  }
  0UL
}

///|
fn[T] Session::inputs(self : Session[T], frame : Int32) -> (UInt64, UInt64) {
  let a = match self.p0.get(frame) {
    Some(v) => v
    None => self.predict(0, frame)
  }
  let b = match self.p1.get(frame) {
    Some(v) => v
    None => self.predict(1, frame)
  }
  (a, b)
}

///|
fn[T : Sim] Session::simulate(self : Session[T], frame : Int32) -> Unit {
  let (a, b) = self.inputs(frame)
  self.sim.step(a, b)
  self.snaps.set(frame, self.sim.save())
  // 重放时也走这里，历史哈希因此始终对应最后一次模拟的结果。
  self.hashes.set(frame, self.sim.hash())
}

///|
fn[T : Sim] Session::replay_from(self : Session[T], base : Int32) -> Unit {
  if base < self.frame - self.window {
    return
  }
  match self.snaps.get(base) {
    None => ()
    Some(bytes) => {
      self.sim.restore(bytes)
      let mut f = base + 1
      while f <= self.frame {
        self.simulate(f)
        f = f + 1
      }
      self.rollbacks = self.rollbacks + 1
    }
  }
}

///|
fn[T] Session::update_confirmed(self : Session[T]) -> Unit {
  let mut c = self.confirmed
  while c < self.frame && self.p0.has(c + 1) && self.p1.has(c + 1) {
    c = c + 1
  }
  self.confirmed = c
}
