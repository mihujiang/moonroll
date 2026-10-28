///|
/// resync：两端世界分叉之后，用一份完整状态把落后的一端掰回来。
///
///   moon run examples/resync
///
/// V0.9 之前只能「发现」分叉：确认帧哈希对不上就报出来，然后两端各算各的。
/// 这一版多了一条补救路径：
///
/// 1. 对端在某个确认帧上的校验和对不上 → 记下这一帧；
/// 2. 向对端要这一帧的**完整状态**（`SnapRequest` → `Snap`）；
/// 3. `resync_from` 把本端 restore 到那一帧，再用本端输入环重放到当前帧。
///
/// 为什么必须「整段替换」而不是「回滚」：回滚是从**本端**快照恢复的，而快照
/// 里就是那份错的世界——回滚只会把同一个错误再算一遍，深度多大都没用。
///
/// 为什么恢复点必须落在回滚窗口内：`frame` 之后的帧要重放，而重放靠的是输入
/// 环；更早的输入已经被环淘汰，重放会用「猜出来」的值，等于换一个地方重新
/// 分叉。
const TOTAL : Int32 = 400

///|
/// 事故帧：1 号在这一帧「本地执行 A、线上发 B」。
///
/// 只改本端内存里的状态是没用的——回滚会从快照恢复并重放，任何没进输入流的
/// 改动都会被洗掉；只有输入流本身出错才会留下永久痕迹。
const CORRUPT : Int32 = 100

///|
/// 每帧重发最近多少帧的输入（扛丢包）。
const RESEND : Int32 = 8

///|
/// 请求失败时的重试间隔：`SnapRequest` / `Snap` 本身也可能丢。
const ASK_EVERY : Int32 = 6

///|
const WINDOW : Int32 = 128

///|
/// 一局的重同步过程记录。
pub(all) struct ResyncStats {
  /// 两端最终的确认帧。
  p0_confirmed : Int32
  p1_confirmed : Int32
  /// P0 首次检出失配的确认帧；0 表示全程没失配。
  detected : Int32
  /// P0 实际完成的恢复点；0 表示没恢复。
  repaired : Int32
  /// P0 发出的 `SnapRequest` 个数。
  asked : Int32
  /// P0 成功重同步的次数。
  resyncs : Int32
  /// 恢复前检出的失配次数。
  mismatch_before : Int32
  /// 恢复后检出的失配次数（应该恒为 0）。
  mismatch_after : Int32
  /// 恢复之后的首个分叉帧；0 表示从恢复点起逐帧一致。
  bad_after : Int32
  /// `Snap` 里状态字节的长度。
  state_bytes : Int32
  /// 两端各自的回滚次数。
  p0_rollbacks : Int32
  p1_rollbacks : Int32
  /// 链路丢掉的包数。
  dropped : Int32
}

///|
/// 恢复过程的中间状态。放在一个可变结构里，是因为它同时被三条路径改写：
/// 收包（检测 / 应用状态）、发包（请求 / 应答）、收尾（继续重试）。
struct Healing {
  /// 待请求的恢复点；0 表示不需要。
  mut need : Int32
  /// 上一次发出请求的帧。
  mut last_ask : Int32
  /// 发出的请求数。
  mut asked : Int32
  /// 已完成的恢复点；0 表示还没恢复。
  mut repaired : Int32
  /// 首个失配的确认帧。
  mut detected : Int32
  /// 恢复前 / 恢复后的失配次数。
  mut mismatch_before : Int32
  mut mismatch_after : Int32
  /// 恢复之后已逐帧比对到哪一帧。
  mut checked : Int32
  /// 恢复之后的首个分叉帧。
  mut bad_after : Int32
  /// 需要回一条 `Snap` 的帧；0 表示没有。
  mut reply : Int32
  /// 最近一次收到的状态字节数。
  mut state_bytes : Int32
}

///|
fn min32(a : Int32, b : Int32) -> Int32 {
  if a < b {
    a
  } else {
    b
  }
}

