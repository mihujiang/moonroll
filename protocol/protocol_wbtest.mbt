///|
fn lcg(state : UInt64) -> UInt64 {
  state * 6364136223846793005UL + 1442695040888963407UL
}

///|
test "encoding layout is compact" {
  // tag(1) + varint frame(1) + varint count(1) + varint bits(1)
  let b = encode(Input(InputFrame::new(1, [0x05UL])))
  assert_eq(b.length(), 4)
  assert_eq(b[0].to_int(), 1)
  assert_eq(b[3].to_int(), 5)
  // 1000 的 varint 是 2 字节
  assert_eq(encode(Confirm(ConfirmFrame::new(1000))).length(), 3)
  // checksum: tag + varint frame + 8 字节
  assert_eq(encode(Checksum(ChecksumFrame::new(1, 0UL))).length(), 10)
}

///|
test "input frame roundtrip over 1000 random frames" {
  let mut seed = 12345UL
  let mut i = 0
  while i < 1000 {
    seed = lcg(seed)
    let frame = (seed & 0xFFFFUL).to_int()
    seed = lcg(seed)
    let count = (seed % 4UL).to_int() + 1
    let inputs : Array[UInt64] = []
    let mut j = 0
    while j < count {
      seed = lcg(seed)
      inputs.push(seed & 0xFFUL)
      j = j + 1
    }
    let msg = Input(InputFrame::new(frame, inputs))
    match decode(encode(msg)) {
      Some(m) => assert_true(m == msg)
      None => assert_true(false)
    }
    i = i + 1
  }
}

///|
test "confirm and checksum roundtrip" {
  let mut seed = 777UL
  let mut i = 0
  while i < 500 {
    seed = lcg(seed)
    let frame = (seed & 0xFFFFFFUL).to_int()
    let cf = Confirm(ConfirmFrame::new(frame))
    match decode(encode(cf)) {
      Some(m) => assert_true(m == cf)
      None => assert_true(false)
    }
    seed = lcg(seed)
    let hash = seed
    let cs = Checksum(ChecksumFrame::new(frame, hash))
    match decode(encode(cs)) {
      Some(m) => assert_true(m == cs)
      None => assert_true(false)
    }
    i = i + 1
  }
}

///|
test "batch roundtrip" {
  let msgs : Array[Message] = [
    Input(InputFrame::new(3, [1UL, 2UL])),
    Confirm(ConfirmFrame::new(7)),
    Checksum(ChecksumFrame::new(9, 0xDEADBEEFCAFEBABEUL)),
  ]
  let back = decode_batch(encode_batch(msgs))
  assert_eq(back.length(), 3)
  let mut i = 0
  while i < 3 {
    assert_true(back[i] == msgs[i])
    i = i + 1
  }
}

///|
test "truncated buffers never panic" {
  let full = encode(Input(InputFrame::new(123456, [0xABUL, 0xCDUL])))
  let mut n = 0
  while n < full.length() {
    let part = Bytes::makei(n, fn(i) { full[i] })
    ignore(decode(part))
    ignore(decode_batch(part))
    n = n + 1
  }
}

///|
test "garbage buffers never panic" {
  let mut seed = 999UL
  let mut i = 0
  while i < 500 {
    seed = lcg(seed)
    let len = (seed % 40UL).to_int() + 1
    let base = seed
    let bytes = Bytes::makei(len, fn(k) {
      (lcg(base + k.to_uint64()) & 0xFFUL).to_int().to_byte()
    })
    ignore(decode(bytes))
    ignore(decode_batch(bytes))
    i = i + 1
  }
}

///|
test "oversized player count is rejected" {
  // 手工构造 count=9 的输入帧
  let bytes = Bytes::makei(3, fn(i) { [1, 1, 9][i].to_byte() })
  assert_true(decode(bytes) is None)
}
