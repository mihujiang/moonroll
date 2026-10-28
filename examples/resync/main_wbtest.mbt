///|
/// 无丢包时：失配在事故帧上立刻报出来，一次状态请求就能修好。
test "resync repairs the laggard in one round trip" {
  let stats = run(@scene.LinkSpec::new(2, 0, 0, 0), 240, 60)
  assert_eq(stats.detected, 60)
  assert_eq(stats.repaired, 60)
  assert_eq(stats.resyncs, 1)
  assert_eq(stats.asked, 1)
  assert_eq(stats.state_bytes, 8)
  assert_eq(stats.mismatch_after, 0)
  assert_eq(stats.bad_after, 0)
  assert_eq(stats.p0_confirmed, 240)
  assert_eq(stats.p1_confirmed, 240)
}

///|
/// 有丢包时请求和应答都可能掉：靠定时重试仍然收敛，而且恢复后不再分叉。
test "resync survives a lossy link" {
  let stats = run(@scene.LinkSpec::new(3, 2, 4, 8), 300, 80)
  assert_true(stats.dropped > 0)
  assert_true(stats.detected >= 80)
  assert_true(stats.repaired >= stats.detected)
  assert_eq(stats.resyncs, 1)
  assert_eq(stats.mismatch_after, 0)
  assert_eq(stats.bad_after, 0)
  assert_eq(stats.p0_confirmed, 300)
  assert_eq(stats.p1_confirmed, 300)
}

///|
/// 没有事故就没有恢复：重同步次数必须是 0，确认帧照常追平。
test "clean run never resyncs" {
  let stats = run(@scene.LinkSpec::new(3, 2, 4, 8), 200, 0)
  assert_eq(stats.detected, 0)
  assert_eq(stats.repaired, 0)
  assert_eq(stats.resyncs, 0)
  assert_eq(stats.mismatch_before, 0)
  assert_eq(stats.bad_after, 0)
  assert_eq(stats.p0_confirmed, 200)
  assert_eq(stats.p1_confirmed, 200)
}

///|
/// 事故帧在收尾之后：这一局等价于没出过事。
test "corruption past the end changes nothing" {
  let stats = run(@scene.LinkSpec::new(2, 0, 0, 0), 120, 500)
  assert_eq(stats.detected, 0)
  assert_eq(stats.resyncs, 0)
  assert_eq(stats.p0_confirmed, 120)
  assert_eq(stats.p1_confirmed, 120)
}
