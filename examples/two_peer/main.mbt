///|
/// two_peer：最小可运行的联机闭环。
///
/// 两个对等体各跑一个 `Session`，包走真实字节协议（`encode_batch`）和
/// 一条 3 帧延迟 + 1 帧抖动的确定性链路。每帧每端都把自己的最近 8 帧输入
/// 连同一个确认帧、一个校验和帧发出去——这就是「伪可靠层」的全部内容。
///
///   moon run examples/two_peer
const RESEND : Int32 = 8

///|
const TOTAL : Int32 = 600

///|
const DELAY : Int32 = 3

///|
const JITTER : Int32 = 1

///|
/// 取「两端都已确认」的最高帧，比它上面的历史哈希。
fn synced(
  pa : @session.Session[@scene.Scene],
  pb : @session.Session[@scene.Scene],
) -> Bool {
  let a = pa.confirmed()
  let b = pb.confirmed()
  let c = if a < b { a } else { b }
  match (pa.hash_at(c), pb.hash_at(c)) {
    (Some(x), Some(y)) => x == y
    _ => true
  }
}

///|
fn main {
  let pa = @session.Session::with_window(@scene.Scene::new(), 0, 128)
  let pb = @session.Session::with_window(@scene.Scene::new(), 1, 128)
  let net_ab = @sim_net.NetSim::new(
    @sim_net.Link::new(DELAY, JITTER, 0, 0, 20261028UL),
  )
  let net_ba = @sim_net.NetSim::new(
    @sim_net.Link::new(DELAY, JITTER, 0, 0, 777UL),
  )
  println(
    "two_peer：两个 Session + 真实字节协议 + \{DELAY} 帧延迟 + \{JITTER} 帧抖动",
  )
  println("")
  println("frame  p0.confirm  p1.confirm  rollbacks  synced")
  let mut mismatches = 0
  let mut f = 0
  while f < TOTAL {
    f = f + 1
    ignore(pa.advance(@scene.scripted_input(f, 0)))
    ignore(pb.advance(@scene.scripted_input(f, 1)))
    let mut back = f - RESEND + 1
    if back < 1 {
      back = 1
    }
    // 每端把 [最近 RESEND 帧输入] + [确认帧] + [校验和帧] 打成一个包。
    let ab : Array[@protocol.Message] = []
    let ba : Array[@protocol.Message] = []
    let mut m = back
    while m <= f {
      ab.push(
        @protocol.Message::Input(
          @protocol.InputFrame::new(m, [@scene.scripted_input(m, 0)]),
        ),
      )
      ba.push(
        @protocol.Message::Input(
          @protocol.InputFrame::new(m, [@scene.scripted_input(m, 1)]),
        ),
      )
      m = m + 1
    }
    ab.push(
      @protocol.Message::Confirm(@protocol.ConfirmFrame::new(pa.confirmed())),
    )
    ba.push(
      @protocol.Message::Confirm(@protocol.ConfirmFrame::new(pb.confirmed())),
    )
    match pa.hash_at(pa.confirmed()) {
      Some(h) =>
        ab.push(
          @protocol.Message::Checksum(
            @protocol.ChecksumFrame::new(pa.confirmed(), h),
          ),
        )
      None => ()
    }
    match pb.hash_at(pb.confirmed()) {
      Some(h) =>
        ba.push(
          @protocol.Message::Checksum(
            @protocol.ChecksumFrame::new(pb.confirmed(), h),
          ),
        )
      None => ()
    }
    net_ab.send(f, @protocol.encode_batch(ab))
    net_ba.send(f, @protocol.encode_batch(ba))
    for payload in net_ab.recv(f) {
      mismatches = mismatches + @scene.apply(payload, pb)
    }
    for payload in net_ba.recv(f) {
      mismatches = mismatches + @scene.apply(payload, pa)
    }
    if f % 60 == 0 {
      let ok = synced(pa, pb)
      let status = if ok { "yes" } else { "NO" }
      println(
        "\{pad(f.to_string(), 7)}\{pad(pa.confirmed().to_string(), 12)}\{pad(pb.confirmed().to_string(), 12)}\{pad(pa.rollbacks().to_string() + "/" + pb.rollbacks().to_string(), 11)}\{status}",
      )
    }
  }
  // 收尾：最后一轮包还在路上，多跑几帧让确认追上。
  let mut t = TOTAL
  while t < TOTAL + 64 {
    t = t + 1
    for payload in net_ab.recv(t) {
      mismatches = mismatches + @scene.apply(payload, pb)
    }
    for payload in net_ba.recv(t) {
      mismatches = mismatches + @scene.apply(payload, pa)
    }
  }
  println("")
  println("终态：一致 = \{synced(pa, pb)}，校验失配 = \{mismatches}")
  println(
    "      回滚 = \{pa.rollbacks()}/\{pb.rollbacks()}，确认帧 = \{pa.confirmed()}/\{pb.confirmed()}",
  )
  println(
    "      丢包 = \{net_ab.dropped()}/\{net_ba.dropped()}，在途 = \{net_ab.in_flight()}/\{net_ba.in_flight()}",
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
