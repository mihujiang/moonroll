///|
/// 五种发包策略喂给同一套会话，结果必须完全一样——只是字节数不同。
test "all packing policies stay in sync" {
  let spec = @scene.LinkSpec::new(3, 1, 5, 10)
  let modes : Array[Packing] = [Legacy, Span, Masked, Adaptive, Lean]
  let mut i = 0
  while i < modes.length() {
    let st = run(modes[i], spec, 240)
    assert_eq(st.first_divergence, -1)
    assert_eq(st.mismatches, 0)
    let mut k = 0
    while k < 4 {
      assert_eq(st.confirmed[k], 240)
      k = k + 1
    }
    i = i + 1
  }
}

///|
/// 同一内容、同样链路，四种打包方式的行为统计必须逐项相等：
/// 省下来的只能是字节。
test "packing does not change simulation behaviour" {
  let spec = @scene.LinkSpec::new(3, 1, 5, 10)
  let base = run(Legacy, spec, 240)
  let modes : Array[Packing] = [Span, Masked, Adaptive, Lean]
  for m in modes {
    let st = run(m, spec, 240)
    assert_eq(st.rollbacks, base.rollbacks)
    assert_eq(st.replayed, base.replayed)
    assert_eq(st.first_divergence, base.first_divergence)
  }
}

///|
/// 带宽应当一路往下走：区间帧 > 掩码 > 对端水位 > 校验和降频。
test "each step costs fewer bytes" {
  let spec = @scene.LinkSpec::new(3, 1, 5, 10)
  let legacy = run(Legacy, spec, 240)
  let span = run(Span, spec, 240)
  let masked = run(Masked, spec, 240)
  let adaptive = run(Adaptive, spec, 240)
  let lean = run(Lean, spec, 240)
  assert_true(span.bytes < legacy.bytes)
  assert_true(masked.bytes < span.bytes)
  assert_true(adaptive.bytes < masked.bytes)
  assert_true(lean.bytes < adaptive.bytes)
  // 光是把 16 条头压成 1 条，就该省掉一半以上
  assert_true(span.bytes * 2L < legacy.bytes)
}

///|
/// 延迟比冗余还大、丢包 25% 的链路：自适应区间会撑开，但确认帧照样追平。
test "lean survives a link worse than its redundancy" {
  let spec = @scene.LinkSpec::new(10, 2, 25, 15)
  let st = run(Lean, spec, 240)
  assert_eq(st.first_divergence, -1)
  let mut k = 0
  while k < 4 {
    assert_eq(st.confirmed[k], 240)
    k = k + 1
  }
}

///|
test "bandwidth run is deterministic" {
  let spec = @scene.LinkSpec::new(2, 2, 10, 20)
  let a = run(Lean, spec, 200)
  let b = run(Lean, spec, 200)
  assert_eq(a.bytes, b.bytes)
  assert_eq(a.packets, b.packets)
  assert_eq(a.frames_carried, b.frames_carried)
  assert_eq(a.rollbacks, b.rollbacks)
  assert_eq(a.replayed, b.replayed)
  assert_eq(a.first_divergence, b.first_divergence)
  let mut k = 0
  while k < a.confirmed.length() {
    assert_eq(a.confirmed[k], b.confirmed[k])
    k = k + 1
  }
}
