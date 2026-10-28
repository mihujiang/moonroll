///|
/// 掉线语义的测试用模拟器：和 players_test 里的 Crowd 同构，但独立定义，
/// 因为每个黑盒测试文件是各自的包。
struct Pack {
  mut w : UInt64
}

///|
impl @session.Sim for Pack with fn save(self) -> Bytes {
  Bytes::makei(8, fn(i) { ((self.w >> (i * 8)) & 0xFFUL).to_int().to_byte() })
}

///|
impl @session.Sim for Pack with fn restore(self, bytes : Bytes) -> Unit {
  let mut v = 0UL
  let mut i = 0
  while i < 8 {
    v = v | (bytes[i].to_int().to_uint64() << (i * 8))
    i = i + 1
  }
  self.w = v
}

///|
impl @session.Sim for Pack with fn step_players(self, inputs : Array[UInt64]) -> Unit {
  let mut v = self.w * 31UL
  let mut i = 0
  for bits in inputs {
    v = v + ((bits & 0xFFUL) << (i * 4))
    i = i + 1
  }
  self.w = v
}

///|
impl @session.Sim for Pack with fn hash(self) -> UInt64 {
  @digest.hash_u64(self.w)
}

///|
fn pack_input(frame : Int32, player : Int32) -> UInt64 {
  (frame.to_uint64() * 2654435761UL + player.to_uint64() * 1237UL) & 0xFFUL
}

///|
fn make_pack(n : Int32, window : Int32) -> Array[@session.Session[Pack]] {
  let out : Array[@session.Session[Pack]] = []
  let mut i = 0
  while i < n {
    out.push(@session.Session::with_players({ w: 0UL, }, n, i, window))
    i = i + 1
  }
  out
}

///|
/// 推进一帧：先把别人本帧的输入塞进各自的环，再各自本地推进。
/// `silent` 指定的玩家这一帧什么都不发（模拟掉线），传 -1 表示全员在线。
fn tick(
  s : Array[@session.Session[Pack]],
  n : Int32,
  f : Int32,
  silent : Int32,
) -> Unit {
  let mut k = 0
  while k < n {
    let mut j = 0
    while j < n {
      if j != k && j != silent {
        s[k].receive_from(j, f, pack_input(f, j))
      }
      j = j + 1
    }
    k = k + 1
  }
  let mut m = 0
  while m < n {
    ignore(s[m].advance(pack_input(f, m)))
    m = m + 1
  }
}

///|
/// 掉线的玩家不再参与确认帧：宣布之后确认帧立刻补到当前帧。
test "dropped player stops blocking confirmation" {
  let n : Int32 = 3
  let s = make_pack(n, 32)
  let mut f = 0
  while f < 40 {
    f = f + 1
    tick(s, n, f, -1)
  }
  assert_eq(s[0].confirmed(), 40)
  // 2 号从 41 帧起沉默：其他人只能预测，确认帧立刻卡住。
  while f < 70 {
    f = f + 1
    tick(s, n, f, 2)
  }
  assert_eq(s[0].confirmed(), 40)
  assert_eq(s[1].confirmed(), 40)
  let before = s[0].confirmed()
  // 在线集合是每个会话各自的决定，必须同步到全房（否则各自卡在不同的帧）。
  assert_true(s[0].set_player_active(2, false))
  assert_true(s[1].set_player_active(2, false))
  // 0/1 的输入一直连续，所以宣布之后确认帧直接跳到当前帧。
  assert_true(s[0].confirmed() > before)
  while f < 120 {
    f = f + 1
    tick(s, n, f, 2)
  }
  assert_eq(s[0].confirmed(), 120)
  assert_eq(s[1].confirmed(), 120)
  // 掉线者自己毫不知情：它照收别人的包，仍以为全房正常。
  assert_eq(s[2].confirmed(), 120)
  assert_eq(s[0].online_count(), 2)
  assert_true(!s[0].is_active(2))
}

