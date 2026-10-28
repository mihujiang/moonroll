///|
/// four_peer：四个人同时对局。
///
/// 每个玩家一个 `Session`，与其他三人各有一条独立链路（4 人全互连 = 12 条），
/// 包照样走真实字节协议。示例会把「2 人局」和「4 人局」按同一套链路参数各跑
/// 一遍，对比重放帧数——多一个人在局里，代价不是线性的。
///
///   moon run examples/four_peer
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
/// 一局跑完的结果。
pub(all) struct RunStats {
  /// 每个玩家的确认帧。
  confirmed : Array[Int32]
  /// 所有玩家回滚次数之和。
  rollbacks : Int64
  /// 所有玩家重放帧数之和。
  replayed : Int64
  /// 所有玩家单次最大回滚深度里的最大值。
  max_depth : Int32
  /// 校验和帧比对失败次数。
  mismatches : Int32
  /// 首个分叉帧；-1 表示全程一致。
  first_divergence : Int32
}

///|
/// 把某个玩家最近 `RESEND` 帧的输入、当前确认帧和该帧哈希打成一个包。
fn outbound(
  s : @session.Session[@scene.Scene],
  me : Int32,
  back : Int32,
  f : Int32,
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
  @protocol.encode_batch(msgs)
}

///|
/// 找首个分叉帧：从 1 扫到大家的公共确认帧，逐帧比对四个会话的历史哈希。
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
/// 跑一局 `players` 人对局，`verbose` 为真时每 60 帧打一行进度。
pub fn run(players : Int32, total : Int32, verbose : Bool) -> RunStats {
  let sessions : Array[@session.Session[@scene.Scene]] = []
  let mut i = 0
  while i < players {
    sessions.push(
      @session.Session::with_players(@scene.Scene::new(), players, i, 128),
    )
    i = i + 1
  }
  // nets[from][to] 是一条单向链路，from == to 的那格不会被使用。
  let nets : Array[Array[@sim_net.NetSim]] = []
  let mut from = 0
  while from < players {
    let row : Array[@sim_net.NetSim] = []
    let mut to = 0
    while to < players {
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
  let mut mismatches = 0
  let mut f = 0
  while f < total {
    f = f + 1
    let mut p = 0
    while p < players {
      ignore(sessions[p].advance(@scene.scripted_input(f, p)))
      p = p + 1
    }
    let mut back = f - RESEND + 1
    if back < 1 {
      back = 1
    }
    // 每个玩家算一次包，发给其他所有人。
    let mut sender = 0
    while sender < players {
      let payload = outbound(sessions[sender], sender, back, f)
      let mut target = 0
      while target < players {
        if target != sender {
          nets[sender][target].send(f, payload)
        }
        target = target + 1
      }
      sender = sender + 1
    }
    // 每个玩家收其他人的包。
    let mut target = 0
    while target < players {
      let mut src = 0
      while src < players {
        if src != target {
          for payload in nets[src][target].recv(f) {
            mismatches = mismatches + @scene.apply(payload, sessions[target])
          }
        }
        src = src + 1
      }
      target = target + 1
    }
    if verbose && f % 60 == 0 {
      let mut line = "\{pad(f.to_string(), 6)}"
      let mut k = 0
      while k < players {
        line = line + pad(sessions[k].confirmed().to_string(), 8)
        k = k + 1
      }
      let mut rb = 0
      let mut k2 = 0
      while k2 < players {
        rb = rb + sessions[k2].rollbacks()
        k2 = k2 + 1
      }
      println("\{line}\{pad(rb.to_string(), 10)}")
    }
  }
  // 收尾：最后一轮的包还在路上，多收 64 帧让确认追上。
  let mut t = total
  while t < total + 64 {
    t = t + 1
    let mut target = 0
    while target < players {
      let mut src = 0
      while src < players {
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
  let mut max_depth = 0
  let mut k = 0
  while k < players {
    confirmed.push(sessions[k].confirmed())
    rollbacks = rollbacks + sessions[k].rollbacks().to_int64()
    replayed = replayed + sessions[k].replayed()
    if sessions[k].max_rollback_depth() > max_depth {
      max_depth = sessions[k].max_rollback_depth()
    }
    k = k + 1
  }
  {
    confirmed,
    rollbacks,
    replayed,
    max_depth,
    mismatches,
    first_divergence: scan_divergence(sessions),
  }
}

///|
fn main {
  println(
    "four_peer：\{PLAYERS} 个 Session 全互联 + 真实字节协议 + \{DELAY} 帧延迟 + \{JITTER} 帧抖动",
  )
  println("")
  println("frame  confirm(p0..p3)              rollbacks")
  let four = run(PLAYERS, TOTAL, true)
  let two = run(2, TOTAL, false)
  println("")
  println("终态（4 人局）：")
  println(
    "  一致 = \{four.first_divergence < 0}，首个分叉帧 = \{if four.first_divergence < 0 { "无" } else { four.first_divergence.to_string() }}，校验失配 = \{four.mismatches}",
  )
  println(
    "  确认帧 = \{four.confirmed[0]}/\{four.confirmed[1]}/\{four.confirmed[2]}/\{four.confirmed[3]}，回滚 = \{four.rollbacks}，重放帧数 = \{four.replayed}，最大深度 = \{four.max_depth}",
  )
  println("")
  println("同样 480 帧、同样链路参数下的规模对比：")
  println("  玩家数  链路数  回滚次数  重放帧数  最大深度")
  println(
    "  \{pad("2", 8)}\{pad("2", 8)}\{pad(two.rollbacks.to_string(), 10)}\{pad(two.replayed.to_string(), 10)}\{two.max_depth}",
  )
  println(
    "  \{pad(PLAYERS.to_string(), 8)}\{pad("12", 8)}\{pad(four.rollbacks.to_string(), 10)}\{pad(four.replayed.to_string(), 10)}\{four.max_depth}",
  )
  println("")
  println(
    "结论：每人多一条链路、每帧多一路输入，重放成本涨得比人数快——",
  )
  println(
    "      回滚会话的窗口与冗余发送，都是按「最慢的那个玩家」付钱的。",
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
