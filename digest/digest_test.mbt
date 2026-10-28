// Whitebox 测试：FNV-1a 64 的已知向量与字节序稳定性。

///|
test "fnv1a 64 known vector: hello" {
  // FNV-1a 64("hello") = 0xa430d84680aabd0b
  let d = Digest::new()
  d.feed_bytes(b"hello")
  assert_eq(d.finish(), 0xa430d84680aabd0bUL)
}

///|
test "fnv1a 64 known vector: empty" {
  let d = Digest::new()
  d.feed_bytes(b"")
  assert_eq(d.finish(), 0xcbf29ce484222325UL)
}

///|
test "feed_u64 is little endian" {
  let a = Digest::new()
  a.feed_u64(0x0102030405060708UL)
  let b = Digest::new()
  for byte in [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01] {
    b.feed_byte(byte)
  }
  assert_eq(a.finish(), b.finish())
}

///|
test "feed_i64 matches reinterpreted u64" {
  let a = Digest::new()
  a.feed_i64(-1L)
  let b = Digest::new()
  b.feed_u64(0xFFFFFFFFFFFFFFFFUL)
  assert_eq(a.finish(), b.finish())
}

///|
test "order matters" {
  let a = Digest::new()
  a.feed_u64(1UL)
  a.feed_u64(2UL)
  let b = Digest::new()
  b.feed_u64(2UL)
  b.feed_u64(1UL)
  assert_true(a.finish() != b.finish())
}