///|
/// 重连不能把确认帧拽回去，重连者补齐输入后确认帧继续前进。
test "rejoin never rewinds confirmation" {
  let n : Int32 = 3
  let s = make_pack(n, 32)
  let mut f = 0
  while f < 40 {
    f = f + 1
    tick(s, n, f, -1)
  }
  ignore(s[0].set_player_active(2, false))
  ignore(s[1].set_player_active(2, false))
  while f < 80 {
    f = f + 1
    tick(s, n, f, 2)
  }
  assert_eq(s[0].confirmed(), 80)
  // 重新上线：确认帧不许回退，在线人数立刻回到 3。
  assert_true(s[0].set_player_active(2, true))
  assert_eq(s[0].confirmed(), 80)
  assert_eq(s[0].online_count(), 3)
  // 2 号从 81 帧起重新发包，三人恢复齐全。
  while f < 120 {
    f = f + 1
    tick(s, n, f, -1)
  }
  assert_eq(s[0].confirmed(), 120)
  assert_eq(s[1].confirmed(), 120)
  assert_eq(s[0].hash_at(120), s[1].hash_at(120))
}

///|
/// 掉线 / 重连只是改在线集合，不能把状态搞分叉：在线两端逐帧哈希一致。
test "remaining peers stay in sync across a drop" {
  let n : Int32 = 4
  let s = make_pack(n, 32)
  let mut f = 0
  while f < 60 {
    f = f + 1
    tick(s, n, f, -1)
  }
  ignore(s[0].set_player_active(3, false))
  ignore(s[1].set_player_active(3, false))
  ignore(s[2].set_player_active(3, false))
  while f < 160 {
    f = f + 1
    tick(s, n, f, 3)
  }
  let c = s[0].confirmed()
  assert_eq(c, 160)
  assert_eq(s[1].confirmed(), c)
  assert_eq(s[2].confirmed(), c)
  let mut g = 1
  while g <= c {
    assert_eq(s[1].hash_at(g), s[0].hash_at(g))
    assert_eq(s[2].hash_at(g), s[0].hash_at(g))
    g = g + 1
  }
}

///|
/// 边界：本地玩家不能掉线、最后一个人不能被踢、越界索引被忽略、重复调用返回 false。
test "online set guards" {
  let n : Int32 = 3
  let s = make_pack(n, 16)
  // 本地玩家永远是「在线」的那一个
  assert_true(!s[0].set_player_active(0, false))
  assert_true(s[0].is_active(0))
  // 越界
  assert_true(!s[0].set_player_active(7, false))
  assert_true(!s[0].set_player_active(-1, false))
  assert_true(!s[0].is_active(-1))
  assert_true(!s[0].is_active(9))
  // 幂等
  assert_true(!s[0].set_player_active(1, true))
  // 踢掉 1、2 之后只剩自己，不能再踢
  assert_true(s[0].set_player_active(1, false))
  assert_true(s[0].set_player_active(2, false))
  assert_eq(s[0].online_count(), 1)
  assert_true(!s[0].set_player_active(1, false))

  // 单人局：连自己都不能踢
  let solo = make_pack(1, 8)
  assert_true(!solo[0].set_player_active(0, false))
  assert_eq(solo[0].online_count(), 1)
}

///|
/// 对端水位只前进：它决定「重发从哪一帧开始」，退回去只会白发票。
test "peer confirm watermark only moves forward" {
  let n : Int32 = 3
  let s = make_pack(n, 16)
  let mut f = 0
  while f < 5 {
    f = f + 1
    ignore(s[0].advance(pack_input(f, 0)))
  }
  assert_eq(s[0].peer_confirmed(1), 0)
  s[0].receive_confirm(1, 3)
  assert_eq(s[0].peer_confirmed(1), 3)
  s[0].receive_confirm(1, 4)
  assert_eq(s[0].peer_confirmed(1), 4)
  // 迟到的旧包不能把水位拽回去
  s[0].receive_confirm(1, 2)
  assert_eq(s[0].peer_confirmed(1), 4)
  // 对端不可能确认我们还没算出来的帧
  s[0].receive_confirm(1, 999)
  assert_eq(s[0].peer_confirmed(1), s[0].frame())
  // 自己不是「对端」
  s[0].receive_confirm(0, 2)
  assert_eq(s[0].peer_confirmed(0), 0)
  // 越界不炸
  s[0].receive_confirm(9, 2)
  s[0].receive_confirm(-1, 2)
  assert_eq(s[0].peer_confirmed(9), 0)
  assert_eq(s[0].peer_confirmed(-1), 0)
}
