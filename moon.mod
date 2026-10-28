// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "weopqrst/moonroll"

version = "0.8.0"

readme = "README.mbt.md"

repository = "https://github.com/mihujiang/moonroll"

license = "Apache-2.0"

keywords = [ "netcode", "rollback", "determinism", "fixed-point", "game" ]

preferred_target = "wasm-gc"

description = "Sans-IO deterministic rollback netcode for MoonBit: input ring buffer, prediction, rollback re-simulation, state checksums, compact byte protocol with input spans and change masks, deterministic link simulator, a moonphys wasm-gc demo, six runnable examples, 1..8 player sessions, and drop/rejoin handling."

import {
  "weopqrst/moonphys@0.2.2",
}
