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
