///|
/// 60 Hz fixed step, the only timestep the demo and the tests use.
pub const STEP_DT : Double = 1.0 / 60.0

///|
/// Bit 0 moves left, bit 1 moves right, bit 2 jumps. Same layout as the
/// keyboard mapping in `docs/index.html`.
const INPUT_LEFT : UInt64 = 0b001UL

///|
const INPUT_RIGHT : UInt64 = 0b010UL

///|
const INPUT_JUMP : UInt64 = 0b100UL

///|
/// Horizontal impulse per frame while holding a direction.
const MOVE_IMPULSE : Double = 0.08

///|
/// Vertical impulse of one jump; only applied when the body is nearly at rest
/// on the ground, which keeps the replay deterministic.
const JUMP_IMPULSE : Double = 3.0

///|
/// Two arena boxes on a static floor, wrapped as a `Sim` so `Session` can
/// predict, roll back and re-simulate it.
///
/// This is the reference adapter: the whole state lives in
/// `@moonphys.World::save_state`, so a forgotten field shows up immediately as
/// a hash mismatch between the two peers.
pub struct PhysSim {
  world : @moonphys.World
  body_p0 : Int32
  body_p1 : Int32
}

///|
/// A fresh arena: one static floor plus one box per player.
pub fn PhysSim::new() -> PhysSim {
  let world = @moonphys.World::new()
  ignore(
    world.add_body(
      @moonphys.Body::fixed(@moonphys.Shape::box(30.0, 0.5)).at(0.0, -0.5),
    ),
  )
  let body_p0 = world.add_body(
    @moonphys.Body::box(0.45, 0.45)
    .at(-1.5, 1.2)
    .with_friction(0.5)
    .with_user_data(1),
  )
  let body_p1 = world.add_body(
    @moonphys.Body::box(0.45, 0.45)
    .at(1.5, 1.2)
    .with_friction(0.5)
    .with_user_data(2),
  )
  { world, body_p0, body_p1, }
}

///|
/// Turn an input bitmap into impulses on the player's body.
fn apply_input(world : @moonphys.World, index : Int32, bits : UInt64) -> Unit {
  let body = world.body(index)
  body.wake()
  let mut dx = 0.0
  if (bits & INPUT_LEFT) != 0UL {
    dx = dx - MOVE_IMPULSE
  }
  if (bits & INPUT_RIGHT) != 0UL {
    dx = dx + MOVE_IMPULSE
  }
  if (bits & INPUT_JUMP) != 0UL {
    // Only jump from the ground: velocity is part of the simulated state, so
    // this test replays identically on both peers.
    if body.velocity().y.abs() < 0.35 {
      body.apply_impulse(
        @moonphys.Vec2::new(0.0, JUMP_IMPULSE),
        body.position(),
      )
    }
  }
  if dx != 0.0 {
    body.apply_impulse(@moonphys.Vec2::new(dx, 0.0), body.position())
  }
}

///|
pub impl @session.Sim for PhysSim with fn save(self) {
  self.world.save_state()
}

///|
pub impl @session.Sim for PhysSim with fn restore(self, bytes) {
  ignore(self.world.load_state(bytes))
}

///|
pub impl @session.Sim for PhysSim with fn step(self, p0, p1) {
  apply_input(self.world, self.body_p0, p0)
  apply_input(self.world, self.body_p1, p1)
  self.world.step(STEP_DT)
}

///|
pub impl @session.Sim for PhysSim with fn hash(self) {
  self.world.state_hash()
}

///|
/// 显式声明方法提升（消除 W0079）。
pub extend PhysSim with @session.Sim::{step, save, restore, hash}

///|
/// Read access for rendering.
pub fn PhysSim::world(self : PhysSim) -> @moonphys.World {
  self.world
}

///|
/// Body index of player `slot` (0 or 1).
pub fn PhysSim::player_body(self : PhysSim, slot : Int32) -> Int32 {
  if slot == 0 {
    self.body_p0
  } else {
    self.body_p1
  }
}
