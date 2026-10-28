///|
/// 宣布掉线之后，确认帧必须能继续前进；不宣布就只能卡在掉线前那一帧。
test "announcing a drop unblocks confirmation" {
  let stuck = run(false, 240, false)
  assert_eq(stuck.declared_at, 0)
  assert_eq(stuck.confirmed[0], 200)
  assert_eq(stuck.confirmed[1], 200)
  assert_eq(stuck.confirmed[2], 200)
  let live = run(true, 240, false)
  assert_true(live.declared_at > 200)
  assert_eq(live.confirmed[0], 240)
  assert_eq(live.confirmed[1], 240)
  assert_eq(live.confirmed[2], 240)
  // 掉线者自己还停在掉线前——它已经不在这个房间里了。
  assert_eq(live.confirmed[3], 200)
}

///|
/// 掉线是一个人离开，不该把剩下的人拖进分叉。
test "remaining peers agree after a drop" {
  let live = run(true, 240, false)
  assert_eq(live.first_divergence, -1)
  assert_eq(live.mismatches, 0)
  // 链路上确实发生了回滚，示例才有说服力
  assert_true(live.rollbacks > 0L)
  assert_true(live.replayed > 0L)
}

///|
/// 掉线语义把「为一个永远不来的输入付钱」变成「少等一个人」：
/// 重放量应当明显下降。
test "dropping a peer cuts the replay bill" {
  let stuck = run(false, 240, false)
  let live = run(true, 240, false)
  assert_true(live.replayed < stuck.replayed)
  assert_true(live.rollbacks < stuck.rollbacks)
}

///|
/// 同一套链路参数跑两遍，数字必须一模一样。
test "drop demo is deterministic" {
  let a = run(true, 240, false)
  let b = run(true, 240, false)
  assert_eq(a.declared_at, b.declared_at)
  assert_eq(a.rollbacks, b.rollbacks)
  assert_eq(a.replayed, b.replayed)
  assert_eq(a.mismatches, b.mismatches)
  assert_eq(a.first_divergence, b.first_divergence)
  let mut i = 0
  while i < a.confirmed.length() {
    assert_eq(a.confirmed[i], b.confirmed[i])
    i = i + 1
  }
}
