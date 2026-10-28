///|
/// blackbox 测试：确认外部包能构造、解构并读取字段。
test "message is usable from outside the package" {
  let m = @protocol.Input(@protocol.InputFrame::new(42, [0b101UL]))
  match @protocol.decode(@protocol.encode(m)) {
    Some(@protocol.Input(f)) => {
      assert_eq(f.frame, 42)
      assert_eq(f.inputs[0], 0b101UL)
    }
    _ => assert_true(false)
  }
}

///|
test "snap frames are usable from outside the package" {
  let state = Bytes::makei(3, fn(i) { [9, 8, 7][i].to_byte() })
  let msg = @protocol.Message::Snap(@protocol.SnapFrame::new(7, state))
  match @protocol.decode(@protocol.encode(msg)) {
    Some(@protocol.Snap(f)) => {
      assert_eq(f.frame, 7)
      assert_eq(f.state.length(), 3)
      assert_eq(f.state[0].to_int(), 9)
    }
    _ => assert_true(false)
  }
  let ask = @protocol.Message::SnapRequest(@protocol.SnapRequestFrame::new(7))
  match @protocol.decode(@protocol.encode(ask)) {
    Some(@protocol.SnapRequest(f)) => assert_eq(f.frame, 7)
    _ => assert_true(false)
  }
}
