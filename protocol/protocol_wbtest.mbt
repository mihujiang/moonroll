///|
fn lcg(state : UInt64) -> UInt64 {
  state * 6364136223846793005UL + 1442695040888963407UL
}

///|
test "encoding layout is compact" {
  // tag(1) + varint player(1) + varint frame(1) + varint count(1) + varint bits(1)
  let b = encode(Input(InputFrame::new(1, [0x05UL])))
  assert_eq(b.length(), 5)
  assert_eq(b[0].to_int(), 1)
  assert_eq(b[1].to_int(), 0)
  assert_eq(b[4].to_int(), 5)
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
test "active frame layout and roundtrip" {
  // tag + varint player + varint active
  let off = encode(Active(ActiveFrame::new(3, false)))
  assert_eq(off.length(), 3)
  assert_eq(off[0].to_int(), 4)
  assert_eq(off[1].to_int(), 3)
  assert_eq(off[2].to_int(), 0)
  let mut seed = 424242UL
  let mut i = 0
  while i < 500 {
    seed = lcg(seed)
    let player = (seed % 8UL).to_int()
    seed = lcg(seed)
    let msg = Active(ActiveFrame::new(player, seed % 2UL == 1UL))
    match decode(encode(msg)) {
      Some(m) => assert_true(m == msg)
      None => assert_true(false)
    }
    i = i + 1
  }
}

///|
test "malformed active frames are rejected" {
  // player=9 越界
  let bad_player = Bytes::makei(3, fn(i) { [4, 9, 1][i].to_byte() })
  assert_true(decode(bad_player) is None)
  // active=2 不是 0/1
  let bad_state = Bytes::makei(3, fn(i) { [4, 1, 2][i].to_byte() })
  assert_true(decode(bad_state) is None)
}

///|
test "oversized player count is rejected" {
  // 手工构造 count=9 的输入帧：tag=1, player=0, frame=1, count=9
  let bytes = Bytes::makei(4, fn(i) { [1, 0, 1, 9][i].to_byte() })
  assert_true(decode(bytes) is None)
}

///|
test "oversized player index is rejected" {
  // player=9 超出 8 人上限
  let bytes = Bytes::makei(4, fn(i) { [1, 9, 1, 1][i].to_byte() })
  assert_true(decode(bytes) is None)
}

///|
test "player index roundtrip over 2000 random frames" {
  let mut seed = 2026UL
  let mut i = 0
  while i < 2000 {
    seed = lcg(seed)
    let frame = (seed & 0xFFFFUL).to_int()
    seed = lcg(seed)
    let count = (seed % 3UL).to_int() + 1
    seed = lcg(seed)
    // player + count 不能越过 8 人上限
    let player = (seed % (9UL - count.to_uint64())).to_int()
    let inputs : Array[UInt64] = []
    let mut j = 0
    while j < count {
      seed = lcg(seed)
      inputs.push(seed & 0xFFUL)
      j = j + 1
    }
    let msg = Input(InputFrame::new_from(player, frame, inputs))
    match decode(encode(msg)) {
      Some(m) => assert_true(m == msg)
      None => assert_true(false)
    }
    i = i + 1
  }
}

///|
test "input span folds repeated frames" {
  // 8 帧里输入只变三次：值 -> 值 ×3 -> 值 -> 值 -> 值 -> 值
  let inputs : Array[UInt64] = [3UL, 3UL, 3UL, 5UL, 5UL, 5UL, 5UL, 1UL]
  let span = InputSpanFrame::of(2, 100, inputs)
  assert_eq(span.count, 8)
  assert_eq(span.values.length(), 3)
  assert_eq(span.mask, 0b10001001UL)
  let back = span.expand()
  assert_eq(back.length(), 8)
  let mut i = 0
  while i < 8 {
    assert_eq(back[i], inputs[i])
    i = i + 1
  }
  // 编码：tag + player + start + count + mask(2) + 3 个值 = 9 字节；
  // 逐帧发 8 条 Input 是 8 × 4 = 32 字节。
  let bytes = encode_batch([Span(span)])
  assert_eq(bytes.length(), 9)
}

///|
test "input span of a constant run is one value" {
  let inputs : Array[UInt64] = [7UL, 7UL, 7UL, 7UL]
  let span = InputSpanFrame::of(0, 1, inputs)
  assert_eq(span.mask, 1UL)
  assert_eq(span.values.length(), 1)
  assert_eq(encode_batch([Span(span)]).length(), 6)
  // raw 不折叠：同一个区间的 4 个值全给
  let raw = InputSpanFrame::raw(0, 1, inputs)
  assert_eq(raw.values.length(), 4)
  assert_eq(encode_batch([Span(raw)]).length(), 9)
}

///|
test "input span roundtrip over 500 random runs" {
  let mut seed = 20240UL
  let mut i = 0
  while i < 500 {
    seed = lcg(seed)
    let count = (seed % 16UL).to_int() + 1
    seed = lcg(seed)
    let start = (seed & 0x3FFUL).to_int() + 1
    seed = lcg(seed)
    let player = (seed % 8UL).to_int()
    // 用很小的取值域制造大量重复帧
    let inputs : Array[UInt64] = []
    let mut j = 0
    while j < count {
      seed = lcg(seed)
      inputs.push(seed % 5UL)
      j = j + 1
    }
    let span = InputSpanFrame::of(player, start, inputs)
    let msg = Span(span)
    match decode(encode(msg)) {
      Some(m) => {
        assert_true(m == msg)
        match m {
          Span(s) => {
            let expanded = s.expand()
            assert_eq(expanded.length(), count)
            let mut k = 0
            while k < count {
              assert_eq(expanded[k], inputs[k])
              k = k + 1
            }
          }
          _ => assert_true(false)
        }
      }
      None => assert_true(false)
    }
    i = i + 1
  }
}

///|
test "malformed input spans are rejected" {
  // mask 的首位没置位：这段没有起点值
  let no_first = Bytes::makei(6, fn(i) { [5, 1, 10, 2, 2, 7][i].to_byte() })
  assert_true(decode(no_first) is None)
  // count = 0
  let zero = Bytes::makei(5, fn(i) { [5, 1, 10, 0, 1][i].to_byte() })
  assert_true(decode(zero) is None)
  // count = 65 超过掩码位数
  let too_many = Bytes::makei(5, fn(i) { [5, 1, 10, 65, 1][i].to_byte() })
  assert_true(decode(too_many) is None)
  // start = 0（帧号从 1 开始）
  let zero_start = Bytes::makei(5, fn(i) { [5, 1, 0, 2, 3][i].to_byte() })
  assert_true(decode(zero_start) is None)
  // player = 8
  let bad_player = Bytes::makei(5, fn(i) { [5, 8, 10, 2, 3][i].to_byte() })
  assert_true(decode(bad_player) is None)
  // mask 越出 count：count=2 但有第 3 位
  let wide = Bytes::makei(5, fn(i) { [5, 1, 10, 2, 5][i].to_byte() })
  assert_true(decode(wide) is None)
  // 值不够
  let short = Bytes::makei(5, fn(i) { [5, 1, 10, 2, 3][i].to_byte() })
  assert_true(decode(short) is None)
}
