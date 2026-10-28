///|
/// 一条确定性链路的参数。时间单位是逻辑帧（60fps 下 1 帧 ≈ 16.7ms），
/// `loss` / `reorder` 是百分比。
pub struct LinkSpec {
  delay : Int32
  jitter : Int32
  loss : Int32
  reorder : Int32
}

///|
pub fn LinkSpec::new(
  delay : Int32,
  jitter : Int32,
  loss : Int32,
  reorder : Int32,
) -> LinkSpec {
  { delay, jitter, loss, reorder, }
}

///|
/// 一条链路的运行结果。
pub struct LinkStats {
  /// 两端各自的确认帧。
  mut p0_confirmed : Int32
  mut p1_confirmed : Int32
  /// 两端各自发生的回滚次数。
  mut p0_rollbacks : Int32
  mut p1_rollbacks : Int32
  /// 收到的 `Checksum` 帧里与本端历史哈希不一致的次数。
  mut mismatches : Int32
  /// 首个「两端都已确认、但哈希不同」的帧；0 表示没有分叉。
  mut first_divergence : Int32
  /// 分叉帧上两端各自的状态哈希，方便对照排查。
  mut hash0 : UInt64
  mut hash1 : UInt64
  /// P0 累计重放过的帧数。
  mut replayed_p0 : Int64
  /// 单次回滚的最大深度。
  mut max_depth : Int32
  /// 链路丢掉的包数。
  mut dropped : Int32
  /// 两端在共同确认帧上的状态是否一致。
  mut synced : Bool
}

///|
/// 把一条链路上的字节解成消息并投递，返回本次发现的校验失配数。
pub fn apply(payload : Bytes, s : @session.Session[Scene]) -> Int32 {
  let mut bad = 0
  for msg in @protocol.decode_batch(payload) {
    match msg {
      @protocol.Input(x) => {
        let mut i = 0
        for bits in x.inputs {
          s.receive_from(x.player + i, x.frame, bits)
          i = i + 1
        }
      }
      @protocol.Checksum(c) =>
        match s.hash_at(c.frame) {
          Some(mine) => if mine != c.hash { bad = bad + 1 }
          None => ()
        }
      _ => ()
    }
  }
  bad
}

///|
/// 每帧的包：[最近 `resend` 帧输入] + [确认帧] + [校验和帧]。
fn pack(
  s : @session.Session[Scene],
  player : Int32,
  upto : Int32,
  resend : Int32,
  bad_frame : Int32,
) -> Bytes {
  let msgs : Array[@protocol.Message] = []
  let mut m = upto - resend + 1
  if m < 1 {
    m = 1
  }
  while m <= upto {
    let mut input = scripted_input(m, player)
    if m == bad_frame {
      // 真实事故：本地执行了 A，网线上发出去的却是 B（序列化 / 版本 bug）。
      // 这种偏差不会被本端回滚洗掉，只能靠两端的确认帧哈希发现。
      input = input ^ 1UL
    }
    msgs.push(
      @protocol.Message::Input(
        @protocol.InputFrame::new_from(player, m, [input]),
      ),
    )
    m = m + 1
  }
  msgs.push(
    @protocol.Message::Confirm(@protocol.ConfirmFrame::new(s.confirmed())),
  )
  match s.hash_at(s.confirmed()) {
    Some(h) =>
      msgs.push(
        @protocol.Message::Checksum(
          @protocol.ChecksumFrame::new(s.confirmed(), h),
        ),
      )
    None => ()
  }
  @protocol.encode_batch(msgs)
}

///|
/// 跑一局两个对等体的对局，返回统计结果。
///
/// `corrupt_frame` 不为 0 时，P1 在那一帧「本地执行 A、发出去的是 B」——
/// 用来验证分叉检测确实能在正确的帧上报出来。
///
/// 之所以不去直接改内存里的状态：回滚会从快照恢复并重放，任何没有被
/// 记录进输入流的改动都会被洗掉；只有输入流本身出错才会留下痕迹。
pub fn run_link(
  spec : LinkSpec,
  frames : Int32,
  corrupt_frame : Int32,
) -> LinkStats {
  let pa = @session.Session::with_window(Scene::new(), 0, 128)
  let pb = @session.Session::with_window(Scene::new(), 1, 128)
  let net_ab = @sim_net.NetSim::new(
    @sim_net.Link::new(
      spec.delay,
      spec.jitter,
      spec.loss,
      spec.reorder,
      20261028UL,
    ),
  )
  let net_ba = @sim_net.NetSim::new(
    @sim_net.Link::new(spec.delay, spec.jitter, spec.loss, spec.reorder, 777UL),
  )
  let stats : LinkStats = {
    p0_confirmed: 0,
    p1_confirmed: 0,
    p0_rollbacks: 0,
    p1_rollbacks: 0,
    mismatches: 0,
    first_divergence: 0,
    hash0: 0UL,
    hash1: 0UL,
    replayed_p0: 0L,
    max_depth: 0,
    dropped: 0,
    synced: false,
  }
  let mut checked = 0
  let mut f = 0
  while f < frames {
    f = f + 1
    ignore(pa.advance(scripted_input(f, 0)))
    ignore(pb.advance(scripted_input(f, 1)))
    net_ab.send(f, pack(pa, 0, f, 8, 0))
    net_ba.send(f, pack(pb, 1, f, 8, corrupt_frame))
    for payload in net_ab.recv(f) {
      stats.mismatches = stats.mismatches + apply(payload, pb)
    }
    for payload in net_ba.recv(f) {
      stats.mismatches = stats.mismatches + apply(payload, pa)
    }
    check_confirmed(pa, pb, stats, checked)
    checked = min_confirm(pa, pb)
  }
  // 收尾：最后一轮包还在路上。
  let mut t = frames
  while t < frames + 80 {
    t = t + 1
    for payload in net_ab.recv(t) {
      stats.mismatches = stats.mismatches + apply(payload, pb)
    }
    for payload in net_ba.recv(t) {
      stats.mismatches = stats.mismatches + apply(payload, pa)
    }
    check_confirmed(pa, pb, stats, checked)
    checked = min_confirm(pa, pb)
  }
  stats.p0_confirmed = pa.confirmed()
  stats.p1_confirmed = pb.confirmed()
  stats.p0_rollbacks = pa.rollbacks()
  stats.p1_rollbacks = pb.rollbacks()
  stats.replayed_p0 = pa.replayed()
  stats.max_depth = pa.max_rollback_depth()
  stats.dropped = net_ab.dropped() + net_ba.dropped()
  stats.synced = stats.first_divergence == 0
  stats
}

///|
fn min_confirm(
  pa : @session.Session[Scene],
  pb : @session.Session[Scene],
) -> Int32 {
  let a = pa.confirmed()
  let b = pb.confirmed()
  if a < b {
    a
  } else {
    b
  }
}

///|
/// 比对两端在共同确认帧上的历史哈希，记录首个分叉帧。
fn check_confirmed(
  pa : @session.Session[Scene],
  pb : @session.Session[Scene],
  stats : LinkStats,
  checked : Int32,
) -> Unit {
  let c = min_confirm(pa, pb)
  let mut f = checked + 1
  while f <= c {
    match (pa.hash_at(f), pb.hash_at(f)) {
      (Some(x), Some(y)) =>
        if x != y && stats.first_divergence == 0 {
          stats.first_divergence = f
          stats.hash0 = x
          stats.hash1 = y
        }
      _ => ()
    }
    f = f + 1
  }
}
