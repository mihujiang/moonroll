///|
/// V0.2 冒烟示例：定点数、状态哈希、输入环、回滚会话。
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
impl @session.Sim for Demo with fn step(self, a : UInt64, b : UInt64) -> Unit {
  self.x = self.x * 31UL + (a & 0xFFUL) + ((b & 0xFFUL) << 32)
}

///|
impl @session.Sim for Demo with fn hash(self) -> UInt64 {
  @digest.hash_u64(self.x)
}

///|
fn input_of(frame : Int, salt : Int) -> UInt64 {
  (frame.to_uint64() * 2654435761UL + salt.to_uint64() * 97UL) & 0xFFUL
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
  let pa = @session.Session::with_window({ x: 0UL }, 0, 128)
  let pb = @session.Session::with_window({ x: 0UL }, 1, 128)
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
  println("moonroll version    = " + @moonroll.version())
}
