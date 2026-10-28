///|
/// FNV-1a 64 位状态哈希。
///
/// 用途：回滚同步里两侧每 N 帧交换一次哈希，不一致即 desync。
/// 只依赖整数运算与固定的字节序，跨后端天然一致。
pub struct Digest {
  mut state : UInt64
}

///|
const FNV_OFFSET_BASIS : UInt64 = 0xcbf29ce484222325UL

///|
const FNV_PRIME : UInt64 = 0x100000001b3UL

///|
pub fn Digest::new() -> Digest {
  { state: FNV_OFFSET_BASIS }
}

///|
/// 喂入一个字节（低 8 位有效）。
pub fn Digest::feed_byte(self : Digest, byte : Int) -> Unit {
  self.state = (self.state ^ (byte & 0xFF).to_uint64()) * FNV_PRIME
}

///|
/// 喂入 64 位整数，按小端逐字节处理（字节序固定，避免平台差异）。
pub fn Digest::feed_u64(self : Digest, value : UInt64) -> Unit {
  for i in 0..<8 {
    self.feed_byte(((value >> (i * 8)) & 0xFFUL).to_int())
  }
}

///|
/// 喂入 64 位有符号整数（按位重解释）。
pub fn Digest::feed_i64(self : Digest, value : Int64) -> Unit {
  self.feed_u64(value.reinterpret_as_uint64())
}

///|
/// 喂入一段字节。
pub fn Digest::feed_bytes(self : Digest, bytes : Bytes) -> Unit {
  for i in 0..<bytes.length() {
    self.feed_byte(bytes[i].to_int())
  }
}

///|
/// 取出当前哈希值。
pub fn Digest::finish(self : Digest) -> UInt64 {
  self.state
}

///|
/// 一次性哈希一个 64 位值。
pub fn hash_u64(value : UInt64) -> UInt64 {
  let d = Digest::new()
  d.feed_u64(value)
  d.finish()
}
