///|
/// 四人对局必须是确定性的：同样的链路参数跑两次，数字必须一模一样。
test "four peer demo is deterministic" {
  let a = run(4, 200, false)
  let b = run(4, 200, false)
  assert_eq(a.replayed, b.replayed)
  assert_eq(a.rollbacks, b.rollbacks)
  assert_eq(a.max_depth, b.max_depth)
  assert_eq(a.mismatches, b.mismatches)
  assert_eq(a.first_divergence, b.first_divergence)
  let mut i = 0
  while i < a.confirmed.length() {
    assert_eq(a.confirmed[i], b.confirmed[i])
    i = i + 1
  }
}

///|
test "four peer demo stays in sync and confirms every frame" {
  let s = run(4, 240, false)
  assert_eq(s.first_divergence, -1)
  assert_eq(s.mismatches, 0)
  assert_eq(s.confirmed.length(), 4)
  let mut i = 0
  while i < s.confirmed.length() {
    assert_eq(s.confirmed[i], 240)
    i = i + 1
  }
  // 链路上确实发生了回滚，否则这个示例什么也没证明
  assert_true(s.rollbacks > 0L)
  assert_true(s.replayed > 0L)
}

///|
test "more players cost more replays" {
  let two = run(2, 240, false)
  let four = run(4, 240, false)
  assert_true(four.replayed > two.replayed)
}
