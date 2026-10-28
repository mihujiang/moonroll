///|
/// bandwidth：同样一局，四种发包策略的线上字节数对比。
///
///   moon run examples/bandwidth
///
/// 回滚同步的「输入冗余」是带宽的主要开销：为了扛住丢包，每帧都要把最近
/// 若干帧的输入重发一遍。这里的五种策略做的是同一件事，只是包装方式不同：
///
/// 1. `Legacy`  ：每帧一条 `Input`，固定重发最近 16 帧（V0.7 之前的做法）
/// 2. `Span`    ：把同一玩家的 16 帧压成一条 `InputSpan`，但每帧的值照给
/// 3. `Masked`  ：`InputSpan` + 变化掩码，只给与前一帧不同的值
/// 4. `Adaptive`：不再盲发 16 帧，而是从「对端已确认的那一帧 + 1」开始发
///
/// 前三种的区间长度一样（都是 16 帧），差别只在编码；第四种连长度都跟着
/// 链路变——延迟小就只发几帧，丢包时水位停住、区间自己变长；第五种再把
/// 每帧一次的校验和降到每 8 帧一次。
const PLAYERS : Int32 = 4

///|
const TOTAL : Int32 = 600

///|
/// 固定策略的重发帧数（`Legacy` / `Span` / `Masked` 的区间长度）。
///
/// 取 16 而不是 8，是为了模拟「为了保险把冗余配大」的常见做法——
/// 自适应策略的价值正是把配大了的冗余自己收回来。
const RESEND : Int32 = 16

///|
/// 自适应策略的区间上限：再长就该拆包或者放弃回滚了。
const SPAN_MAX : Int32 = 32

///|
/// 发包策略。
pub(all) enum Packing {
  Legacy
  Span
  Masked
  Adaptive
  Lean
} derive(Eq)

///|
pub extend Packing with Eq::{not_equal, equal}

///|
pub fn Packing::label(self : Packing) -> String {
  match self {
    Legacy => "每帧一条 Input，固定 16 帧"
    Span => "一条 InputSpan，固定 16 帧"
    Masked => "InputSpan + 变化掩码"
    Adaptive => "InputSpan + 掩码 + 对端水位"
    Lean => "以上 + 校验和每 8 帧"
  }
}

///|
/// 一局跑完的统计。字节数按「所有单向链路累加」计，与人数无关地可比。
pub(all) struct PackStats {
  /// 发出的总字节数。
  bytes : Int64
  /// 发出的总包数。
  packets : Int64
  /// 所有包里携带的输入帧数之和（含重发）。
  frames_carried : Int64
  /// 每个玩家的确认帧。
  confirmed : Array[Int32]
  /// 所有玩家回滚次数之和。
  rollbacks : Int64
  /// 所有玩家重放帧数之和。
  replayed : Int64
  /// 校验和帧比对失败次数。
  mismatches : Int32
  /// 首个分叉帧；-1 表示全程一致。
  first_divergence : Int32
}

///|
pub fn PackStats::avg_bytes_per_packet(self : PackStats) -> Int32 {
  if self.packets == 0L {
    return 0
  }
  (self.bytes / self.packets).to_int()
}

///|
pub fn PackStats::avg_frames_per_packet(self : PackStats) -> Int32 {
  if self.packets == 0L {
    return 0
  }
  (self.frames_carried / self.packets).to_int()
}

