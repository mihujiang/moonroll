///|
test "zero delay delivers immediately" {
  let net = NetSim::new(Link::new(0, 0, 0, 0, 1UL))
  net.send(10, b"a")
  assert_eq(net.recv(10).length(), 1)
  assert_eq(net.recv(10).length(), 0)
  assert_eq(net.delivered(), 1)
}

///|
test "fixed delay shifts arrival" {
  let net = NetSim::new(Link::new(3, 0, 0, 0, 1UL))
  net.send(5, b"x")
  assert_eq(net.recv(7).length(), 0)
  assert_eq(net.recv(8).length(), 1)
  assert_eq(net.in_flight(), 0)
}

///|
test "total loss drops everything" {
  let net = NetSim::new(Link::new(1, 0, 100, 0, 7UL))
  net.send(0, b"x")
  assert_eq(net.dropped(), 1)
  assert_eq(net.delivered(), 0)
  assert_eq(net.recv(100).length(), 0)
}

///|
test "same seed reproduces same arrival sequence" {
  let run = fn(seed : UInt64) -> Array[Int32] {
    let net = NetSim::new(Link::new(2, 3, 10, 20, seed))
    let mut t = 0
    while t < 50 {
      net.send(t, Bytes::makei(1, fn(_) { t.to_byte() }))
      t = t + 1
    }
    let out : Array[Int32] = []
    let mut now = 0
    while now < 90 {
      for p in net.recv(now) {
        out.push(p[0].to_int())
      }
      now = now + 1
    }
    out
  }

  let a = run(12345UL)
  let b = run(12345UL)
  assert_true(a.length() > 0)
  assert_eq(a.length(), b.length())
  let mut i = 0
  while i < a.length() {
    assert_eq(a[i], b[i])
    i = i + 1
  }
}

///|
test "jitter produces out of order arrival" {
  let net = NetSim::new(Link::new(1, 5, 0, 0, 42UL))
  let mut t = 0
  while t < 30 {
    net.send(t, Bytes::makei(1, fn(_) { t.to_byte() }))
    t = t + 1
  }
  let order : Array[Int32] = []
  let mut now = 0
  while now < 40 {
    for p in net.recv(now) {
      order.push(p[0].to_int())
    }
    now = now + 1
  }
  assert_eq(order.length(), 30)
  let mut inversions = 0
  let mut i = 1
  while i < order.length() {
    if order[i] < order[i - 1] {
      inversions = inversions + 1
    }
    i = i + 1
  }
  assert_true(inversions > 0)
}

///|
test "zero bandwidth means unlimited" {
  let net = NetSim::new(Link::new(0, 0, 0, 0, 1UL))
  net.send(0, Bytes::makei(4096, fn(_) { 0 }))
  assert_eq(net.throttled(), 0)
  assert_eq(net.recv(0).length(), 1)
}

///|
test "bandwidth budget is shared inside one frame" {
  let net = NetSim::new(Link::with_bandwidth(0, 0, 0, 0, 1UL, 100))
  net.send(0, Bytes::make(80, 0))
  // 同一帧只剩 20 字节：40 字节的包被限流丢弃
  net.send(0, Bytes::make(40, 0))
  // 下一帧预算重置，20 字节能过
  net.send(1, Bytes::make(20, 0))
  assert_eq(net.throttled(), 1)
  assert_eq(net.dropped(), 0)
  let a = net.recv(0)
  let b = net.recv(1)
  assert_eq(a.length(), 1)
  assert_eq(b.length(), 1)
}

///|
test "throttling does not perturb the loss stream" {
  // 限流发生在随机判定之后：同样 seed 的两条链路，一条有 1 字节预算（几乎全被限流），
  // 一条不限流，丢包次数必须一致——否则「加预算」会悄悄改掉整局的重放节奏。
  let unlimited = NetSim::new(Link::new(2, 3, 10, 20, 9UL))
  let capped = NetSim::new(Link::with_bandwidth(2, 3, 10, 20, 9UL, 1))
  let mut t = 0
  while t < 20 {
    unlimited.send(t, Bytes::make(10, 0))
    capped.send(t, Bytes::make(10, 0))
    t = t + 1
  }
  assert_true(capped.throttled() > 0)
  assert_eq(unlimited.dropped(), capped.dropped())
  // 通过随机判定的包要么上线（unlimited）要么被预算吃掉（capped），总数守恒。
  assert_eq(unlimited.dropped() + capped.throttled(), 20)
}
