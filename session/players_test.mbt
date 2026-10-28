///|
/// 多人局的测试用模拟器：所有玩家的输入按下标错位混进同一个 64 位状态。
struct Crowd {
  mut v : UInt64
}

///|
impl @session.Sim for Crowd with fn save(self) -> Bytes {
  Bytes::makei(8, fn(i) { ((self.v >> (i * 8)) & 0xFFUL).to_int().to_byte() })
}

///|
impl @session.Sim for Crowd with fn restore(self, bytes : Bytes) -> Unit {
  let mut v = 0UL
  let mut i = 0
  while i < 8 {
    v = v | (bytes[i].to_int().to_uint64() << (i * 8))
    i = i + 1
  }
  self.v = v
}

///|
impl @session.Sim for Crowd with fn step_players(self, inputs : Array[UInt64]) -> Unit {
  let mut v = self.v * 31UL
  let mut i = 0
  for bits in inputs {
    v = v + ((bits & 0xFFUL) << (i * 4))
    i = i + 1
  }
  self.v = v
}

///|
impl @session.Sim for Crowd with fn hash(self) -> UInt64 {
  @digest.hash_u64(self.v)
}

///|
fn crowd_input(frame : Int32, player : Int32) -> UInt64 {
  (frame.to_uint64() * 2654435761UL + player.to_uint64() * 1237UL) & 0xFFUL
}

///|
fn make_crowd(n : Int32, window : Int32) -> Array[@session.Session[Crowd]] {
  let out : Array[@session.Session[Crowd]] = []
  let mut i = 0
  while i < n {
    out.push(@session.Session::with_players({ v: 0UL, }, n, i, window))
    i = i + 1
  }
  out
}

///|
/// 四端在输入及时到达时应当完全没有回滚，且每一帧的哈希都一致。
test "four players with timely inputs never roll back" {
  let n : Int32 = 4
  let s = make_crowd(n, 64)
  let mut f = 0
  while f < 200 {
    f = f + 1
    // 先把同帧其他玩家的输入塞进环里（此时是「未来帧」，不会触发回滚）
    let mut k = 0
    while k < n {
      let mut j = 0
      while j < n {
        if j != k {
          s[k].receive_from(j, f, crowd_input(f, j))
        }
        j = j + 1
      }
      k = k + 1
    }
    let mut k2 = 0
    while k2 < n {
      ignore(s[k2].advance(crowd_input(f, k2)))
      k2 = k2 + 1
    }
  }
  let mut k = 0
  while k < n {
    assert_eq(s[k].confirmed(), 200)
    assert_eq(s[k].rollbacks(), 0)
    assert_eq(s[k].replayed(), 0L)
    k = k + 1
  }
  let mut f2 = 1
  while f2 <= 200 {
    let base = s[0].hash_at(f2)
    let mut j = 1
    while j < n {
      assert_eq(s[j].hash_at(f2), base)
      j = j + 1
    }
    f2 = f2 + 1
  }
}

///|
/// 有一个玩家总是迟到 5 帧：会反复回滚，但等所有输入补齐后世界必须仍然一致。
test "four players converge after late inputs" {
  let n : Int32 = 4
  let s = make_crowd(n, 128)
  let late = 3
  let mut f = 0
  while f < 240 {
    f = f + 1
    // 0、1、2 号玩家的输入同帧送达
    let mut k = 0
    while k < n {
      let mut j = 0
      while j < n {
        if j != k && j != late {
          s[k].receive_from(j, f, crowd_input(f, j))
        }
        j = j + 1
      }
      k = k + 1
    }
    let mut k2 = 0
    while k2 < n {
      ignore(s[k2].advance(crowd_input(f, k2)))
      k2 = k2 + 1
    }
    // 3 号玩家的输入晚 5 帧才到
    if f > 5 {
      let mut k3 = 0
      while k3 < n {
        if k3 != late {
          s[k3].receive_from(late, f - 5, crowd_input(f - 5, late))
        }
        k3 = k3 + 1
      }
    }
  }
  // 补送剩下 5 帧
  let mut extra = 0
  while extra < 5 {
    extra = extra + 1
    let frame = 240 - 5 + extra
    let mut k = 0
    while k < n {
      if k != late {
        s[k].receive_from(late, frame, crowd_input(frame, late))
      }
      k = k + 1
    }
  }
  // 所有人都已确认到 240 帧，逐帧比对历史哈希
  let mut k = 0
  while k < n {
    assert_eq(s[k].confirmed(), 240)
    // 迟到的是 3 号玩家自己的输入，所以它本人不会回滚；另外三端一定回滚过
    if k != late {
      assert_true(s[k].rollbacks() > 0)
      assert_true(s[k].replayed() > 0L)
    }
    k = k + 1
  }
  let mut f2 = 1
  while f2 <= 240 {
    let base = s[0].hash_at(f2)
    let mut j = 1
    while j < n {
      assert_eq(s[j].hash_at(f2), base)
      j = j + 1
    }
    f2 = f2 + 1
  }
}

///|
test "out of range player index is ignored" {
  let s = @session.Session::with_players({ v: 0UL, }, 4, 0, 64)
  ignore(s.advance(1UL))
  let before = s.frame()
  s.receive_from(-1, 1, 9UL)
  s.receive_from(4, 1, 9UL)
  s.receive_from(99, 1, 9UL)
  assert_eq(s.frame(), before)
  assert_eq(s.player_input(4, 1), None)
  assert_eq(s.player_input(-1, 1), None)
}

///|
test "two player shortcut is ignored in a bigger room" {
  let s = @session.Session::with_players({ v: 0UL, }, 4, 0, 64)
  ignore(s.advance(1UL))
  // 4 人局里「对端」没有唯一含义，便捷入口必须什么都不做
  s.receive(1, 7UL)
  assert_eq(s.player_input(1, 1), None)
  assert_eq(s.player_input(2, 1), None)
  assert_eq(s.player_input(3, 1), None)
}

///|
test "player count and local id are clamped" {
  assert_eq(
    @session.Session::with_players({ v: 0UL, }, 0, 0, 8).player_count(),
    1,
  )
  assert_eq(
    @session.Session::with_players({ v: 0UL, }, 99, 5, 8).player_count(),
    @session.MAX_PLAYERS,
  )
  assert_eq(
    @session.Session::with_players({ v: 0UL, }, 4, 9, 8).local_player(),
    3,
  )
  assert_eq(
    @session.Session::with_players({ v: 0UL, }, 4, -3, 8).local_player(),
    0,
  )
  // 双人便捷构造仍然等价于 with_players(sim, 2, ...)
  assert_eq(@session.Session::new({ v: 0UL, }, 1).player_count(), 2)
  assert_eq(@session.Session::with_window({ v: 0UL, }, 1, 32).player_count(), 2)
}

///|
test "single player session confirms every frame" {
  let s = @session.Session::with_players({ v: 0UL, }, 1, 0, 16)
  let mut f = 0
  while f < 50 {
    f = f + 1
    ignore(s.advance(crowd_input(f, 0)))
  }
  assert_eq(s.confirmed(), 50)
  assert_eq(s.rollbacks(), 0)
}
