///|
/// 测试用模拟器：两个玩家的输入都混入同一个 64 位状态。
/// 用 UInt64 是为了让乘法自然回绕，避免 Int64 溢出。
struct Counter {
  mut x : UInt64
}

///|
impl @session.Sim for Counter with fn save(self) -> Bytes {
  Bytes::makei(8, fn(i) { ((self.x >> (i * 8)) & 0xFFUL).to_int().to_byte() })
}

///|
impl @session.Sim for Counter with fn restore(self, bytes : Bytes) -> Unit {
  let mut x = 0UL
  let mut i = 0
  while i < 8 {
    x = x | (bytes[i].to_int().to_uint64() << (i * 8))
    i = i + 1
  }
  self.x = x
}

///|
impl @session.Sim for Counter with fn step(self, a : UInt64, b : UInt64) -> Unit {
  self.x = self.x * 31UL + (a & 0xFFUL) + ((b & 0xFFUL) << 32)
}

///|
impl @session.Sim for Counter with fn hash(self) -> UInt64 {
  @digest.hash_u64(self.x)
}

///|
fn input_of(frame : Int32, salt : Int32) -> UInt64 {
  (frame.to_uint64() * 2654435761UL + salt.to_uint64() * 97UL) & 0xFFUL
}

///|
test "single session without remote input keeps no rollback" {
  let s = @session.Session::new({ x: 0UL, }, 0)
  let mut f = 0
  while f < 100 {
    f = f + 1
    ignore(s.advance(input_of(f, 0)))
  }
  assert_eq(s.frame(), 100)
  assert_eq(s.rollbacks(), 0)
  assert_eq(s.confirmed(), 0)
}

///|
test "two peers converge under 2 frame delay over 3000 frames" {
  let total = 3000
  let delay = 2
  let a = @session.Session::with_window({ x: 0UL, }, 0, 128)
  let b = @session.Session::with_window({ x: 0UL, }, 1, 128)
  let mut f = 0
  while f < total {
    f = f + 1
    ignore(a.advance(input_of(f, 0)))
    ignore(b.advance(input_of(f, 1)))
    let d = f - delay
    if d >= 1 {
      a.receive(d, input_of(d, 1))
      b.receive(d, input_of(d, 0))
    }
  }
  let mut d = total - delay + 1
  while d <= total {
    a.receive(d, input_of(d, 1))
    b.receive(d, input_of(d, 0))
    d = d + 1
  }
  let gold = { x: 0UL, }
  let mut g = 1
  while g <= total {
    @session.Sim::step(gold, input_of(g, 0), input_of(g, 1))
    g = g + 1
  }
  assert_eq(a.hash(), @session.Sim::hash(gold))
  assert_eq(b.hash(), @session.Sim::hash(gold))
  assert_true(a.rollbacks() > 0)
  assert_eq(a.confirmed(), total)
  assert_eq(b.confirmed(), total)
}

///|
test "jittery out of order delivery still converges" {
  let total = 600
  let a = @session.Session::with_window({ x: 0UL, }, 0, 128)
  let b = @session.Session::with_window({ x: 0UL, }, 1, 128)
  // 每帧的到达抖动 0..3，乱序但不丢包
  let jitter = [0, 2, 1, 3, 2, 0, 3, 1]
  fn arrive_at(m : Int32) -> Int32 {
    m + jitter[m % 8]
  }

  let mut f = 0
  while f < total {
    f = f + 1
    ignore(a.advance(input_of(f, 0)))
    ignore(b.advance(input_of(f, 1)))
    let mut m = if f < 4 { 1 } else { f - 3 }
    while m <= f {
      if arrive_at(m) == f {
        a.receive(m, input_of(m, 1))
        b.receive(m, input_of(m, 0))
      }
      m = m + 1
    }
  }
  let mut m = 1
  while m <= total {
    if a.player_input(1, m) is None {
      a.receive(m, input_of(m, 1))
    }
    if b.player_input(0, m) is None {
      b.receive(m, input_of(m, 0))
    }
    m = m + 1
  }
  let gold = { x: 0UL, }
  let mut g = 1
  while g <= total {
    @session.Sim::step(gold, input_of(g, 0), input_of(g, 1))
    g = g + 1
  }
  assert_eq(a.hash(), @session.Sim::hash(gold))
  assert_eq(b.hash(), @session.Sim::hash(gold))
}

///|
test "snapshot ring evicts overwritten frames" {
  let r = @session.SnapshotRing::new(3)
  r.set(10, b"a")
  assert_true(r.get(10) is Some(_))
  r.set(13, b"d")
  assert_true(r.get(10) is None)
  assert_true(r.get(13) is Some(_))
  assert_eq(r.get(12), None)
}
