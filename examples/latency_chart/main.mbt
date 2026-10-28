///|
/// latency_chart：把 8 条典型链路跑一遍，输出一张可以直接贴进文档的表格。
///
///   moon run examples/latency_chart
///
/// 关心的不是「能不能连上」，而是：延迟变差时回滚次数怎么涨、两端会不会分叉。
const FRAMES : Int32 = 300

///|
struct Case {
  name : String
  spec : @scene.LinkSpec
}

///|
fn main {
  let cases : Array[Case] = [
    { name: "局域网 16ms", spec: @scene.LinkSpec::new(0, 0, 0, 0), },
    { name: "同城 33ms", spec: @scene.LinkSpec::new(2, 0, 0, 0), },
    { name: "跨城 100ms", spec: @scene.LinkSpec::new(6, 0, 0, 0), },
    { name: "跨城 100ms ±50ms", spec: @scene.LinkSpec::new(6, 3, 0, 0), },
    {
      name: "跨城 100ms +10% 乱序",
      spec: @scene.LinkSpec::new(6, 3, 0, 10),
    },
    { name: "跨城 100ms +5% 丢包", spec: @scene.LinkSpec::new(6, 3, 5, 0), },
    { name: "跨洋 200ms ±50ms", spec: @scene.LinkSpec::new(12, 3, 0, 0), },
    {
      name: "跨洋 200ms ±50ms +25% 乱序",
      spec: @scene.LinkSpec::new(12, 3, 0, 25),
    },
  ]
  println("")
  println(
    "| 场景 | 延迟 | 抖动 | 丢包 | 乱序 | 回滚次数 | 重放帧数 | 最大深度 | 确认帧 | 分叉帧 | 一致 |",
  )
  println("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
  let mut all_synced = true
  for c in cases {
    let stats = @scene.run_link(c.spec, FRAMES, 0)
    if !stats.synced {
      all_synced = false
    }
    println(row(c, stats))
  }
  println("")
  println(
    "说明：延迟 / 抖动单位是逻辑帧（60fps → 1 帧 ≈ 16.7ms），丢包 / 乱序是百分比。",
  )
  println(
    "「分叉帧」显示首个「两端都已确认但状态不同」的帧号，`-` 表示没有发现分叉。",
  )
  println("")
  println(
    if all_synced {
      "结论：8 条链路全部收敛。回滚次数恒等于帧数（每帧都会收到一帧更早的输入），" +
      "真正随延迟增长的是「重放帧数」与「最大深度」——那就是 CPU 成本。"
    } else {
      "警告：存在未收敛的链路，说明同步逻辑有 bug。"
    },
  )
}

///|
fn row(c : Case, stats : @scene.LinkStats) -> String {
  let divergence = if stats.first_divergence == 0 {
    "-"
  } else {
    stats.first_divergence.to_string()
  }
  let ok = if stats.synced { "yes" } else { "NO" }
  "| " +
  c.name +
  " | " +
  c.spec.delay.to_string() +
  " | " +
  c.spec.jitter.to_string() +
  " | " +
  c.spec.loss.to_string() +
  "% | " +
  c.spec.reorder.to_string() +
  "% | " +
  stats.p0_rollbacks.to_string() +
  " | " +
  stats.replayed_p0.to_string() +
  " | " +
  stats.max_depth.to_string() +
  " | " +
  stats.p0_confirmed.to_string() +
  "/" +
  stats.p1_confirmed.to_string() +
  " | " +
  divergence +
  " | " +
  ok +
  " |"
}