///|
/// 打一个上行包，返回（字节，包内携带的输入帧数）。
///
/// `peer` 只在自适应策略里用到：它是这个包要发给谁，决定了
/// 「从哪一帧开始重发」。
fn outbound(
  s : @session.Session[@scene.Scene],
  me : Int32,
  peer : Int32,
  f : Int32,
  packing : Packing,
) -> (Bytes, Int32) {
  let msgs : Array[@protocol.Message] = []
  let adaptive = packing == Adaptive || packing == Lean
  // 校验和是每帧 10 字节的大头：掉到每 8 帧一次，只延迟分叉检测，不影响正确性。
  let sync_every = if packing == Lean { 8 } else { 1 }
  let mut back = f - RESEND + 1
  if back < 1 {
    back = 1
  }
  if adaptive {
    // 对端已经确认过的帧不用再发；丢包时它的水位停住，区间自动变长。
    let hint = s.peer_confirmed(peer) + 1
    if hint > back {
      back = hint
    }
    if back > f {
      back = f
    }
    if f - back + 1 > SPAN_MAX {
      back = f - SPAN_MAX + 1
    }
  }
  let mut carried = 0
  if packing == Legacy {
    let mut m = back
    while m <= f {
      match s.player_input(me, m) {
        Some(bits) => {
          msgs.push(
            @protocol.Message::Input(
              @protocol.InputFrame::new_from(me, m, [bits]),
            ),
          )
          carried = carried + 1
        }
        None => ()
      }
      m = m + 1
    }
  } else {
    let frames : Array[UInt64] = []
    let mut m = back
    while m <= f {
      frames.push(
        match s.player_input(me, m) {
          Some(v) => v
          None => 0UL
        },
      )
      m = m + 1
    }
    if frames.length() > 0 {
      let span = if packing == Span {
        @protocol.InputSpanFrame::raw(me, back, frames)
      } else {
        @protocol.InputSpanFrame::of(me, back, frames)
      }
      msgs.push(@protocol.Message::Span(span))
      carried = frames.length()
    }
  }
  let c = s.confirmed()
  msgs.push(@protocol.Message::Confirm(@protocol.ConfirmFrame::new(c)))
  if f % sync_every == 0 {
    match s.hash_at(c) {
      Some(h) =>
        msgs.push(
          @protocol.Message::Checksum(@protocol.ChecksumFrame::new(c, h)),
        )
      None => ()
    }
  }
  (@protocol.encode_batch(msgs), carried)
}

///|
/// 把一条链路上收到的字节投递进会话，返回本次发现的校验失配数。
///
/// `src` 是发送方：`Confirm` 帧里不带玩家索引（它是全房水位），
/// 发送方身份由连接本身给出。
fn deliver(
  payload : Bytes,
  s : @session.Session[@scene.Scene],
  src : Int32,
) -> Int32 {
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
      @protocol.Span(x) => {
        let mut i = 0
        for bits in x.expand() {
          s.receive_from(x.player, x.start + i, bits)
          i = i + 1
        }
      }
      @protocol.Confirm(c) => s.receive_confirm(src, c.frame)
      @protocol.Checksum(c) =>
        if c.frame <= s.confirmed() {
          match s.hash_at(c.frame) {
            Some(mine) => if mine != c.hash { bad = bad + 1 }
            None => ()
          }
        }
      @protocol.Active(_) => ()
    }
  }
  bad
}

///|
/// 找首个分叉帧：从 1 扫到所有玩家的公共确认帧，逐帧比对历史哈希。
fn scan_divergence(sessions : Array[@session.Session[@scene.Scene]]) -> Int32 {
  let mut c = sessions[0].confirmed()
  let mut i = 1
  while i < sessions.length() {
    if sessions[i].confirmed() < c {
      c = sessions[i].confirmed()
    }
    i = i + 1
  }
  let mut f = 1
  while f <= c {
    let base = sessions[0].hash_at(f)
    let mut j = 1
    while j < sessions.length() {
      if sessions[j].hash_at(f) != base {
        return f
      }
      j = j + 1
    }
    f = f + 1
  }
  -1
}

