// Headless acceptance check for docs/engine.wasm.
//
// Loads the wasm-gc demo (no imports), runs the built-in 1800-frame scripted
// match over a 200 ms / 50 ms-jitter link and prints the counters the README
// promises. Exit code 0 means both peers converged with zero divergence.
//
//   node tools/check-demo.mjs
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const wasmPath = join(here, "..", "docs", "engine.wasm");

const bytes = await readFile(wasmPath);
const { instance } = await WebAssembly.instantiate(bytes, {});
const e = instance.exports;

const required = [
  "mr_reset", "mr_step", "mr_frame", "mr_confirmed", "mr_rollbacks", "mr_desync",
  "mr_synced", "mr_hash_lo", "mr_hash_hi", "mr_in_flight", "mr_dropped",
  "mr_body_count", "mr_body_x", "mr_body_y", "mr_body_rotation", "mr_body_is_static",
  "mr_selftest",
];
const missing = required.filter((name) => typeof e[name] !== "function");
if (missing.length > 0) {
  console.error(`engine.wasm 缺少导出：${missing.join(", ")}`);
  process.exit(1);
}

const started = performance.now();
const code = e.mr_selftest();
const elapsed = performance.now() - started;

const report = {
  frames: e.mr_frame(),
  confirmed: [e.mr_confirmed(0), e.mr_confirmed(1)],
  rollbacks: [e.mr_rollbacks(0), e.mr_rollbacks(1)],
  desync: e.mr_desync(),
  bodies: e.mr_body_count(0),
  selftest: code,
};

console.log(
  `自检 frames=${report.frames} confirmed=${report.confirmed.join("/")} ` +
  `rollbacks=${report.rollbacks.join("/")} desync=${report.desync} ` +
  `bodies=${report.bodies} (${elapsed.toFixed(0)} ms)`,
);

if (code !== 0 || report.desync !== 0) {
  console.error("自检未通过：两端没有在已确认帧上收敛");
  process.exit(1);
}
if (report.rollbacks[0] === 0 || report.rollbacks[1] === 0) {
  console.error("自检未触发回滚：延迟链路没有生效");
  process.exit(1);
}
console.log("OK：200 ms 延迟 + 50 ms 抖动下两端逐帧一致，回滚已发生");
