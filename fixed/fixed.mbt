///|
/// Q16.16 定点数。
///
/// 为什么需要它：回滚同步要求「同一串输入在任何后端、任何 CPU 上产生逐位相同的轨迹」。
/// 浮点运算在 `js` 与 `wasm-gc` 上实测一致（见 README），但 native 与跨平台仍受
/// 编译器优化与 FMA 收缩影响。`Fixed` 用整数运算，语义由 MoonBit 的 Int64 保证，
/// 不依赖任何浮点库。
///
/// 内部表示：`v = value * 65536`。所有中间运算走 Int64，
/// 因此实际可用范围是 Int32 区间，约 `[-32768, 32767]`。
pub struct Fixed {
  v : Int64
} derive(Eq)

///|
const FIXED_SCALE : Int64 = 65536L

///|
/// 从原始定点整数构造（`v = value * 65536`）。
pub fn Fixed::from_raw(v : Int64) -> Fixed {
  { v, }
}

///|
/// 取出原始定点整数，用于序列化与状态哈希。
pub fn Fixed::raw(self : Fixed) -> Int64 {
  self.v
}

///|
/// 整数 -> 定点数。
pub fn Fixed::from_int(value : Int) -> Fixed {
  { v: value.to_int64() * FIXED_SCALE }
}

///|
/// 浮点数 -> 定点数（四舍五入，仅用于初始化与测试，不参与模拟核心）。
pub fn Fixed::from_double(value : Double) -> Fixed {
  let scaled = value * 65536.0
  let rounded = if scaled >= 0.0 {
    (scaled + 0.5).to_int64()
  } else {
    (scaled - 0.5).to_int64()
  }
  { v: rounded }
}

///|
/// 定点数 -> 浮点数（仅用于渲染与打印，不参与模拟核心）。
pub fn Fixed::to_double(self : Fixed) -> Double {
  self.v.to_double() / 65536.0
}

///|
pub fn Fixed::abs(self : Fixed) -> Fixed {
  if self.v < 0L {
    { v: -self.v }
  } else {
    self
  }
}

///|
pub impl Neg for Fixed with fn neg(self) {
  { v: -self.v }
}

///|
pub impl Add for Fixed with fn add(self, other) {
  { v: self.v + other.v }
}

///|
pub impl Sub for Fixed with fn sub(self, other) {
  { v: self.v - other.v }
}

///|
pub impl Mul for Fixed with fn mul(self, other) {
  { v: (self.v * other.v) >> 16 }
}

///|
pub impl Div for Fixed with fn div(self, other) {
  { v: (self.v << 16) / other.v }
}

///|
pub impl Compare for Fixed with fn compare(self, other) -> Int {
  if self.v < other.v {
    -1
  } else if self.v > other.v {
    1
  } else {
    0
  }
}

///|
/// 整数平方根（牛顿迭代，纯整数，确定性）。
fn isqrt(n : Int64) -> Int64 {
  if n < 2L {
    return n
  }
  let mut x = n
  let mut y = (x + 1L) >> 1
  while y < x {
    x = y
    y = (x + n / x) >> 1
  }
  x
}

///|
/// 定点开方：`sqrt(x)` 仍是 Q16.16。
///
/// 推导：`sqrt(v / 2^16) * 2^16 = sqrt(v * 2^16)`，
/// 因此对 `v << 16` 求整数平方根即可。
pub fn Fixed::sqrt(self : Fixed) -> Fixed {
  if self.v <= 0L {
    return { v: 0L }
  }
  let n = self.v << 16
  let r = isqrt(n)
  // 四舍五入到最近的定点值：比较 r 与 r+1 谁更接近 sqrt(n)
  let below = n - r * r
  let above = (r + 1L) * (r + 1L) - n
  if above < below {
    { v: r + 1L }
  } else {
    { v: r }
  }
}

///|
/// 线性插值：`a + (b - a) * t`。
pub fn lerp(a : Fixed, b : Fixed, t : Fixed) -> Fixed {
  a + (b - a) * t
}

///|
pub fn clamp(value : Fixed, lo : Fixed, hi : Fixed) -> Fixed {
  if value < lo {
    lo
  } else if value > hi {
    hi
  } else {
    value
  }
}
