// Whitebox 测试：直接访问 Fixed 的构造与运算。

///|
fn close(a : Double, b : Double, eps : Double) -> Bool {
  let d = a - b
  (if d < 0.0 { -d } else { d }) <= eps
}

///|
test "int roundtrip" {
  assert_eq(Fixed::from_int(3).to_double(), 3.0)
  assert_eq(Fixed::from_int(-7).to_double(), -7.0)
  assert_eq(Fixed::from_int(0).to_double(), 0.0)
}

///|
test "double roundtrip within half LSB" {
  let values = [0.0, 1.0, -1.0, 1.5, -2.25, 0.1, 3.14159]
  for v in values {
    let x = Fixed::from_double(v)
    assert_true(close(x.to_double(), v, 1.0 / 65536.0))
  }
}

///|
test "add and sub are exact" {
  let a = Fixed::from_double(1.25)
  let b = Fixed::from_double(2.5)
  assert_eq((a + b).to_double(), 3.75)
  assert_eq((b - a).to_double(), 1.25)
  assert_eq((a - b).to_double(), -1.25)
}

///|
test "mul matches double within tolerance" {
  let mut i = 0
  while i < 120 {
    let a = Fixed::from_double(i.to_double() * 0.37 - 20.0)
    let b = Fixed::from_double(0.5 + (i % 7).to_double() * 0.25)
    let got = (a * b).to_double()
    let want = a.to_double() * b.to_double()
    assert_true(close(got, want, 4.0 / 65536.0))
    i += 1
  }
}

///|
test "div matches double within tolerance" {
  let a = Fixed::from_double(7.0)
  let b = Fixed::from_double(3.0)
  assert_true(close((a / b).to_double(), 7.0 / 3.0, 4.0 / 65536.0))
}

///|
test "sqrt matches double within tolerance" {
  let values = [1.0, 2.0, 4.0, 9.0, 0.25, 10.0, 123.0]
  for v in values {
    let x = Fixed::from_double(v)
    let got = x.sqrt().to_double()
    let want = v.sqrt()
    assert_true(close(got, want, 4.0 / 65536.0))
  }
  assert_eq(Fixed::from_double(-1.0).sqrt().to_double(), 0.0)
}

///|
test "lerp and clamp" {
  let a = Fixed::from_int(0)
  let b = Fixed::from_int(10)
  assert_eq(lerp(a, b, Fixed::from_double(0.5)).to_double(), 5.0)
  assert_eq(lerp(a, b, Fixed::from_int(0)).to_double(), 0.0)
  assert_eq(lerp(a, b, Fixed::from_int(1)).to_double(), 10.0)
  assert_eq(clamp(Fixed::from_int(20), a, b).to_double(), 10.0)
  assert_eq(clamp(Fixed::from_int(-3), a, b).to_double(), 0.0)
  assert_eq(clamp(Fixed::from_int(4), a, b).to_double(), 4.0)
}

///|
test "neg and abs" {
  let x = Fixed::from_double(-3.5)
  assert_eq((-x).to_double(), 3.5)
  assert_eq(x.abs().to_double(), 3.5)
  assert_true(x.abs() == -x)
}

///|
test "comparisons" {
  let a = Fixed::from_int(1)
  let b = Fixed::from_int(2)
  assert_true(a < b)
  assert_true(a <= b)
  assert_true(b > a)
  assert_true(b >= a)
  assert_true(a == Fixed::from_int(1))
  assert_true(a != b)
}
