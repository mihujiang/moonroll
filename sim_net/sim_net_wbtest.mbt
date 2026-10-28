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
