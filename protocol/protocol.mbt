///|
/// 紧凑字节协议：输入帧 / 输入区间帧 / 确认帧 / 校验和帧 / 在线状态帧。
///
/// 线上格式（小端，varint 为 LEB128）：
/// ```
/// Input    : [0x01][varint player][varint frame][varint count][varint bits] * count
/// Confirm  : [0x02][varint frame]
/// Checksum : [0x03][varint frame][8 bytes hash]
/// Active   : [0x04][varint player][varint active]
/// InputSpan: [0x05][varint player][varint start][varint count][varint mask][varint bits] * popcount(mask)
/// ```
///
/// `Input` 里的 `inputs[i]` 是玩家 `player + i` 在同一帧的输入位图。
/// 常见情况是「自己一个人的一帧」，即 `count = 1`；多人同帧批量补齐时
/// `count` 才会大于 1。
///
/// `InputSpan` 是同一个玩家的一段连续帧：`count` 是**帧数**，`mask` 的第 i 位
/// 表示 `start + i` 这一帧的输入是否随包发出，未置位的帧沿用包里前一个值。
/// 重发冗余输入时，一个人一帧一条 `Input` 要 4 字节，一段 8 帧且输入只变两次
/// 时 `InputSpan` 只要 7 字节。
pub(all) struct InputFrame {
  player : Int32
  frame : Int32
  inputs : Array[UInt64]
} derive(Eq)

///|
pub(all) struct ConfirmFrame {
  frame : Int32
} derive(Eq)

///|
pub(all) struct ChecksumFrame {
  frame : Int32
  hash : UInt64
} derive(Eq)

///|
/// 同一个玩家的一段连续帧输入。
///
/// `count` 是帧数，`mask` 的第 i 位表示 `start + i` 帧的输入是否在 `values`
/// 里显式给出；未置位表示「与包里前一个显式值相同」。首帧必须置位，
/// 否则这段就没有起点值。
///
/// 它是 `Input` 的补充而不是替代：`Input` 适合「同一帧、多个玩家」，
/// `InputSpan` 适合「同一个玩家、多帧重发」。
pub(all) struct InputSpanFrame {
  player : Int32
  start : Int32
  count : Int32
  mask : UInt64
  values : Array[UInt64]
} derive(Eq)

///|
/// 某个玩家上线 / 掉线的声明。`active = 1` 是上线，`0` 是掉线。
///
/// 掉线本身不是协议层的判断（网络断没断只有上层知道），这里只负责把
/// 上层的决定可靠地同步给其他对等体，让所有人用同一个在线集合推进确认帧。
pub(all) struct ActiveFrame {
  player : Int32
  active : Bool
} derive(Eq)

///|
pub(all) enum Message {
  Input(InputFrame)
  Confirm(ConfirmFrame)
  Checksum(ChecksumFrame)
  Active(ActiveFrame)
  Span(InputSpanFrame)
} derive(Eq)

///|
/// 显式声明 `derive(Eq)` 生成的方法提升为普通方法（消除 W0079）。
pub extend InputFrame with Eq::{not_equal, equal}

///|
pub extend ConfirmFrame with Eq::{not_equal, equal}

///|
pub extend ChecksumFrame with Eq::{not_equal, equal}

///|
pub extend ActiveFrame with Eq::{not_equal, equal}

///|
pub extend InputSpanFrame with Eq::{not_equal, equal}

///|
pub extend Message with Eq::{not_equal, equal}

///|
/// 默认把 `inputs[0]` 当作玩家 0 的输入。
pub fn InputFrame::new(frame : Int32, inputs : Array[UInt64]) -> InputFrame {
  { player: 0, frame, inputs, }
}

///|
/// `inputs[i]` 是玩家 `player + i` 的输入。
pub fn InputFrame::new_from(
  player : Int32,
  frame : Int32,
  inputs : Array[UInt64],
) -> InputFrame {
  { player, frame, inputs, }
}

///|
pub fn ConfirmFrame::new(frame : Int32) -> ConfirmFrame {
  { frame, }
}

///|
pub fn ChecksumFrame::new(frame : Int32, hash : UInt64) -> ChecksumFrame {
  { frame, hash, }
}

///|
pub fn ActiveFrame::new(player : Int32, active : Bool) -> ActiveFrame {
  { player, active, }
}

///|
/// 一段帧的输入上限：掩码是 64 位，再多就用两个包。
pub const MAX_SPAN : Int32 = 64

