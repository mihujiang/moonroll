// Blackbox 测试：验证根包聚合导出的可用性。

///|
test "aggregated exports are usable" {
  assert_eq(@moonroll.version(), "0.3.0")
  let two = @moonroll.Fixed::from_int(2)
  assert_eq(two.to_double(), 2.0)
  let s = two.sqrt().to_double()
  assert_true(s > 1.4142 && s < 1.4143)
}

///|
test "digest and input rings are reachable from the root package" {
  let d = @moonroll.Digest::new()
  d.feed_bytes(b"moonroll")
  assert_true(d.finish() != 0UL)
  let ring = @moonroll.InputRing::new(4)
  ring.set(1, 1UL)
  assert_true(ring.has(1))
}

///|
test "protocol frames are reachable from the root package" {
  let frame = @moonroll.InputFrame::new(7, [0b101UL, 0b010UL])
  let msg = @moonroll.Message::Input(frame)
  assert_true(msg == @moonroll.Message::Input(frame))
  let checksum = @moonroll.ChecksumFrame::new(9, 0xDEADBEEFUL)
  assert_eq(checksum.frame, 9)
  assert_true(@moonroll.Message::Checksum(checksum) != msg)
}

///|
test "network simulator is reachable from the root package" {
  let link = @moonroll.Link::new(2, 0, 0, 0, 1UL)
  let net = @moonroll.NetSim::new(link)
  net.send(0, b"a")
  net.send(0, b"b")
  assert_eq(net.recv(1).length(), 0)
  assert_eq(net.recv(2).length(), 2)
  assert_eq(net.delivered(), 2)
  assert_eq(net.in_flight(), 0)
}