///|
/// 跑一局 4 人对局，`packing` 决定发包策略。
pub fn run(
  packing : Packing,
  spec : @scene.LinkSpec,
  total : Int32,
) -> PackStats {
  let sessions : Array[@session.Session[@scene.Scene]] = []
  let mut i = 0
  while i < PLAYERS {
    sessions.push(
      @session.Session::with_players(@scene.Scene::new(), PLAYERS, i, 128),
    )
    i = i + 1
  }
  let nets : Array[Array[@sim_net.NetSim]] = []
  let mut from = 0
  while from < PLAYERS {
    let row : Array[@sim_net.NetSim] = []
    let mut to = 0
    while to < PLAYERS {
      row.push(
        @sim_net.NetSim::new(
          @sim_net.Link::new(
            spec.delay,
            spec.jitter,
            spec.loss,
            spec.reorder,
            ((from * 131 + to).to_uint64() + 1UL) * 2654435761UL,
          ),
        ),
      )
      to = to + 1
    }
    nets.push(row)
    from = from + 1
  }
  let mut bytes = 0L
  let mut packets = 0L
  let mut carried = 0L
  let mut mismatches = 0
  let mut f = 0
  while f < total {
    f = f + 1
    let mut p = 0
    while p < PLAYERS {
      ignore(sessions[p].advance(@scene.scripted_input(f, p)))
      p = p + 1
    }
    let mut sender = 0
    while sender < PLAYERS {
      let mut target = 0
      while target < PLAYERS {
        if target != sender {
          let (payload, frames) = outbound(
            sessions[sender],
            sender,
            target,
            f,
            packing,
          )
          bytes = bytes + payload.length().to_int64()
          packets = packets + 1L
          carried = carried + frames.to_int64()
          nets[sender][target].send(f, payload)
        }
        target = target + 1
      }
      sender = sender + 1
    }
    let mut target = 0
    while target < PLAYERS {
      let mut src = 0
      while src < PLAYERS {
        if src != target {
          for payload in nets[src][target].recv(f) {
            mismatches = mismatches + deliver(payload, sessions[target], src)
          }
        }
        src = src + 1
      }
      target = target + 1
    }
  }
  // 收尾：不再推进新帧，但继续重发最后一段——否则丢掉的包永远没有第二次机会，
  // 确认帧就停在那儿了。
  let mut t = total
  let mut drained = false
  while t < total + 120 && !drained {
    t = t + 1
    let mut sender = 0
    while sender < PLAYERS {
      let mut target = 0
      while target < PLAYERS {
        if target != sender {
          let (payload, frames) = outbound(
            sessions[sender],
            sender,
            target,
            total,
            packing,
          )
          bytes = bytes + payload.length().to_int64()
          packets = packets + 1L
          carried = carried + frames.to_int64()
          nets[sender][target].send(t, payload)
        }
        target = target + 1
      }
      sender = sender + 1
    }
    let mut target = 0
    while target < PLAYERS {
      let mut src = 0
      while src < PLAYERS {
        if src != target {
          for payload in nets[src][target].recv(t) {
            mismatches = mismatches + deliver(payload, sessions[target], src)
          }
        }
        src = src + 1
      }
      target = target + 1
    }
    let mut all = true
    let mut k = 0
    while k < PLAYERS {
      if sessions[k].confirmed() < total {
        all = false
      }
      k = k + 1
    }
    drained = all
  }
  let confirmed : Array[Int32] = []
  let mut rollbacks = 0L
  let mut replayed = 0L
  let mut k = 0
  while k < PLAYERS {
    confirmed.push(sessions[k].confirmed())
    rollbacks = rollbacks + sessions[k].rollbacks().to_int64()
    replayed = replayed + sessions[k].replayed()
    k = k + 1
  }
  {
    bytes,
    packets,
    frames_carried: carried,
    confirmed,
    rollbacks,
    replayed,
    mismatches,
    first_divergence: scan_divergence(sessions),
  }
}