///|
/// 由「玩家 `player` 从 `start` 起的连续帧输入」构造。
///
/// 首帧总是显式，之后只有与前一帧不同才显式——所以「按住同一个键 8 帧」
/// 在线上只是一个值加一个掩码。超过 `MAX_SPAN` 帧的部分会被截断。
pub fn InputSpanFrame::of(
  player : Int32,
  start : Int32,
  inputs : Array[UInt64],
) -> InputSpanFrame {
  let n = if inputs.length() > MAX_SPAN { MAX_SPAN } else { inputs.length() }
  let values : Array[UInt64] = []
  let mut mask = 0UL
  let mut last = 0UL
  let mut i = 0
  while i < n {
    let v = inputs[i]
    if i == 0 || v != last {
      mask = mask | (1UL << i)
      values.push(v)
      last = v
    }
    i = i + 1
  }
  { player, start, count: n, mask, values, }
}

///|
/// 逐帧全给的版本：掩码全 1，不做任何折叠。
///
/// 用来把「区间帧」和「变化掩码」两个优化的收益分开测——
/// `raw` 与 `of` 的差就是掩码省下的那部分。
pub fn InputSpanFrame::raw(
  player : Int32,
  start : Int32,
  inputs : Array[UInt64],
) -> InputSpanFrame {
  let n = if inputs.length() > MAX_SPAN { MAX_SPAN } else { inputs.length() }
  let values : Array[UInt64] = []
  let mut mask = 0UL
  let mut i = 0
  while i < n {
    values.push(inputs[i])
    mask = mask | (1UL << i)
    i = i + 1
  }
  { player, start, count: n, mask, values, }
}

///|
/// 展开成逐帧输入，长度等于 `count`。
///
/// 未置位的帧沿用包里前一个显式值；因此解码合法的段必定以显式帧开头。
pub fn InputSpanFrame::expand(self : InputSpanFrame) -> Array[UInt64] {
  let out : Array[UInt64] = []
  let mut cur = 0UL
  let mut k = 0
  let mut i = 0
  while i < self.count {
    if (self.mask & (1UL << i)) != 0UL && k < self.values.length() {
      cur = self.values[k]
      k = k + 1
    }
    out.push(cur)
    i = i + 1
  }
  out
}

///|
fn put_varint(out : Array[Byte], v : UInt64) -> Unit {
  let mut x = v
  while x >= 128UL {
    out.push(((x & 0x7FUL).to_int() | 0x80).to_byte())
    x = x >> 7
  }
  out.push(x.to_int().to_byte())
}

///|
fn get_varint(buf : Bytes, start : Int32) -> (UInt64, Int32)? {
  let mut x = 0UL
  let mut shift = 0
  let mut pos = start
  while pos < buf.length() && shift <= 63 {
    let b = buf[pos].to_int()
    x = x | ((b.to_uint64() & 0x7FUL) << shift)
    pos = pos + 1
    if b < 128 {
      return Some((x, pos))
    }
    shift = shift + 7
  }
  None
}

///|
fn put_u64(out : Array[Byte], v : UInt64) -> Unit {
  let mut i = 0
  while i < 8 {
    out.push(((v >> (i * 8)) & 0xFFUL).to_int().to_byte())
    i = i + 1
  }
}

///|
fn get_u64(buf : Bytes, pos : Int32) -> UInt64? {
  if pos < 0 || pos + 8 > buf.length() {
    return None
  }
  let mut v = 0UL
  let mut i = 0
  while i < 8 {
    v = v | (buf[pos + i].to_int().to_uint64() << (i * 8))
    i = i + 1
  }
  Some(v)
}

///|
fn to_bytes(arr : Array[Byte]) -> Bytes {
  Bytes::makei(arr.length(), fn(i) { arr[i] })
}

///|
fn popcount64(x : UInt64) -> Int32 {
  let mut v = x
  let mut n = 0
  while v != 0UL {
    v = v & (v - 1UL)
    n = n + 1
  }
  n
}

///|
fn encode_into(out : Array[Byte], msg : Message) -> Unit {
  match msg {
    Input(f) => {
      out.push((1).to_byte())
      put_varint(out, f.player.to_uint64())
      put_varint(out, f.frame.to_uint64())
      put_varint(out, f.inputs.length().to_uint64())
      for bits in f.inputs {
        put_varint(out, bits)
      }
    }
    Confirm(f) => {
      out.push((2).to_byte())
      put_varint(out, f.frame.to_uint64())
    }
    Checksum(f) => {
      out.push((3).to_byte())
      put_varint(out, f.frame.to_uint64())
      put_u64(out, f.hash)
    }
    Active(f) => {
      out.push((4).to_byte())
      put_varint(out, f.player.to_uint64())
      put_varint(out, if f.active { 1UL } else { 0UL })
    }
    Span(f) => {
      out.push((5).to_byte())
      put_varint(out, f.player.to_uint64())
      put_varint(out, f.start.to_uint64())
      put_varint(out, f.count.to_uint64())
      put_varint(out, f.mask)
      for v in f.values {
        put_varint(out, v)
      }
    }
  }
}

