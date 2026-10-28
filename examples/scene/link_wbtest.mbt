///|
/// 示例层的三个示例都建在 `run_link` 上，所以要先保证它本身是对的。
test "a clean link converges with zero checksum mismatches" {
  let stats = run_link(LinkSpec::new(6, 3, 0, 0), 200, 0)
  assert_true(stats.synced)
  assert_eq(stats.first_divergence, 0)
  assert_eq(stats.mismatches, 0)
  assert_eq(stats.p0_confirmed, 200)
  assert_eq(stats.p1_confirmed, 200)
}

///|
test "an input serialization bug is caught on the exact frame" {
  let stats = run_link(LinkSpec::new(6, 3, 0, 0), 200, 40)
  assert_false(stats.synced)
  // 第 40 帧发出的输入与本地执行的不一致，分叉就从这一帧开始。
  assert_eq(stats.first_divergence, 40)
  assert_true(stats.mismatches > 0)
  assert_true(stats.hash0 != stats.hash1)
}

///|
test "rollback depth grows with delay, rollback count stays at frame count" {
  let near = run_link(LinkSpec::new(0, 0, 0, 0), 200, 0)
  let far = run_link(LinkSpec::new(12, 3, 0, 0), 200, 0)
  // 每帧都有一帧更早的输入到达，所以次数几乎等于帧数。
  assert_true(near.p0_rollbacks >= 195)
  assert_true(far.p0_rollbacks >= 195)
  // 重放的总帧数与最大深度才是真正的成本，延迟越大涨得越多。
  assert_true(far.replayed_p0 > near.replayed_p0 * 3L)
  assert_true(far.max_depth > near.max_depth)
  assert_true(near.max_depth <= 1)
}

///|
test "the same spec reproduces the same numbers" {
  let a = run_link(LinkSpec::new(6, 3, 5, 10), 150, 0)
  let b = run_link(LinkSpec::new(6, 3, 5, 10), 150, 0)
  assert_eq(a.p0_rollbacks, b.p0_rollbacks)
  assert_eq(a.p1_rollbacks, b.p1_rollbacks)
  assert_eq(a.replayed_p0, b.replayed_p0)
  assert_eq(a.max_depth, b.max_depth)
  assert_eq(a.dropped, b.dropped)
  assert_eq(a.synced, b.synced)
}

///|
test "packet loss still converges because inputs are resent" {
  let stats = run_link(LinkSpec::new(6, 3, 15, 0), 200, 0)
  assert_true(stats.dropped > 0)
  assert_true(stats.synced)
  assert_eq(stats.first_divergence, 0)
}
