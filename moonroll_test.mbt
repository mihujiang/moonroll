// Blackbox 测试：验证根包聚合导出的可用性。

///|
test "aggregated exports are usable" {
  assert_eq(@moonroll.version(), "0.1.0")
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
