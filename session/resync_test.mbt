///|
/// 全量重同步的测试用模拟器：状态是一个 64 位计数器，任何一路输入的差异
/// 都会保留在状态里（乘法扩散），所以「分叉」是真实发生且不可自愈的。
struct Board {
  mut w : UInt64
}

///|
impl @session.Sim for Board with fn save(self) -> Bytes {
  Bytes::makei(8, fn(i) { ((self.w >> (i * 8)) & 0xFFUL).to_int().to_byte() })
}

///|
impl @session.Sim for Board with fn restore(self, bytes : Bytes) -> Unit {
  let mut v = 0UL
  let mut i = 0
  while i < 8 {
    v = v | (bytes[i].to_int().to_uint64() << (i * 8))
    i = i + 1
  }
  self.w = v
}

///|
impl @session.Sim for Board with fn step_players(self, inputs : Array[UInt64]) -> Unit {
  let mut v = self.w * 6364136223846793005UL + 1UL
  let mut i = 0
  for bits in inputs {
    v = v + ((bits & 0xFFUL) << (i * 8))
    i = i + 1
  }
  self.w = v ^ (v >> 29)
}

///|
impl @session.Sim for Board with fn hash(self) -> UInt64 {
  @digest.hash_u64(self.w)
}

///|
fn board_input(frame : Int32, player : Int32) -> UInt64 {
  (frame.to_uint64() * 2654435761UL + player.to_uint64() * 1237UL) & 0xFFUL
}

///|
fn make_boards(n : Int32, window : Int32) -> Array[@session.Session[Board]] {
  let out : Array[@session.Session[Board]] = []
  let mut i = 0
  while i < n {
    out.push(@session.Session::with_players({ w: 0UL, }, n, i, window))
    i = i + 1
  }
  out
}

///|
/// 推进一帧：所有人先把别人这一帧的输入投递进来，再各自本地推进。
fn step_frame(s : Array[@session.Session[Board]], n : Int32, f : Int32) -> Unit {
  let mut k = 0
  while k < n {
    let mut j = 0
    while j < n {
      if j != k {
        s[k].receive_from(j, f, board_input(f, j))
      }
      j = j + 1
    }
    ignore(s[k].advance(board_input(f, k)))
    k = k + 1
  }
}

///|
fn state_at(s : @session.Session[Board], frame : Int32) -> Bytes raise {
  match s.export_state(frame) {
    Some(b) => b
    None => {
      assert_true(false)
      Bytes::new(0)
    }
  }
}

