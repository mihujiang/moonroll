///|
/// 基准用的帧游标：闭包内需要自增，用带可变字段的结构体承载。
struct BenchCursor {
  mut f : Int32
}

///|
/// 建一个已经预热到 `warm` 帧的会话，保证后续 `receive` 的帧号为正。
///
/// `window` 必须大于回滚深度，否则 `replay_from` 会直接放弃该次回滚。
fn bench_session(
  warm : Int32,
  window : Int32,
) -> (@session.Session[Counter], BenchCursor) {
  let s = @session.Session::with_window({ x: 0UL, }, 0, window)
  let mut w = 0
  while w < warm {
    w = w + 1
    ignore(s.advance(input_of(w, 0)))
  }
  (s, { f: warm, })
}

///|
/// 确认基准场景真的触发了回滚，否则计时的只是一次 `advance`。
test "bench scenario really rolls back" {
  let depth = 16
  let (s, cur) = bench_session(depth, 128)
  let before = s.rollbacks()
  cur.f = cur.f + 1
  ignore(s.advance(input_of(cur.f, 0)))
  let target = cur.f - depth
  s.receive(target, input_of(target, 1))
  assert_true(s.rollbacks() > before)
}

///|
/// 每帧一次「预测 + 深度 16 的回滚重放」的成本。
///
/// 运行：`moon bench -p weopqrst/moonroll/session`
test "bench: predict + 16 frame rollback" (it : @bench.T) {
  let depth = 16
  let (s, cur) = bench_session(depth, 128)
  it.bench(fn() {
    cur.f = cur.f + 1
    ignore(s.advance(input_of(cur.f, 0)))
    let target = cur.f - depth
    if s.player_input(1, target) is None {
      s.receive(target, input_of(target, 1))
    }
  })
}

///|
/// 每帧一次「预测 + 深度 128 的回滚重放」的成本。
test "bench: predict + 128 frame rollback" (it : @bench.T) {
  let depth = 128
  let (s, cur) = bench_session(depth, 256)
  it.bench(fn() {
    cur.f = cur.f + 1
    ignore(s.advance(input_of(cur.f, 0)))
    let target = cur.f - depth
    if s.player_input(1, target) is None {
      s.receive(target, input_of(target, 1))
    }
  })
}
