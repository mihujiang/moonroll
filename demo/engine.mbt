///|
/// Frames worth of inputs repeated in every packet, so a dropped packet does
/// not strand a frame forever.
const RESEND : Int32 = 8

///|
/// Snapshot window per session, also the maximum rollback depth.
const WINDOW : Int32 = 128

///|
/// Frames the browser runs per second; also the demo's time unit.
pub const FPS : Int32 = 60

///|
/// One two-peer match: two independent physics worlds, two rollback sessions,
/// and the simulated link between them.
priv struct Demo {
  sims : Array[@phys.PhysSim]
  sessions : Array[@session.Session[@phys.PhysSim]]
  inputs : Array[Array[UInt64]]
  net_ab : @sim_net.NetSim
  net_ba : @sim_net.NetSim
  mut frame : Int32
  mut desyncs : Int32
  /// 已经比对过「两端同帧世界哈希」的最高帧，避免重复计数。
  mut checked : Int32
}

///|
fn new_demo(
  delay : Int32,
  jitter : Int32,
  loss : Int32,
  reorder : Int32,
) -> Demo {
  let sims = [@phys.PhysSim::new(), @phys.PhysSim::new()]
  let sessions = [
    @session.Session::with_window(sims[0], 0, WINDOW),
    @session.Session::with_window(sims[1], 1, WINDOW),
  ]
  {
    sims,
    sessions,
    inputs: [[], []],
    net_ab: @sim_net.NetSim::new(
      @sim_net.Link::new(delay, jitter, loss, reorder, 20261028UL),
    ),
    net_ba: @sim_net.NetSim::new(
      @sim_net.Link::new(delay, jitter, loss, reorder, 777UL),
    ),
    frame: 0,
    desyncs: 0,
    checked: 0,
  }
}

///|
fn deliver_into(s : @session.Session[@phys.PhysSim], payload : Bytes) -> Unit {
  for msg in @protocol.decode_batch(payload) {
    match msg {
      @protocol.Input(frame) => apply_remote(s, frame)
      _ => ()
    }
  }
}

///|
fn apply_remote(
  s : @session.Session[@phys.PhysSim],
  frame : @protocol.InputFrame,
) -> Unit {
  if frame.inputs.length() > 0 {
    s.receive(frame.frame, frame.inputs[0])
  }
}

///|
fn Demo::tick(self : Demo, p0 : UInt64, p1 : UInt64) -> Unit {
  self.frame = self.frame + 1
  let f = self.frame
  ignore(self.sessions[0].advance(p0))
  ignore(self.sessions[1].advance(p1))
  self.inputs[0].push(p0)
  self.inputs[1].push(p1)
  let ab : Array[@protocol.Message] = []
  let ba : Array[@protocol.Message] = []
  let mut back = f - RESEND + 1
  if back < 1 {
    back = 1
  }
  let mut m = back
  while m <= f {
    ab.push(
      @protocol.Message::Input(
        @protocol.InputFrame::new(m, [self.inputs[0][m - 1]]),
      ),
    )
    ba.push(
      @protocol.Message::Input(
        @protocol.InputFrame::new(m, [self.inputs[1][m - 1]]),
      ),
    )
    m = m + 1
  }
  self.net_ab.send(f, @protocol.encode_batch(ab))
  self.net_ba.send(f, @protocol.encode_batch(ba))
  for packet in self.net_ab.recv(f) {
    deliver_into(self.sessions[1], packet)
  }
  for packet in self.net_ba.recv(f) {
    deliver_into(self.sessions[0], packet)
  }
  self.check_confirmed()
}

///|
/// 只比对两端都确认过的帧上的世界哈希。
///
/// 两端当前帧的预测输入可以合法地不同（一端的输入还在路上），拿当前
/// 哈希直接比会得到大量假分叉；已确认帧上的输入两端都已知，必须逐位一致。
fn Demo::check_confirmed(self : Demo) -> Unit {
  let c0 = self.sessions[0].confirmed()
  let c1 = self.sessions[1].confirmed()
  let c = if c0 < c1 { c0 } else { c1 }
  let mut f = self.checked + 1
  while f <= c {
    match (self.sessions[0].hash_at(f), self.sessions[1].hash_at(f)) {
      (Some(a), Some(b)) => if a != b { self.desyncs = self.desyncs + 1 }
      _ => ()
    }
    f = f + 1
  }
  if c > self.checked {
    self.checked = c
  }
}

