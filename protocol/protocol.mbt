///|
/// 紧凑字节协议：输入帧 / 确认帧 / 校验和帧。
///
/// 线上格式（小端，varint 为 LEB128）：
/// ```
/// Input    : [0x01][varint player][varint frame][varint count][varint bits] * count
/// Confirm  : [0x02][varint frame]
/// Checksum : [0x03][varint frame][8 bytes hash]
/// ```
///
/// `Input` 里的 `inputs[i]` 是玩家 `player + i` 在同一帧的输入位图。
/// 常见情况是「自己一个人的一帧」，即 `count = 1`；多人同帧批量补齐时
/// `count` 才会大于 1。
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
pub(all) enum Message {
  Input(InputFrame)
  Confirm(ConfirmFrame)
  Checksum(ChecksumFrame)
} derive(Eq)

///|
/// 显式声明 `derive(Eq)` 生成的方法提升为普通方法（消除 W0079）。
pub extend InputFrame with Eq::{not_equal, equal}

///|
pub extend ConfirmFrame with Eq::{not_equal, equal}

///|
pub extend ChecksumFrame with Eq::{not_equal, equal}

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
