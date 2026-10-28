///|
/// 回滚会话：持有模拟器、每个玩家一条输入环、窗口内快照，负责预测、确认与重放。
///
/// 帧号从 1 开始，0 表示初始状态。`frame` 是本地已模拟到的最新帧，
/// `confirmed` 是所有**在线**玩家输入都已到达的最大帧（其之前的帧不会再回滚）。
///
/// 典型循环（每帧一次）：
/// 1. 本地推进：`advance(本地输入)`
/// 2. 把 `player_input(本地玩家, 帧)` 发给其他玩家
/// 3. 收到某玩家输入时调用 `receive_from(玩家, 帧, 输入)`
/// 4. 有人掉线时调用 `set_player_active(玩家, false)`，并把同样的决定同步给全房
///
/// 玩家数在构造时固定，1..`MAX_PLAYERS`（8）人；双人局可以用更短的
/// `receive(帧, 输入)`，它会自动推断对端是另一个玩家。
pub struct Session[T] {
  sim : T
  local_id : Int32
  num_players : Int32
  window : Int32
  mut frame : Int32
  mut confirmed : Int32
  mut rollbacks : Int32
  /// 累计重放过的帧数（`回滚次数 × 平均深度`）。
  mut replayed : Int64
  /// 单次回滚重放过的最大帧数，用来观察链路最坏情况。
  mut max_depth : Int32
  /// 每个玩家一条输入环，按玩家索引排列。
  rings : Array[@input.InputRing]
  /// 每个玩家从帧 1 开始「连续收到」了到哪一帧。
  ///
  /// 掉线期间该玩家不会有输入到达，重连时把指针直接抬到当前确认帧，
  /// 这样中间的空洞不会把确认帧永久卡住。
  cont : Array[Int32]
  /// 每个玩家是否在线。掉线的玩家保留槽位（模拟器仍然需要 N 路输入），
  /// 但不再参与确认帧的推进。
  active : Array[Bool]
  /// 每个对端最近一次**声明的确认帧**（来自它的 `Confirm` 包）。
  ///
  /// 只用于算「重新发送从哪里开始」：对方已经确认过的帧不必再发。
  /// 丢了也不会错，只会多发几帧。
  heard : Array[Int32]
  /// 每帧复用的一张输入表，`inputs[i]` 是第 i 个玩家本帧的输入。
  buf : Array[UInt64]
  snaps : SnapshotRing
  hashes : HashRing
}

///|
/// 默认回滚窗口（帧）。
pub const DEFAULT_WINDOW : Int32 = 64

///|
/// 单局支持的最大玩家数，与协议解码里的上限保持一致。
pub const MAX_PLAYERS : Int32 = 8

///|
/// 双人局会话（等价于 `with_players(sim, 2, local_id, DEFAULT_WINDOW)`）。
pub fn[T : Sim] Session::new(sim : T, local_id : Int32) -> Session[T] {
  Session::with_players(sim, 2, local_id, DEFAULT_WINDOW)
}

///|
/// 双人局会话，指定回滚窗口。
pub fn[T : Sim] Session::with_window(
  sim : T,
  local_id : Int32,
  window : Int32,
) -> Session[T] {
  Session::with_players(sim, 2, local_id, window)
}

///|
/// `num_players` 是这一局固定的人数（1..8），`local_id` 是本地玩家索引，
/// `window` 是可回滚的最大帧数。
pub fn[T : Sim] Session::with_players(
  sim : T,
  num_players : Int32,
  local_id : Int32,
  window : Int32,
) -> Session[T] {
  let n = if num_players < 1 {
    1
  } else if num_players > MAX_PLAYERS {
    MAX_PLAYERS
  } else {
    num_players
  }
  let w = if window < 1 { 1 } else { window }
  let cap = w * 2 + 2
  let rings : Array[@input.InputRing] = []
  let mut i = 0
  while i < n {
    rings.push(@input.InputRing::new(cap))
    i = i + 1
  }
  let cont : Array[Int32] = []
  let active : Array[Bool] = []
  let heard : Array[Int32] = []
  let mut k = 0
  while k < n {
    cont.push(0)
    active.push(true)
    heard.push(0)
    k = k + 1
  }
  let snaps = SnapshotRing::new(cap)
  let hashes = HashRing::new(cap)
  // 帧 0 是初始状态，必须留下快照，否则第一次回滚没有可恢复点
  snaps.set(0, sim.save())
  hashes.set(0, sim.hash())
  {
    sim,
    local_id: if local_id < 0 {
      0
    } else if local_id >= n {
      n - 1
    } else {
      local_id
    },
    num_players: n,
    window: w,
    frame: 0,
    confirmed: 0,
    rollbacks: 0,
    replayed: 0L,
    max_depth: 0,
    rings,
    cont,
    active,
    heard,
    buf: Array::make(n, 0UL),
    snaps,
    hashes,
  }
}

