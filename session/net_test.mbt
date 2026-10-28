///|
/// 应用层冗余重发的帧数。
const RESEND : Int32 = 16

///|
fn lcg(state : UInt64) -> UInt64 {
  state * 6364136223846793005UL + 1442695040888963407UL
}

///|
/// 处理一个收到的包：输入帧交给会话，确认帧返回其帧号（0 表示不是确认帧）。
fn feed(session : @session.Session[Counter], payload : Bytes) -> Int32 {
  match @protocol.decode(payload) {
    Some(@protocol.Input(frame)) => {
      let mut i = 0
      for bits in frame.inputs {
        session.receive_from(frame.player + i, frame.frame, bits)
        i = i + 1
      }
      0
    }
    Some(@protocol.Confirm(c)) => c.frame
    _ => 0
  }
}

///|
/// 端到端：两个 @session.Session 通过确定性链路互发输入帧与确认帧。
///
/// 应用层做冗余重发（每帧重发最近 `RESEND` 帧），因此丢包不会造成永久丢失。
/// 返回 (a.hash, b.hash)。
fn run_net(
  delay : Int32,
  jitter : Int32,
  loss : Int32,
  reorder : Int32,
  seed : UInt64,
  total : Int32,
) -> (UInt64, UInt64) {
  let a = @session.Session::with_window({ x: 0UL, }, 0, 128)
  let b = @session.Session::with_window({ x: 0UL, }, 1, 128)
  let ab = @sim_net.NetSim::new(
    @sim_net.Link::new(delay, jitter, loss, reorder, seed),
  )
  let ba = @sim_net.NetSim::new(
    @sim_net.Link::new(delay, jitter, loss, reorder, seed + 1UL),
  )
  // acked_a: B 已确认收到的 A 输入帧；acked_b: A 已确认收到的 B 输入帧
  let mut acked_a = 0
  let mut acked_b = 0
  let mut f = 0
  while f < total {
    f = f + 1
    ignore(a.advance(input_of(f, 0)))
    ignore(b.advance(input_of(f, 1)))
    // A -> B：重发未确认的本地输入
    let mut m = if f - RESEND > acked_a { f - RESEND } else { acked_a + 1 }
    while m <= f {
      let msg = @protocol.Input(
        @protocol.InputFrame::new_from(0, m, [input_of(m, 0)]),
      )
      ignore(ab.send(f, @protocol.encode(msg)))
      m = m + 1
    }
    // B -> A：重发未确认的本地输入
    m = if f - RESEND > acked_b { f - RESEND } else { acked_b + 1 }
    while m <= f {
      let msg = @protocol.Input(
        @protocol.InputFrame::new_from(1, m, [input_of(m, 1)]),
      )
      ignore(ba.send(f, @protocol.encode(msg)))
      m = m + 1
    }
    for payload in ab.recv(f) {
      let c = feed(b, payload)
      acked_b = if c > acked_b { c } else { acked_b }
    }
    for payload in ba.recv(f) {
      let c = feed(a, payload)
      acked_a = if c > acked_a { c } else { acked_a }
    }
    // 告知对端：我已收到你的输入到 confirmed
    let conf_a = @protocol.Confirm(@protocol.ConfirmFrame::new(a.confirmed()))
    let conf_b = @protocol.Confirm(@protocol.ConfirmFrame::new(b.confirmed()))
    ignore(ab.send(f, @protocol.encode(conf_a)))
    ignore(ba.send(f, @protocol.encode(conf_b)))
  }
  // 收尾：模拟可靠层继续重发未确认输入，直到双方都确认到最后一帧
  let mut wait = 0
  while wait < 120 {
    wait = wait + 1
    let now = total + wait
    let mut m = if total - RESEND > acked_a {
      total - RESEND
    } else {
      acked_a + 1
    }
    while m <= total {
      let msg = @protocol.Input(
        @protocol.InputFrame::new_from(0, m, [input_of(m, 0)]),
      )
      ignore(ab.send(now, @protocol.encode(msg)))
      m = m + 1
    }
    m = if total - RESEND > acked_b { total - RESEND } else { acked_b + 1 }
    while m <= total {
      let msg = @protocol.Input(
        @protocol.InputFrame::new_from(1, m, [input_of(m, 1)]),
      )
      ignore(ba.send(now, @protocol.encode(msg)))
      m = m + 1
    }
    let packets_ab = ab.recv(now)
    for payload in packets_ab {
      let c = feed(b, payload)
      acked_b = if c > acked_b { c } else { acked_b }
    }
    let packets_ba = ba.recv(now)
    for payload in packets_ba {
      let c = feed(a, payload)
      acked_a = if c > acked_a { c } else { acked_a }
    }
    let conf_a = @protocol.Confirm(@protocol.ConfirmFrame::new(a.confirmed()))
    let conf_b = @protocol.Confirm(@protocol.ConfirmFrame::new(b.confirmed()))
    ignore(ab.send(now, @protocol.encode(conf_a)))
    ignore(ba.send(now, @protocol.encode(conf_b)))
    if acked_a >= total &&
      acked_b >= total &&
      ab.in_flight() == 0 &&
      ba.in_flight() == 0 {
      break
    }
  }
  let ha = a.hash()
  let hb = b.hash()
  if ha != hb {
    println(
      "  a frame=" +
      a.frame().to_string() +
      " conf=" +
      a.confirmed().to_string() +
      " acked_a=" +
      acked_a.to_string(),
    )
    println(
      "  b frame=" +
      b.frame().to_string() +
      " conf=" +
      b.confirmed().to_string() +
      " acked_b=" +
      acked_b.to_string(),
    )
  }
  (ha, hb)
}

///|
test "representative network curves converge" {
  let curves : Array[(Int32, Int32, Int32, Int32)] = [
    (0, 0, 0, 0), // 0ms
    (3, 0, 0, 0), // 50ms
    (6, 0, 0, 0), // 100ms
    (12, 0, 0, 0), // 200ms
    (18, 0, 0, 0), // 300ms
    (6, 3, 0, 0), // 100ms，抖动 ±50ms
    (6, 1, 5, 0), // 100ms + 5% 丢包
    (6, 1, 2, 25), // 100ms + 抖动 + 2% 丢包 + 25% 乱序
  ]
  let gold = { x: 0UL, }
  let mut g = 1
  while g <= 300 {
    @session.Sim::step_players(gold, [input_of(g, 0), input_of(g, 1)])
    g = g + 1
  }
  let expected = @session.Sim::hash(gold)
  for curve in curves {
    let (delay, jitter, loss, reorder) = curve
    let (ha, hb) = run_net(delay, jitter, loss, reorder, 20260101UL, 300)
    assert_eq(ha, hb)
    assert_eq(ha, expected)
  }
}

///|
test "fuzz: random link parameters converge" {
  let mut seed = 987654321UL
  let mut i = 0
  while i < 1000 {
    seed = lcg(seed)
    let delay = (seed % 25UL).to_int()
    seed = lcg(seed)
    let jitter = (seed % 7UL).to_int()
    seed = lcg(seed)
    let loss = (seed % 11UL).to_int()
    seed = lcg(seed)
    let reorder = (seed % 3UL).to_int() * 25
    let (ha, hb) = run_net(delay, jitter, loss, reorder, seed, 300)
    if ha != hb {
      println(
        "fuzz mismatch: delay=" +
        delay.to_string() +
        " jitter=" +
        jitter.to_string() +
        " loss=" +
        loss.to_string() +
        " reorder=" +
        reorder.to_string() +
        " seed=" +
        seed.to_string(),
      )
    }
    assert_eq(ha, hb)
    i = i + 1
  }
}