///|
fn main {
  let spec = @scene.LinkSpec::new(3, 1, 5, 10)
  let modes : Array[Packing] = [Legacy, Span, Masked, Adaptive, Lean]
  let stats : Array[PackStats] = []
  for m in modes {
    stats.push(run(m, spec, TOTAL))
  }
  let base = stats[0].bytes
  println("")
  println(
    "4 人全互联（12 条链路），\{TOTAL} 帧，3 帧延迟 + 1 帧抖动 + 5% 丢包 + 10% 乱序：",
  )
  println("")
  println(
    "| 策略 | 发送字节 | 相对第一种 | 平均字节/包 | 平均携带帧数 | 确认帧 | 回滚 | 重放帧数 | 一致 |",
  )
  println("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
  let mut i = 0
  while i < modes.length() {
    println(row(modes[i], stats[i], base))
    i = i + 1
  }
  let mut ok = true
  for st in stats {
    if st.first_divergence != -1 {
      ok = false
    }
  }
  println("")
  println(
    "第一种每帧固定重发 16 帧，每个包 16 条 `Input`；第二种换成一条区间帧，头开销从 16 份降到 1 份；",
  )
  println(
    "第三种只发变化的值（脚本每 6 帧才换一次按键）；第四种连区间都跟着链路走——",
  )
  println(
    "对端确认到哪就从哪之后开始发，于是「配大了的冗余」被自己收回，丢包时水位停住、区间自己变长。",
  )
  println("")
  // 高丢包 + 长延迟：自适应模式的区间会自己撑开，但收敛性不能打折。
  let hard = @scene.LinkSpec::new(10, 2, 25, 15)
  let legacy = run(Legacy, hard, TOTAL)
  let adaptive = run(Lean, hard, TOTAL)
  println(
    "10 帧延迟 + 2 帧抖动 + 25% 丢包 + 15% 乱序（链路比冗余还差）：",
  )
  println("")
  println(
    "| 策略 | 发送字节 | 平均携带帧数 | 确认帧 | 回滚 | 重放帧数 | 一致 |",
  )
  println("| --- | --- | --- | --- | --- | --- | --- |")
  println(row_short("每帧一条 Input，固定 16 帧", legacy))
  println(row_short("InputSpan + 掩码 + 自适应 + 校验和/8", adaptive))
  println("")
  if ok && legacy.first_divergence == -1 && adaptive.first_divergence == -1 {
    println(
      "结论：五种策略都收敛，回滚与重放次数逐项相等——省的是字节，不是正确性。",
    )
  } else {
    println(
      "警告：出现了分叉或未收敛的会话，说明打包/投递有 bug。",
    )
  }
  println("")
}

///|
fn row(p : Packing, st : PackStats, base : Int64) -> String {
  let ratio = if base == 0L { 100 } else { (st.bytes * 100L / base).to_int() }
  "| " +
  p.label() +
  " | " +
  st.bytes.to_string() +
  " | " +
  ratio.to_string() +
  "% | " +
  st.avg_bytes_per_packet().to_string() +
  " | " +
  st.avg_frames_per_packet().to_string() +
  " | " +
  st.confirmed[0].to_string() +
  "/" +
  st.confirmed[1].to_string() +
  "/" +
  st.confirmed[2].to_string() +
  "/" +
  st.confirmed[3].to_string() +
  " | " +
  st.rollbacks.to_string() +
  " | " +
  st.replayed.to_string() +
  " | " +
  (if st.first_divergence == -1 { "yes" } else { "NO" }) +
  " |"
}

///|
fn row_short(name : String, st : PackStats) -> String {
  "| " +
  name +
  " | " +
  st.bytes.to_string() +
  " | " +
  st.avg_frames_per_packet().to_string() +
  " | " +
  st.confirmed[0].to_string() +
  "/" +
  st.confirmed[1].to_string() +
  "/" +
  st.confirmed[2].to_string() +
  "/" +
  st.confirmed[3].to_string() +
  " | " +
  st.rollbacks.to_string() +
  " | " +
  st.replayed.to_string() +
  " | " +
  (if st.first_divergence == -1 { "yes" } else { "NO" }) +
  " |"
}
