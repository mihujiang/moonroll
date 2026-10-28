///|
/// V0.1 冒烟示例：定点数、状态哈希、输入环。
///
/// 运行：
///   moon run cmd/main --target wasm-gc
fn main {
  // 1) 定点数：整数运算，跨后端逐位一致
  let a = @fixed.Fixed::from_double(1.5)
  let b = @fixed.Fixed::from_double(2.25)
  println("fixed 1.5 * 2.25 = " + (a * b).to_double().to_string())
  println(
    "fixed sqrt(2)     = " +
    @fixed.Fixed::from_int(2).sqrt().to_double().to_string(),
  )
  println(
    "fixed lerp(0,10,.3)= " +
    @fixed.lerp(
      @fixed.Fixed::from_int(0),
      @fixed.Fixed::from_int(10),
      @fixed.Fixed::from_double(0.3),
    )
    .to_double()
    .to_string(),
  )
  // 2) 状态哈希：回滚两侧比对
  let d = @digest.Digest::new()
  d.feed_bytes(b"hello")
  println("digest fnv1a(hello) = " + d.finish().to_string())
  // 3) 输入环：按帧号随机存取
  let ring = @input.InputRing::new(8)
  ring.set(42, 0b101UL)
  match ring.get(42) {
    Some(bits) => println("input frame 42      = " + bits.to_string())
    None => println("input frame 42      = missing")
  }
  println("moonroll version    = " + @moonroll.version())
}