///|
fn bytes_equal(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut i = 0
  while i < a.length() {
    if a[i] != b[i] {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// 分叉之后用对端的状态整段替换：恢复点及之后逐帧哈希重新一致，
/// 而且继续推进也不会再分叉。
test "resync heals a forked session" {
  let n : Int32 = 3
  let s = make_boards(n, 64)
  let mut f = 0
  while f < 30 {
    f = f + 1
    step_frame(s, n, f)
  }
  assert_eq(s[0].hash_at(30), s[1].hash_at(30))
  // 第 31 帧：0 号本地执行真值，但发出去的是被改过的值。
  // 收到坏值的一端从此活在另一个世界里，回滚也救不回来。
  let good = board_input(31, 0)
  let bad = good ^ 1UL
  s[1].receive_from(0, 31, bad)
  s[2].receive_from(0, 31, bad)
  s[0].receive_from(1, 31, board_input(31, 1))
  s[0].receive_from(2, 31, board_input(31, 2))
  s[1].receive_from(2, 31, board_input(31, 2))
  s[2].receive_from(1, 31, board_input(31, 1))
  ignore(s[0].advance(good))
  ignore(s[1].advance(board_input(31, 1)))
  ignore(s[2].advance(board_input(31, 2)))
  f = 31
  while f < 60 {
    f = f + 1
    step_frame(s, n, f)
  }
  assert_true(s[0].hash_at(60) != s[1].hash_at(60))
  assert_eq(s[1].hash_at(60), s[2].hash_at(60))
  // 1 号手里有权威状态（它照原样执行了 0 号的输入）：把 55 帧整段交给 0 号。
  let before_confirmed = s[0].confirmed()
  assert_true(s[0].resync_from(55, state_at(s[1], 55)))
  assert_eq(s[0].resyncs(), 1)
  assert_eq(s[0].hash_at(55), s[1].hash_at(55))
  // 恢复点之后的帧用本端输入环重放，结果必须与权威端逐帧一致。
  assert_eq(s[0].hash_at(60), s[1].hash_at(60))
  // 确认帧只前进，不被重同步拽回去。
  assert_true(s[0].confirmed() >= before_confirmed)
  // 本地输入环不受影响：自己发出去的历史还在。
  assert_eq(s[0].player_input(0, 60), Some(board_input(60, 0)))
  // 继续推进：三端逐帧一致，确认帧照常追平。
  while f < 90 {
    f = f + 1
    step_frame(s, n, f)
  }
  assert_eq(s[0].confirmed(), 90)
  assert_eq(s[1].confirmed(), 90)
  let mut g = 55
  while g <= 90 {
    assert_eq(s[0].hash_at(g), s[1].hash_at(g))
    g = g + 1
  }
}

///|
/// 恢复点越界一律拒绝，会话保持不变——宁可继续报分叉，也不能把状态搞坏。
test "resync rejects unusable frames" {
  let n : Int32 = 2
  let s = make_boards(n, 16)
  let mut f = 0
  while f < 40 {
    f = f + 1
    step_frame(s, n, f)
  }
  let state = state_at(s[1], 35)
  let before = s[0].hash_at(40)
  // 未来帧：本端还没有那一段的输入，重放不出来
  assert_true(!s[0].resync_from(41, state))
  // 帧号从 1 开始
  assert_true(!s[0].resync_from(0, state))
  assert_true(!s[0].resync_from(-3, state))
  // 超出回滚窗口：那一段的输入已被输入环淘汰，重放等于换一个地方重新分叉
  assert_true(!s[0].resync_from(10, state))
  assert_eq(s[0].resyncs(), 0)
  assert_eq(s[0].hash_at(40), before)
  assert_eq(s[0].frame(), 40)
  // 窗口边界之内仍然可用
  assert_true(s[0].resync_from(24, state))
  assert_eq(s[0].resyncs(), 1)
}

///|
/// 恢复点取当前帧也可以：不重放任何帧，只换一份世界。
test "resync at the current frame" {
  let n : Int32 = 2
  let s = make_boards(n, 32)
  let mut f = 0
  while f < 50 {
    f = f + 1
    step_frame(s, n, f)
  }
  // 2 人局里 0 号执行真值、发出去的是另一个值，两边在第 51 帧分叉
  let wrong = board_input(51, 0) ^ 3UL
  s[0].receive_from(1, 51, board_input(51, 1))
  s[1].receive_from(0, 51, wrong)
  ignore(s[0].advance(board_input(51, 0)))
  ignore(s[1].advance(board_input(51, 1)))
  assert_true(s[0].hash_at(51) != s[1].hash_at(51))
  assert_true(s[1].resync_from(51, state_at(s[0], 51)))
  assert_eq(s[1].hash_at(51), s[0].hash_at(51))
  assert_eq(s[1].confirmed(), 51)
  assert_eq(s[1].resyncs(), 1)
}

///|
/// 导出只对「还能复现」的帧有值：未来帧、0 帧、被快照环覆盖的老帧都是 `None`。
test "export only answers for frames it still holds" {
  let n : Int32 = 2
  let s = make_boards(n, 2)
  let mut f = 0
  while f < 10 {
    f = f + 1
    step_frame(s, n, f)
  }
  assert_true(s[0].export_state(0) is None)
  assert_true(s[0].export_state(11) is None)
  // 窗口 2 只有 6 个槽：第 3 帧早就被覆盖
  assert_true(s[0].export_state(3) is None)
  match s[0].export_state(10) {
    Some(_) => assert_true(true)
    None => assert_true(false)
  }
  // 导出的必须真的是「第 9 帧的世界」，而不是当前帧
  let t = make_boards(2, 32)
  let mut g = 0
  while g < 9 {
    g = g + 1
    step_frame(t, 2, g)
  }
  assert_true(bytes_equal(state_at(s[0], 9), state_at(t[0], 9)))
  assert_true(!bytes_equal(state_at(s[0], 9), state_at(s[0], 10)))
}
