///|
/// drop_out：一个人掉线，全房还能不能继续？
///
/// 4 人局，3 号玩家在第 `GONE` 帧之后拔网线（不再发包）。示例跑两遍：
///
/// - `announce_drop = false`：没人宣布掉线，确认帧永远停在 3 号最后发包的位置，
///   其余三人只能一直靠预测往前跑，回滚窗口很快用尽；
/// - `announce_drop = true`：房主（0 号）发现 3 号超过 `TIMEOUT` 帧没动静，
///   把「3 号掉线」写进包里广播，其余人收到后同样把他移出在线集合，
///   确认帧随即恢复推进，剩下三人逐帧哈希仍然一致。
///
///   moon run examples/drop_out
const PLAYERS : Int32 = 4

///|
const TOTAL : Int32 = 480

///|
const RESEND : Int32 = 8

///|
const DELAY : Int32 = 3

///|
const JITTER : Int32 = 1

///|
/// 拔网线的那位。
const GONE_PLAYER : Int32 = 3

///|
/// 从这一帧起他不再发包。
const GONE : Int32 = 200

///|
/// 房主的判据：连续这么多帧没收到他的包就宣布掉线。
const TIMEOUT : Int32 = 30

///|
/// 一局跑完的结果。
pub(all) struct DropStats {
  /// 四个玩家各自的确认帧（3 号掉线，所以他会停住）。
  confirmed : Array[Int32]
  /// 其余三人的回滚次数之和。
  rollbacks : Int64
  /// 其余三人的重放帧数之和。
  replayed : Int64
  /// 其余三人之间首个分叉帧；-1 表示全程一致。
  first_divergence : Int32
  /// 校验和帧比对失配次数。
  mismatches : Int32
  /// 房主宣布掉线的帧；0 表示整局都没宣布。
  declared_at : Int32
}

///|
/// 把某个玩家最近 `RESEND` 帧的输入、确认帧、校验和（以及房主的掉线声明）
/// 打成一个包。
fn outbound(
  s : @session.Session[@scene.Scene],
  me : Int32,
  back : Int32,
  f : Int32,
  announce : Bool,
) -> Bytes {
  let msgs : Array[@protocol.Message] = []
  let mut m = back
  while m <= f {
    match s.player_input(me, m) {
      Some(bits) =>
        msgs.push(
          @protocol.Message::Input(
            @protocol.InputFrame::new_from(me, m, [bits]),
          ),
        )
      None => ()
    }
    m = m + 1
  }
  let c = s.confirmed()
  msgs.push(@protocol.Message::Confirm(@protocol.ConfirmFrame::new(c)))
  match s.hash_at(c) {
    Some(h) =>
      msgs.push(@protocol.Message::Checksum(@protocol.ChecksumFrame::new(c, h)))
    None => ()
  }
  if announce {
    msgs.push(
      @protocol.Message::Active(@protocol.ActiveFrame::new(GONE_PLAYER, false)),
    )
  }
  @protocol.encode_batch(msgs)
}

