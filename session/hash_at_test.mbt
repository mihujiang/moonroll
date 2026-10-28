///|
/// 历史哈希只应反映「重放之后」的结果，且超出快照窗口后自然失效。
test "hash_at follows replay and expires outside the window" {
  let s = @session.Session::with_window({ x: 0UL, }, 0, 4)
  let mut f = 0
  while f < 3 {
    f = f + 1
    ignore(s.advance(input_of(f, 0)))
  }
  assert_eq(s.hash_at(3), Some(s.hash()))
  let before = s.hash_at(2).unwrap()
  // 对端第 2 帧的输入迟到：回滚到帧 1 并重放 2..3。
  s.receive(2, 7UL)
  assert_eq(s.rollbacks(), 1)
  assert_eq(s.hash_at(3), Some(s.hash()))
  assert_true(s.hash_at(2).unwrap() != before)
  // 容量 = 窗口 * 2 + 2 = 10，继续推进后帧 3 的槽位被覆盖。
  let mut i = 0
  while i < 40 {
    i = i + 1
    ignore(s.advance(1UL))
  }
  assert_eq(s.hash_at(3), None)
}

///|
/// 同一帧在两端的哈希必须一致：这是「世界没分叉」的唯一判据。
test "confirmed frames hash identically on both peers" {
  let a = @session.Session::with_window({ x: 0UL, }, 0, 128)
  let b = @session.Session::with_window({ x: 0UL, }, 1, 128)
  let mut f = 0
  while f < 200 {
    f = f + 1
    ignore(a.advance(input_of(f, 0)))
    ignore(b.advance(input_of(f, 1)))
    // 3 帧单向延迟
    if f > 3 {
      a.receive(f - 3, input_of(f - 3, 1))
      b.receive(f - 3, input_of(f - 3, 0))
    }
  }
  let c = if a.confirmed() < b.confirmed() {
    a.confirmed()
  } else {
    b.confirmed()
  }
  assert_true(c > 150)
  let mut g = c - 20
  while g <= c {
    assert_eq(a.hash_at(g), b.hash_at(g))
    g = g + 1
  }
}
