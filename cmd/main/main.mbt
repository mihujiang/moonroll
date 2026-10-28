///|
/// V0.3 冒烟示例：定点数、状态哈希、输入环、回滚会话、字节协议、确定性链路。
///
/// 运行：
///   moon run cmd/main --target wasm-gc
///
/// 模型：两个玩家的输入都混入同一个 64 位状态，用来验证两端收敛。
struct Demo {
  mut x : UInt64
}

///|
impl @session.Sim for Demo with fn save(self) -> Bytes {
  Bytes::makei(8, fn(i) { ((self.x >> (i * 8)) & 0xFFUL).to_int().to_byte() })
}

///|
impl @session.Sim for Demo with fn restore(self, bytes : Bytes) -> Unit {
  let mut x = 0UL
  let mut i = 0
  while i < 8 {
    x = x | (bytes[i].to_int().to_uint64() << (i * 8))
    i = i + 1
  }
  self.x = x
}

///|
impl @session.Sim for Demo with fn step_players(self, inputs : Array[UInt64]) -> Unit {
  let mut x = self.x * 31UL
  let mut i = 0
  for bits in inputs {
    x = x + ((bits & 0xFFUL) << (i * 8))
    i = i + 1
  }
  self.x = x
}

///|
impl @session.Sim for Demo with fn hash(self) -> UInt64 {
  @digest.hash_u64(self.x)
}

///|
fn input_of(frame : Int32, salt : Int32) -> UInt64 {
  (frame.to_uint64() * 2654435761UL + salt.to_uint64() * 97UL) & 0xFFUL
}

///|
/// 把一条线上的字节解成消息，投递给会话。
fn apply(payload : Bytes, s : @session.Session[Demo]) -> Unit {
  for msg in @protocol.decode_batch(payload) {
    match msg {
      @protocol.Input(x) => {
        let mut i = 0
        for bits in x.inputs {
          s.receive_from(x.player + i, x.frame, bits)
          i = i + 1
        }
      }
      _ => ()
    }
  }
}

///|
fn main {
  // 1) 定点数：整数运算，跨后端逐位一致
  let a = @fixed.Fixed::from_double(1.5)
  let b = @fixed.Fixed::from_double(2.25)
  println("fixed 1.5 * 2.25 = " + (a * b).to_double().to_string())
  println(
    "fixed sqrt(2)     = " +
    @fixed.Fixed::from_int(2).sqrt().to_double().to_string(),
  )
  println(
    "fixed lerp(0,10,.3)= " +
    @fixed.lerp(
      @fixed.Fixed::from_int(0),
      @fixed.Fixed::from_int(10),
      @fixed.Fixed::from_double(0.3),
    )
    .to_double()
    .to_string(),
  )
  // 2) 状态哈希：回滚两侧比对
  let d = @digest.Digest::new()
  d.feed_bytes(b"hello")
  println("digest fnv1a(hello) = " + d.finish().to_string())
  // 3) 输入环：按帧号随机存取
  let ring = @input.InputRing::new(8)
  ring.set(42, 0b101UL)
  match ring.get(42) {
    Some(bits) => println("input frame 42      = " + bits.to_string())
    None => println("input frame 42      = missing")
  }
  // 4) 回滚会话：2 帧延迟下两个对等体跑 300 帧后状态一致
  let total = 300
  let delay = 2
  let pa = @session.Session::with_window({ x: 0UL, }, 0, 128)
  let pb = @session.Session::with_window({ x: 0UL, }, 1, 128)
  let mut f = 0
  while f < total {
    f = f + 1
    ignore(pa.advance(input_of(f, 0)))
    ignore(pb.advance(input_of(f, 1)))
    let arrived = f - delay
    if arrived >= 1 {
      pa.receive(arrived, input_of(arrived, 1))
      pb.receive(arrived, input_of(arrived, 0))
    }
  }
  let mut drain = total - delay + 1
  while drain <= total {
    pa.receive(drain, input_of(drain, 1))
    pb.receive(drain, input_of(drain, 0))
    drain = drain + 1
  }
  println(
    "rollback peers equal = " +
    (pa.hash() == pb.hash()).to_string() +
    ", rollbacks = " +
    pa.rollbacks().to_string() +
    ", frames = " +
    pa.frame().to_string(),
  )
  // 5) 字节协议：输入帧 4 字节、确认帧 3 字节、校验和帧 10 字节
  let wire = @protocol.InputFrame::new(1000, [0b101UL, 0b010UL])
  let payload = @protocol.encode(@protocol.Message::Input(wire))
  println("protocol input      = " + payload.length().to_string() + " bytes")
  println(
    "protocol round-trip = " +
    (@protocol.decode(payload) == Some(@protocol.Message::Input(wire))).to_string(),
  )
  // 6) 确定性链路：延迟 6 帧 + 抖动 3 帧 + 10% 乱序，包体走真实字节协议
  let total_net = 300
  let resend = 16
  let net_ab = @sim_net.NetSim::new(@sim_net.Link::new(6, 3, 0, 10, 20261028UL))
  let net_ba = @sim_net.NetSim::new(@sim_net.Link::new(6, 3, 0, 10, 777UL))
  let na = @session.Session::with_window({ x: 0UL, }, 0, 128)
  let nb = @session.Session::with_window({ x: 0UL, }, 1, 128)
  let mut n = 0
  while n < total_net {
    n = n + 1
    ignore(na.advance(input_of(n, 0)))
    ignore(nb.advance(input_of(n, 1)))
    // 每个包夹带最近 `resend` 帧的输入，充当伪可靠层
    let mut back = n - resend + 1
    if back < 1 {
      back = 1
    }
    let ab : Array[@protocol.Message] = []
    let ba : Array[@protocol.Message] = []
    let mut m = back
    while m <= n {
      ab.push(
        @protocol.Message::Input(
          @protocol.InputFrame::new_from(0, m, [input_of(m, 0)]),
        ),
      )
      ba.push(
        @protocol.Message::Input(
          @protocol.InputFrame::new_from(1, m, [input_of(m, 1)]),
        ),
      )
      m = m + 1
    }
    net_ab.send(n, @protocol.encode_batch(ab))
    net_ba.send(n, @protocol.encode_batch(ba))
    for p in net_ab.recv(n) {
      apply(p, nb)
    }
    for p in net_ba.recv(n) {
      apply(p, na)
    }
  }
  // 收尾：再推进若干帧，让在途与乱序的包全部送达
  let mut t = total_net
  while t < total_net + 64 {
    t = t + 1
    for p in net_ab.recv(t) {
      apply(p, nb)
    }
    for p in net_ba.recv(t) {
      apply(p, na)
    }
  }
  println(
    "sim_net peers equal = " +
    (na.hash() == nb.hash()).to_string() +
    ", confirmed = " +
    na.confirmed().to_string() +
    "/" +
    nb.confirmed().to_string() +
    ", rollbacks = " +
    na.rollbacks().to_string() +
    "/" +
    nb.rollbacks().to_string(),
  )
  println(
    "sim_net packets     = delivered " +
    net_ab.delivered().to_string() +
    ", dropped " +
    net_ab.dropped().to_string() +
    ", in_flight " +
    net_ab.in_flight().to_string(),
  )
  println("moonroll version    = " + @moonroll.version())
}
