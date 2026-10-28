///|
/// Scripted inputs: p0 walks right, p1 walks left, both jump now and then.
fn scripted(i : Int32) -> (UInt64, UInt64) {
  let p0 = if i % 9 < 4 { 0b011UL } else if i % 13 == 0 { 0b110UL } else { 0UL }
  let p1 = if i % 11 < 3 { 0b001UL } else { 0UL }
  (p0, p1)
}

///|
fn run_script(sim : PhysSim, from : Int32, to : Int32) -> Unit {
  let mut i = from
  while i < to {
    let (p0, p1) = scripted(i)
    sim.step(p0, p1)
    i = i + 1
  }
}

///|
test "two fresh phys sims stay bit-identical" {
  let a = PhysSim::new()
  let b = PhysSim::new()
  run_script(a, 0, 240)
  run_script(b, 0, 240)
  assert_eq(@session.Sim::hash(a), @session.Sim::hash(b))
}

///|
test "restore plus replay matches the uninterrupted run" {
  let a = PhysSim::new()
  let b = PhysSim::new()
  // Both step to frame 120; the boxes are resting on the floor by then, so the
  // snapshot carries non-trivial contact impulses.
  run_script(a, 0, 120)
  run_script(b, 0, 120)
  let hash_mark = @session.Sim::hash(a)
  let mark = @session.Sim::save(a)
  run_script(a, 120, 300)
  let hash_end = @session.Sim::hash(a)
  // Rewind and replay the very same input range.
  @session.Sim::restore(b, mark)
  assert_eq(@session.Sim::hash(b), hash_mark)
  run_script(b, 120, 300)
  assert_eq(@session.Sim::hash(b), hash_end)
}
