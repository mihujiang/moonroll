///|
/// 端到端验收：200 ms 单向延迟 + 50 ms 抖动 + 10% 乱序，两个物理世界
/// 互发输入、互相回滚，最终在已确认帧上逐位一致。
test "jittery reordered link still converges on confirmed frames" {
  let d = new_demo(12, 3, 0, 10)
  let mut i = 1
  while i <= 600 {
    let (p0, p1) = scripted(i)
    d.tick(p0, p1)
    i = i + 1
  }
  let mut tail = 0
  while tail < 120 {
    let (p0, p1) = scripted(600)
    d.tick(p0, p1)
    tail = tail + 1
  }
  assert_eq(d.desyncs, 0)
  assert_true(d.sessions[0].confirmed() >= 600)
  assert_true(d.sessions[1].confirmed() >= 600)
  assert_eq(d.sessions[0].hash(), d.sessions[1].hash())
}

///|
/// 丢包必须由重发兜住：15% 丢包下回滚次数大于零，但两端仍然收敛。
test "packet loss causes rollbacks without divergence" {
  let d = new_demo(12, 3, 15, 10)
  let mut i = 1
  while i <= 600 {
    let (p0, p1) = scripted(i)
    d.tick(p0, p1)
    i = i + 1
  }
  let mut tail = 0
  while tail < 180 {
    let (p0, p1) = scripted(600)
    d.tick(p0, p1)
    tail = tail + 1
  }
  assert_eq(d.desyncs, 0)
  assert_true(d.sessions[0].rollbacks() > 0)
  assert_true(d.sessions[0].confirmed() >= 600)
}
