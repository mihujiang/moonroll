///|
/// desync_demo：证明分叉检测真的会响。
///
///   moon run examples/desync_demo
///
/// 先跑一局正常的，确认「没有分叉」不是靠什么都不检查；再让 P1 在第 100 帧
/// 「本地执行 A、发出去的是 B」，看检测器能否在正确的帧上报出来。
///
/// 现实里对应的是序列化 bug、两端版本不一致、漏同步了某个字段。注意不能
/// 直接去改内存里的状态——回滚会从快照恢复重放，把它洗掉。
const FRAMES : Int32 = 300

///|
const CORRUPT_AT : Int32 = 100

///|
fn main {
  // 100ms 延迟 + 50ms 抖动的链路，两条场景用同一组参数。
  let spec = @scene.LinkSpec::new(6, 3, 0, 0)
  println("desync_demo：分叉检测器自证")
  println("")
  let clean = @scene.run_link(spec, FRAMES, 0)
  println("场景 A · 正常对局")
  println(
    "  分叉帧 = \{frame_or_dash(clean.first_divergence)}，一致 = \{clean.synced}",
  )
  println(
    "  校验失配 = \{clean.mismatches}，回滚 = \{clean.p0_rollbacks}/\{clean.p1_rollbacks}",
  )
  println("")
  let broken = @scene.run_link(spec, FRAMES, CORRUPT_AT)
  println(
    "场景 B · 第 \{CORRUPT_AT} 帧 P1 发出去的输入与本地执行的输入不一致",
  )
  println(
    "  分叉帧 = \{frame_or_dash(broken.first_divergence)}（从这一帧起两端世界不同）",
  )
  println("  P0 hash  = \{broken.hash0}")
  println("  P1 hash  = \{broken.hash1}")
  println(
    "  校验失配 = \{broken.mismatches}（P1 发出的 Checksum 与 P0 的历史哈希不符）",
  )
  println("  一致 = \{broken.synced}")
  println("")
  if clean.synced && !broken.synced && broken.first_divergence > 0 {
    println(
      "结论：正常局不报警，篡改后在同一帧上被两端同时发现——检测是可用的。",
    )
  } else {
    println(
      "失败：检测器没能区分正常与异常，这本身就是一个 bug。",
    )
  }
}

///|
fn frame_or_dash(frame : Int32) -> String {
  if frame == 0 {
    "-"
  } else {
    frame.to_string()
  }
}