///|
/// Scripted input for the automated self test: bitmaps that walk and jump.
fn scripted(frame : Int32) -> (UInt64, UInt64) {
  let p0 = if frame % 9 < 4 {
    0b011UL
  } else if frame % 13 == 0 {
    0b110UL
  } else {
    0UL
  }
  let p1 = if frame % 11 < 3 { 0b001UL } else { 0UL }
  (p0, p1)
}

///|
let demo : Ref[Demo?] = { val: None, }

///|
fn current() -> Demo {
  match demo.val {
    Some(d) => d
    None => {
      let d = new_demo(12, 3, 0, 10)
      demo.val = Some(d)
      d
    }
  }
}

///|
#export_name("mr_reset")
pub fn mr_reset(
  delay : Int32,
  jitter : Int32,
  loss : Int32,
  reorder : Int32,
) -> Unit {
  demo.val = Some(new_demo(delay, jitter, loss, reorder))
}

///|
#export_name("mr_step")
pub fn mr_step(i0 : Int32, i1 : Int32) -> Unit {
  current().tick(i0.to_uint64() & 0b111UL, i1.to_uint64() & 0b111UL)
}

///|
#export_name("mr_frame")
pub fn mr_frame() -> Int32 {
  current().frame
}

///|
#export_name("mr_confirmed")
pub fn mr_confirmed(player : Int32) -> Int32 {
  let d = current()
  d.sessions[player].confirmed()
}

///|
#export_name("mr_rollbacks")
pub fn mr_rollbacks(player : Int32) -> Int32 {
  let d = current()
  d.sessions[player].rollbacks()
}

///|
#export_name("mr_desync")
pub fn mr_desync() -> Int32 {
  current().desyncs
}

///|
#export_name("mr_synced")
pub fn mr_synced() -> Int32 {
  let d = current()
  if d.sessions[0].hash() == d.sessions[1].hash() {
    1
  } else {
    0
  }
}

///|
#export_name("mr_hash_lo")
pub fn mr_hash_lo(player : Int32) -> Int32 {
  let d = current()
  (d.sessions[player].hash() & 0xFFFFFFFFUL).to_int()
}

///|
#export_name("mr_hash_hi")
pub fn mr_hash_hi(player : Int32) -> Int32 {
  let d = current()
  (d.sessions[player].hash() >> 32).to_int()
}

///|
#export_name("mr_in_flight")
pub fn mr_in_flight() -> Int32 {
  let d = current()
  d.net_ab.in_flight() + d.net_ba.in_flight()
}

///|
#export_name("mr_dropped")
pub fn mr_dropped() -> Int32 {
  let d = current()
  d.net_ab.dropped() + d.net_ba.dropped()
}

///|
#export_name("mr_body_count")
pub fn mr_body_count(player : Int32) -> Int32 {
  current().sims[player].world().body_count()
}

///|
#export_name("mr_body_x")
pub fn mr_body_x(player : Int32, index : Int32) -> Double {
  let world = current().sims[player].world()
  world.body(index).position().x
}

///|
#export_name("mr_body_y")
pub fn mr_body_y(player : Int32, index : Int32) -> Double {
  let world = current().sims[player].world()
  world.body(index).position().y
}

///|
#export_name("mr_body_rotation")
pub fn mr_body_rotation(player : Int32, index : Int32) -> Double {
  let world = current().sims[player].world()
  world.body(index).rotation()
}

///|
#export_name("mr_body_is_static")
pub fn mr_body_is_static(player : Int32, index : Int32) -> Int32 {
  let world = current().sims[player].world()
  if world.body(index).is_static() {
    1
  } else {
    0
  }
}

///|
/// Run the acceptance scenario headless: 200 ms one-way delay + 50 ms jitter,
/// 1800 frames, scripted inputs. Returns 0 when both peers converge.
#export_name("mr_selftest")
pub fn mr_selftest() -> Int32 {
  mr_reset(12, 3, 0, 10)
  let d = current()
  let mut i = 1
  while i <= 1800 {
    let (p0, p1) = scripted(i)
    d.tick(p0, p1)
    i = i + 1
  }
  // 尾部：最后一段输入还在重发队列里，多跑一段让确认追上 1800。
  let mut tail = 0
  while tail < 60 {
    let (p0, p1) = scripted(1800)
    d.tick(p0, p1)
    tail = tail + 1
  }
  let converged = d.sessions[0].confirmed() >= 1800 &&
    d.sessions[1].confirmed() >= 1800 &&
    d.sessions[0].hash() == d.sessions[1].hash() &&
    d.desyncs == 0
  if converged {
    0
  } else {
    1
  }
}