///|
pub fn encode(msg : Message) -> Bytes {
  let out : Array[Byte] = []
  encode_into(out, msg)
  to_bytes(out)
}

///|
pub fn encode_batch(msgs : Array[Message]) -> Bytes {
  let out : Array[Byte] = []
  for m in msgs {
    encode_into(out, m)
  }
  to_bytes(out)
}

///|
fn decode_at(buf : Bytes, start : Int32) -> (Message, Int32)? {
  if start >= buf.length() {
    return None
  }
  let tag = buf[start].to_int()
  let pos = start + 1
  if tag == 1 {
    let (player, p1) = match get_varint(buf, pos) {
      Some(pair) => pair
      None => return None
    }
    let (frame, p2) = match get_varint(buf, p1) {
      Some(pair) => pair
      None => return None
    }
    let (count, p3) = match get_varint(buf, p2) {
      Some(pair) => pair
      None => return None
    }
    // 玩家索引 0..7，且 player + count 不能越过 8 人上限，否则视为损坏
    if player > 7UL || count > 8UL || player.to_int() + count.to_int() > 8 {
      return None
    }
    let inputs : Array[UInt64] = []
    let mut p = p3
    let mut i = 0
    while i < count.to_int() {
      match get_varint(buf, p) {
        Some((bits, np)) => {
          inputs.push(bits)
          p = np
          i = i + 1
        }
        None => return None
      }
    }
    Some(
      (Input({ player: player.to_int(), frame: frame.to_int(), inputs, }), p),
    )
  } else if tag == 2 {
    match get_varint(buf, pos) {
      Some((frame, p)) => Some((Confirm({ frame: frame.to_int(), }), p))
      None => None
    }
  } else if tag == 3 {
    match get_varint(buf, pos) {
      Some((frame, p1)) =>
        match get_u64(buf, p1) {
          Some(hash) =>
            Some((Checksum({ frame: frame.to_int(), hash, }), p1 + 8))
          None => None
        }
      None => None
    }
  } else if tag == 4 {
    let (player, p1) = match get_varint(buf, pos) {
      Some(pair) => pair
      None => return None
    }
    let (active, p2) = match get_varint(buf, p1) {
      Some(pair) => pair
      None => return None
    }
    // 玩家索引 0..7，状态只能是 0 / 1；其他一律视为损坏
    if player > 7UL || active > 1UL {
      return None
    }
    Some((Active({ player: player.to_int(), active: active == 1UL, }), p2))
  } else if tag == 5 {
    let (player, p1) = match get_varint(buf, pos) {
      Some(pair) => pair
      None => return None
    }
    let (start, p2) = match get_varint(buf, p1) {
      Some(pair) => pair
      None => return None
    }
    let (count, p3) = match get_varint(buf, p2) {
      Some(pair) => pair
      None => return None
    }
    let (mask, p4) = match get_varint(buf, p3) {
      Some(pair) => pair
      None => return None
    }
    // 玩家索引 0..7；帧号从 1 起；帧数 1..64（掩码只有 64 位）；
    // 首帧必须显式，否则这段没有起点值；掩码不能超出帧数。
    if player > 7UL || start < 1UL || count < 1UL || count > 64UL {
      return None
    }
    if (mask & 1UL) == 0UL {
      return None
    }
    if count < 64UL && mask >> count.to_int() != 0UL {
      return None
    }
    let values : Array[UInt64] = []
    let mut p = p4
    let mut i = 0
    let want = popcount64(mask)
    while i < want {
      match get_varint(buf, p) {
        Some((bits, np)) => {
          values.push(bits)
          p = np
          i = i + 1
        }
        None => return None
      }
    }
    Some(
      (
        Span({
          player: player.to_int(),
          start: start.to_int(),
          count: count.to_int(),
          mask,
          values,
        }),
        p,
      ),
    )
  } else {
    None
  }
}

///|
pub fn decode(buf : Bytes) -> Message? {
  match decode_at(buf, 0) {
    Some((msg, _)) => Some(msg)
    None => None
  }
}

///|
pub fn decode_batch(buf : Bytes) -> Array[Message] {
  let out : Array[Message] = []
  let mut pos = 0
  while pos < buf.length() {
    match decode_at(buf, pos) {
      Some((msg, next)) => {
        out.push(msg)
        pos = next
      }
      None => break
    }
  }
  out
}