///|
pub fn[T] Session::local_player(self : Session[T]) -> Int32 {
  self.local_id
}

///|
/// 这一局的玩家数。
pub fn[T] Session::player_count(self : Session[T]) -> Int32 {
  self.num_players
}

///|
/// 某个玩家是否在线。掉线的玩家仍然占一个输入槽位（模拟器的输入表长度
/// 不变），但不再参与确认帧的推进。
pub fn[T] Session::is_active(self : Session[T], player : Int32) -> Bool {
  if player < 0 || player >= self.num_players {
    false
  } else {
    self.active[player]
  }
}

///|
/// 当前在线玩家数（未掉线的人数）。
pub fn[T] Session::online_count(self : Session[T]) -> Int32 {
  let mut n = 0
  let mut i = 0
  while i < self.num_players {
    if self.active[i] {
      n = n + 1
    }
    i = i + 1
  }
  n
}

///|
/// 声明玩家 `player` 上线 / 掉线，返回状态是否真的改变。
///
/// 「什么时候算掉线」是上层的策略（超时阈值、房主踢人），本库不替你决定；
/// 它只提供一个同步点：**所有会话必须用相同的在线集合推进**，否则确认帧会
/// 各不相同。掉线期间该玩家的输入退化为「窗口内最近一次已知值、否则 0」，
/// 这对所有对等体都是同一套确定性规则，因此不会引入分叉。
///
/// 两种调用会被安全忽略：把本地玩家标成掉线；把最后一名在线玩家标成掉线。
pub fn[T] Session::set_player_active(
  self : Session[T],
  player : Int32,
  on : Bool,
) -> Bool {
  if player < 0 || player >= self.num_players {
    return false
  }
  if self.active[player] == on {
    return false
  }
  if player == self.local_id && !on {
    return false
  }
  if !on && self.online_count() <= 1 {
    return false
  }
  self.active[player] = on
  if on && self.cont[player] < self.confirmed {
    // 掉线期间的输入永远不会补到齐：把连续指针抬到当前确认帧，
    // 该玩家从这之后重新贡献输入，确认帧不会因此回退。
    self.cont[player] = self.confirmed
  }
  self.update_confirmed()
  true
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
/// 累计重放过的帧数。
///
/// 回滚次数只说明「重放了几次」，真正影响 CPU 的是重放深度；
/// 链路延迟越大，这个数相对帧数涨得越快。
pub fn[T] Session::replayed(self : Session[T]) -> Int64 {
  self.replayed
}

///|
/// 单次回滚里重放过的最大帧数（最坏情况的深度）。
pub fn[T] Session::max_rollback_depth(self : Session[T]) -> Int32 {
  self.max_depth
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
/// 取某个玩家在某一帧的已知输入（未到达、已被覆盖或玩家索引越界时为 `None`）。
pub fn[T] Session::player_input(
  self : Session[T],
  player : Int32,
  frame : Int32,
) -> UInt64? {
  if player < 0 || player >= self.num_players {
    return None
  }
  self.rings[player].get(frame)
}

///|
/// 本地推进一帧，返回新的帧号。
pub fn[T : Sim] Session::advance(
  self : Session[T],
  local_input : UInt64,
) -> Int32 {
  self.frame = self.frame + 1
  self.rings[self.local_id].set(self.frame, local_input)
  self.cont[self.local_id] = self.frame
  self.simulate(self.frame)
  self.update_confirmed()
  self.frame
}

///|
/// 双人局的便捷入口：收到「对端」在 `frame` 帧的输入。
///
/// 3 人以上请用 `receive_from`——「对端」在 N 人局里没有唯一含义，
/// 这里会直接忽略，避免调用方悄悄写错。
pub fn[T : Sim] Session::receive(
  self : Session[T],
  frame : Int32,
  remote_input : UInt64,
) -> Unit {
  if self.num_players != 2 {
    return
  }
  self.receive_from(1 - self.local_id, frame, remote_input)
}

///|
/// 收到对端 `player` 的 `Confirm` 包，记下它已确认到 `frame`。
///
/// 这个水位只用来算「重发从哪一帧开始」：对方已经确认过的帧不用再发。
/// 记录本身不影响确认帧的推进（那由 `receive_from` 里的连续指针负责），
/// 所以迟到的、重复的、乱序的 `Confirm` 都是安全的。
///
/// 帧号会被钳到本地已模拟帧：对端不可能确认我们还没算出来的帧。
pub fn[T] Session::receive_confirm(
  self : Session[T],
  player : Int32,
  frame : Int32,
) -> Unit {
  if player < 0 || player >= self.num_players {
    return
  }
  if player == self.local_id {
    return
  }
  let f = if frame > self.frame { self.frame } else { frame }
  if f <= self.heard[player] {
    return
  }
  self.heard[player] = f
}

///|
/// 对端 `player` 最近声明的确认帧（从未收到过 `Confirm` 时为 0）。
///
/// 发送端可以据此把「重发最近 8 帧」换成「重发对方还没确认的那一段」：
/// 链路正常时这段只有延迟那么大，丢包时水位停住、区间自动变长，
/// 于是被丢的输入仍然会被补上。
pub fn[T] Session::peer_confirmed(self : Session[T], player : Int32) -> Int32 {
  if player < 0 || player >= self.num_players {
    return 0
  }
  self.heard[player]
}

///|
/// 收到玩家 `player` 在 `frame` 帧的输入。
///
/// 若该帧已模拟过（`frame <= self.frame`）且尚未确认，就从 `frame - 1`
/// 的快照恢复并重放 `frame..self.frame`，即发生一次回滚。
pub fn[T : Sim] Session::receive_from(
  self : Session[T],
  player : Int32,
  frame : Int32,
  remote_input : UInt64,
) -> Unit {
  if player < 0 || player >= self.num_players {
    return
  }
  if frame < 1 || frame > self.frame + self.window {
    return
  }
  if frame < self.frame - self.window * 2 {
    return
  }
  self.rings[player].set(frame, remote_input)
  let mut c = self.cont[player]
  while self.rings[player].has(c + 1) {
    c = c + 1
  }
  self.cont[player] = c
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
  let ring = self.rings[player]
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
/// 把某一帧的完整输入表填进复用缓冲区：已知的就用已知值，缺失的做预测。
fn[T] Session::fill_inputs(self : Session[T], frame : Int32) -> Unit {
  let mut i = 0
  while i < self.num_players {
    self.buf[i] = match self.rings[i].get(frame) {
      Some(v) => v
      None => self.predict(i, frame)
    }
    i = i + 1
  }
}

///|
fn[T : Sim] Session::simulate(self : Session[T], frame : Int32) -> Unit {
  self.fill_inputs(frame)
  self.sim.step_players(self.buf)
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
      let depth = self.frame - base
      self.replayed = self.replayed + depth.to_int64()
      if depth > self.max_depth {
        self.max_depth = depth
      }
    }
  }
}

///|
/// 确认帧 = 所有**在线**玩家都连续收到的最高帧（不超过本地已模拟帧）。
///
/// 掉线的玩家被排除在外——否则一个人不再发包，全房确认帧就永久停住，
/// 回滚窗口用尽后所有人退化成「接受分叉」。只前进不后退，重连也不会让
/// 确认帧回退。
fn[T] Session::update_confirmed(self : Session[T]) -> Unit {
  let mut c = self.frame
  let mut i = 0
  while i < self.num_players {
    if self.active[i] && self.cont[i] < c {
      c = self.cont[i]
    }
    i = i + 1
  }
  if c > self.confirmed {
    self.confirmed = c
  }
}