///|
/// 一帧上行包：最近 `RESEND` 帧的输入 + 确认帧 + 当前确认帧的校验和。
///
/// `corrupt` 不为 0 时，那一帧的输入会被改掉——模拟「本地算了 A，序列化出去
/// 的却是 B」。
fn upstream(
  s : @session.Session[@scene.Scene],
  id : Int32,
  upto : Int32,
  corrupt : Int32,
) -> Array[@protocol.Message] {
  let msgs : Array[@protocol.Message] = []
  let mut m = upto - RESEND + 1
  if m < 1 {
    m = 1
  }
  while m <= upto {
    let mut input = @scene.scripted_input(m, id)
    if m == corrupt {
      input = input ^ 1UL
    }
    msgs.push(
      @protocol.Message::Input(@protocol.InputFrame::new_from(id, m, [input])),
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
  msgs
}

///|
/// 投递到落后的 P0：输入 / 确认 / 校验和 / 完整状态。
///
/// 校验和只在**本端也已确认**的帧上比对：尚未确认的帧里还混着预测输入，
/// 和对方的真实输入本来就不同，比了只会得到假分叉。
fn apply_to_laggard(
  payload : Bytes,
  s : @session.Session[@scene.Scene],
  heal : Healing,
) -> Unit {
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
        if c.frame <= s.confirmed() {
          match s.hash_at(c.frame) {
            Some(mine) =>
              if mine != c.hash {
                if heal.repaired == 0 {
                  heal.mismatch_before = heal.mismatch_before + 1
                } else {
                  heal.mismatch_after = heal.mismatch_after + 1
                }
                // 第一次失配的确认帧就是最合适的恢复点：它一定不早于事故帧，
                // 之后的输入在两端已经一致，重放不会再分叉。
                if heal.detected == 0 {
                  heal.detected = c.frame
                  heal.need = c.frame
                }
              }
            None => ()
          }
        }
      @protocol.Snap(snap) =>
        if heal.repaired == 0 && heal.need != 0 && snap.frame == heal.need {
          if s.resync_from(snap.frame, snap.state) {
            heal.repaired = snap.frame
            heal.need = 0
            heal.checked = snap.frame
            heal.state_bytes = snap.state.length()
          }
        }
      // 只要状态：应答由 `resync_from` 应用，别的消息与本端无关
      _ => ()
    }
  }
}

///|
/// 投递到权威端 P1：输入 / 状态请求。
///
/// P1 不比对校验和：两人局里双方同时「互相纠正」会来回覆盖。真实系统里谁算
/// 权威要么按房主定，要么按多数票——这是上层策略，库只提供「取状态」和
/// 「换状态」两个动作。
fn apply_to_authority(
  payload : Bytes,
  s : @session.Session[@scene.Scene],
  heal : Healing,
) -> Unit {
  for msg in @protocol.decode_batch(payload) {
    match msg {
      @protocol.Input(x) => {
        let mut i = 0
        for bits in x.inputs {
          s.receive_from(x.player + i, x.frame, bits)
          i = i + 1
        }
      }
      // 每个请求都回一次：丢包时靠调用方的定时重试收敛
      @protocol.SnapRequest(r) => heal.reply = r.frame
      _ => ()
    }
  }
}

///|
/// 恢复点之后逐帧比对两端在共同确认帧上的哈希。
///
/// 边跑边比，而不是最后一次性扫：历史哈希只保留最近一个窗口，最后再扫时
/// 早先的帧已经取不到了。
fn check_synced(
  p0 : @session.Session[@scene.Scene],
  p1 : @session.Session[@scene.Scene],
  heal : Healing,
) -> Unit {
  if heal.repaired == 0 {
    return
  }
  let c = min32(p0.confirmed(), p1.confirmed())
  let mut f = heal.checked + 1
  while f <= c {
    match (p0.hash_at(f), p1.hash_at(f)) {
      (Some(a), Some(b)) =>
        if a != b && heal.bad_after == 0 {
          heal.bad_after = f
        }
      _ => ()
    }
    f = f + 1
  }
  heal.checked = c
}

