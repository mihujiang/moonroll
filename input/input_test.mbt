// Whitebox 测试：环形缓冲的读写、覆盖与未命中。

///|
test "set then get" {
  let ring = @input.InputRing::new(8)
  ring.set(3, 0b1010UL)
  assert_eq(ring.get(3), Some(0b1010UL))
  assert_true(ring.has(3))
}

///|
test "missing frame returns none" {
  let ring = @input.InputRing::new(8)
  assert_eq(ring.get(5), None)
  assert_false(ring.has(5))
}

///|
test "capacity is clamped to at least one" {
  let ring = @input.InputRing::new(0)
  assert_eq(ring.capacity(), 1)
  ring.set(0, 1UL)
  assert_eq(ring.get(0), Some(1UL))
}

///|
test "wrap around keeps recent frames only" {
  let ring = @input.InputRing::new(4)
  let mut frame = 0
  while frame < 10 {
    ring.set(frame, frame.to_uint64())
    frame += 1
  }
  // 最近 4 帧仍在
  for f in [6, 7, 8, 9] {
    assert_eq(ring.get(f), Some(f.to_uint64()))
  }
  // 更早的帧已被覆盖，不能误命中（槽位相同但帧号不同）
  assert_eq(ring.get(5), None)
  assert_eq(ring.get(1), None)
}

///|
test "negative frame does not panic" {
  let ring = @input.InputRing::new(4)
  ring.set(-1, 7UL)
  assert_eq(ring.get(-1), Some(7UL))
  assert_eq(ring.get(3), None)
}