///|
/// 在 `keep` 这几个会话的共同确认帧上逐帧比对哈希，找首个分叉帧。
fn scan_divergence(
  sessions : Array[@session.Session[@scene.Scene]],
  keep : Int32,
) -> Int32 {
  let mut c = sessions[0].confirmed()
  let mut i = 1
  while i < keep {
    if sessions[i].confirmed() < c {
      c = sessions[i].confirmed()
    }
    i = i + 1
  }
  let mut f = 1
  while f <= c {
    let base = sessions[0].hash_at(f)
    let mut j = 1
    while j < keep {
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
/// 跑一局 `total` 帧的对局；`announce_drop` 决定房主是否广播掉线。
pub fn run(announce_drop : Bool, total : Int32, verbose : Bool) -> DropStats {
  let sessions : Array[@session.Session[@scene.Scene]] = []
  let mut i = 0
  while i < PLAYERS {
    sessions.push(
      @session.Session::with_players(@scene.Scene::new(), PLAYERS, i, 128),
    )
    i = i + 1
  }
  // nets[from][to] 是一条单向链路，from == to 的那格不会被使用。
  let nets : Array[Array[@sim_net.NetSim]] = []
  let mut from = 0
  while from < PLAYERS {
    let row : Array[@sim_net.NetSim] = []
    let mut to = 0
    while to < PLAYERS {
      row.push(
        @sim_net.NetSim::new(
          @sim_net.Link::new(
            DELAY,
            JITTER,
            0,
            0,
            ((from * 977 + to).to_uint64() + 1UL) * 7919UL,
          ),
        ),
      )
      to = to + 1
    }
    nets.push(row)
    from = from + 1
  }
  // 房主视角的「最后一次听到某人的包」——用到达帧近似，够用且确定性。
  let heard : Array[Int32] = Array::make(PLAYERS, 0)
  let mut decided = false
  let mut declared_at = 0
  let mut mismatches = 0
  let mut f = 0
  while f < total {
    f = f + 1
    let mut p = 0
    while p < PLAYERS {
      ignore(sessions[p].advance(@scene.scripted_input(f, p)))
      p = p + 1
    }
    // 收包：先收，再判断掉线，最后发包，保证声明能随本帧的包发出去。
    let mut target = 0
    while target < PLAYERS {
      let mut src = 0
      while src < PLAYERS {
        if src != target {
          for payload in nets[src][target].recv(f) {
            mismatches = mismatches + @scene.apply(payload, sessions[target])
            if target == 0 {
              heard[src] = f
            }
          }
        }
        src = src + 1
      }
      target = target + 1
    }
    // 掉线判定只由房主做：其他人收到 `Active` 帧后照做，避免各判各的。
    if !decided && announce_drop && f - heard[GONE_PLAYER] > TIMEOUT {
      decided = true
      declared_at = f
      ignore(sessions[0].set_player_active(GONE_PLAYER, false))
    }
    let mut back = f - RESEND + 1
    if back < 1 {
      back = 1
    }
    let mut sender = 0
    while sender < PLAYERS {
      // 拔了网线的那位：本地还在跑，包一个也发不出去。
      if sender == GONE_PLAYER && f > GONE {
        ()
      } else {
        let payload = outbound(sessions[sender], sender, back, f, decided)
        let mut dst = 0
        while dst < PLAYERS {
          // 拔网线是双向的：既发不出去，也收不到。
          if dst != sender && !(dst == GONE_PLAYER && f > GONE) {
            nets[sender][dst].send(f, payload)
          }
          dst = dst + 1
        }
      }
      sender = sender + 1
    }
    if verbose && f % 60 == 0 {
      let mut line = "\{pad(f.to_string(), 6)}"
      let mut k = 0
      while k < PLAYERS {
        line = line + pad(sessions[k].confirmed().to_string(), 8)
        k = k + 1
      }
      line = line + pad(sessions[0].online_count().to_string(), 6)
      println(line)
    }
  }
  // 收尾：最后一轮的包还在路上，多收 64 帧让确认追上。
  let mut t = total
  while t < total + 64 {
    t = t + 1
    let mut target = 0
    while target < PLAYERS {
      let mut src = 0
      while src < PLAYERS {
        if src != target {
          for payload in nets[src][target].recv(t) {
            mismatches = mismatches + @scene.apply(payload, sessions[target])
          }
        }
        src = src + 1
      }
      target = target + 1
    }
  }
  let confirmed : Array[Int32] = []
  let mut rollbacks = 0L
  let mut replayed = 0L
  let mut k = 0
  while k < PLAYERS {
    confirmed.push(sessions[k].confirmed())
    // 3 号掉线后已经不在同一个世界里，只统计其余三人。
    if k != GONE_PLAYER {
      rollbacks = rollbacks + sessions[k].rollbacks().to_int64()
      replayed = replayed + sessions[k].replayed()
    }
    k = k + 1
  }
  {
    confirmed,
    rollbacks,
    replayed,
    first_divergence: scan_divergence(sessions, GONE_PLAYER),
    mismatches,
    declared_at,
  }
}

///|
fn main {
  println(
    "drop_out：\{PLAYERS} 人局，\{GONE_PLAYER} 号在第 \{GONE} 帧后停止发包，超时阈值 \{TIMEOUT} 帧",
  )
  println("")
  println("frame  confirm(p0..p3)              online")
  let stuck = run(false, TOTAL, true)
  println("")
  println("—— 不宣布掉线 ——")
  println(
    "  确认帧 = \{stuck.confirmed[0]}/\{stuck.confirmed[1]}/\{stuck.confirmed[2]}/\{stuck.confirmed[3]}，其余三人一致 = \{stuck.first_divergence < 0}，校验失配 = \{stuck.mismatches}",
  )
  println(
    "  回滚 = \{stuck.rollbacks}，重放帧数 = \{stuck.replayed}（一直在追一个永远不会到的输入）",
  )
  println("")
  println("frame  confirm(p0..p3)              online")
  let live = run(true, TOTAL, true)
  println("")
  println("—— 房主在第 \{live.declared_at} 帧宣布掉线 ——")
  println(
    "  确认帧 = \{live.confirmed[0]}/\{live.confirmed[1]}/\{live.confirmed[2]}/\{live.confirmed[3]}，其余三人一致 = \{live.first_divergence < 0}，校验失配 = \{live.mismatches}",
  )
  println("  回滚 = \{live.rollbacks}，重放帧数 = \{live.replayed}")
  println("")
  println(
    "结论：确认帧等的是「所有在线玩家」，不是「所有玩家」——",
  )
  println(
    "      掉线语义必须由上层给出（这里是一个超时阈值），本库只负责把它同步给全房。",
  )
}

///|
/// 右侧补空格，让表格在等宽字体里对齐。
fn pad(s : String, width : Int32) -> String {
  let mut out = s
  while out.length() < width {
    out = out + " "
  }
  out
}