///|
/// 跑一局：`corrupt` 不为 0 时，P1 在那一帧发出与本地执行不一致的输入。
pub fn run(
  spec : @scene.LinkSpec,
  total : Int32,
  corrupt : Int32,
) -> ResyncStats {
  let p0 = @session.Session::with_window(@scene.Scene::new(), 0, WINDOW)
  let p1 = @session.Session::with_window(@scene.Scene::new(), 1, WINDOW)
  let net01 = @sim_net.NetSim::new(
    @sim_net.Link::new(
      spec.delay,
      spec.jitter,
      spec.loss,
      spec.reorder,
      20261028UL,
    ),
  )
  let net10 = @sim_net.NetSim::new(
    @sim_net.Link::new(
      spec.delay,
      spec.jitter,
      spec.loss,
      spec.reorder,
      424242UL,
    ),
  )
  let heal : Healing = {
    need: 0,
    last_ask: 0,
    asked: 0,
    repaired: 0,
    detected: 0,
    mismatch_before: 0,
    mismatch_after: 0,
    checked: 0,
    bad_after: 0,
    reply: 0,
    state_bytes: 0,
  }
  let mut f = 0
  while f < total {
    f = f + 1
    ignore(p0.advance(@scene.scripted_input(f, 0)))
    ignore(p1.advance(@scene.scripted_input(f, 1)))
    let msgs0 = upstream(p0, 0, f, 0)
    if heal.need != 0 && f - heal.last_ask >= ASK_EVERY {
      msgs0.push(
        @protocol.Message::SnapRequest(
          @protocol.SnapRequestFrame::new(heal.need),
        ),
      )
      heal.last_ask = f
      heal.asked = heal.asked + 1
    }
    net01.send(f, @protocol.encode_batch(msgs0))
    let msgs1 = upstream(p1, 1, f, corrupt)
    if heal.reply != 0 {
      match p1.export_state(heal.reply) {
        Some(state) =>
          msgs1.push(
            @protocol.Message::Snap(@protocol.SnapFrame::new(heal.reply, state)),
          )
        None => ()
      }
      heal.reply = 0
    }
    net10.send(f, @protocol.encode_batch(msgs1))
    for payload in net10.recv(f) {
      apply_to_laggard(payload, p0, heal)
    }
    for payload in net01.recv(f) {
      apply_to_authority(payload, p1, heal)
    }
    check_synced(p0, p1, heal)
  }
  // 收尾：不再推进新帧，但继续重发最后一段输入、继续重试状态请求，
  // 直到两端的确认帧都追平——否则丢掉的包永远没有第二次机会。
  let mut t = total
  while t < total + 200 && (p0.confirmed() < total || p1.confirmed() < total) {
    t = t + 1
    let msgs0 = upstream(p0, 0, total, 0)
    if heal.need != 0 && t - heal.last_ask >= ASK_EVERY {
      msgs0.push(
        @protocol.Message::SnapRequest(
          @protocol.SnapRequestFrame::new(heal.need),
        ),
      )
      heal.last_ask = t
      heal.asked = heal.asked + 1
    }
    net01.send(t, @protocol.encode_batch(msgs0))
    let msgs1 = upstream(p1, 1, total, corrupt)
    if heal.reply != 0 {
      match p1.export_state(heal.reply) {
        Some(state) =>
          msgs1.push(
            @protocol.Message::Snap(@protocol.SnapFrame::new(heal.reply, state)),
          )
        None => ()
      }
      heal.reply = 0
    }
    net10.send(t, @protocol.encode_batch(msgs1))
    for payload in net10.recv(t) {
      apply_to_laggard(payload, p0, heal)
    }
    for payload in net01.recv(t) {
      apply_to_authority(payload, p1, heal)
    }
    check_synced(p0, p1, heal)
  }
  {
    p0_confirmed: p0.confirmed(),
    p1_confirmed: p1.confirmed(),
    detected: heal.detected,
    repaired: heal.repaired,
    asked: heal.asked,
    resyncs: p0.resyncs(),
    mismatch_before: heal.mismatch_before,
    mismatch_after: heal.mismatch_after,
    bad_after: heal.bad_after,
    state_bytes: heal.state_bytes,
    p0_rollbacks: p0.rollbacks(),
    p1_rollbacks: p1.rollbacks(),
    dropped: net01.dropped() + net10.dropped(),
  }
}

///|
fn main {
  let spec = @scene.LinkSpec::new(3, 2, 4, 8)
  let stats = run(spec, TOTAL, CORRUPT)
  println("resync：分叉之后用完整状态把落后者掰回来")
  println("")
  println(
    "链路：延迟 \{spec.delay} 帧 + 抖动 \{spec.jitter} 帧 + 丢包 \{spec.loss}% + 乱序 \{spec.reorder}%",
  )
  println(
    "事故：1 号在第 \{CORRUPT} 帧本地执行 A、线上发 B（输入序列化错位）",
  )
  println("      两端的输入流从此不同，靠回滚永远追不回来")
  println("")
  if stats.detected == 0 {
    println("没有检出失配：这一局本来就一致")
  } else {
    println(
      "P0 首次失配：确认帧 \{stats.detected} 的状态哈希不同（共 \{stats.mismatch_before} 次失配）",
    )
    println(
      "P0 请求第 \{stats.detected} 帧的完整状态：发出 \{stats.asked} 个 SnapRequest",
    )
    println(
      "P0 已恢复：restore 到第 \{stats.repaired} 帧（状态 \{stats.state_bytes} 字节），再用输入环重放",
    )
  }
  println("")
  println(
    "确认帧：P0 \{stats.p0_confirmed} / P1 \{stats.p1_confirmed}；回滚 P0 \{stats.p0_rollbacks} / P1 \{stats.p1_rollbacks}",
  )
  println(
    "重同步次数：P0 \{stats.resyncs}；恢复后失配 \{stats.mismatch_after} 次",
  )
  if stats.bad_after == 0 {
    println(
      "恢复后：从恢复点到结束，两端在共同确认帧上逐帧哈希一致",
    )
  } else {
    println("恢复后仍然在第 \{stats.bad_after} 帧分叉")
  }
  println(
    "注：恢复点之前的旧哈希留在落后者本地——重同步修的是未来，不改写历史。",
  )
}
