#!/usr/bin/env node
// 本地一键验收：把 CI 里 test / demo 两个 job 的门禁在同一台机器上串起来跑。
//
//   node tools/verify.mjs            # 全量：check / fmt / 双后端测试 / native / 七个示例 / demo
//   node tools/verify.mjs --quick    # 快速：只跑 check / fmt / 双后端测试
//   MOON_BIN=/path/to/moon node tools/verify.mjs
//
// moon 的查找顺序：$MOON_BIN → 相邻的 _toolchain/moonbit/bin/moon（本仓库的固定工具链）
// → PATH。注意 PATH 里那份 moon 的 core 版本可能与本仓库要求不一致，优先用前两个。
import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");
const quick = process.argv.slice(2).includes("--quick");

const EXAMPLES = [
  "two_peer",
  "latency_chart",
  "desync_demo",
  "four_peer",
  "drop_out",
  "bandwidth",
  "resync",
];

function findMoon() {
  if (process.env.MOON_BIN) return process.env.MOON_BIN;
  const exe = process.platform === "win32" ? "moon.exe" : "moon";
  const local = resolve(root, "..", "_toolchain", "moonbit", "bin", exe);
  if (existsSync(local)) return local;
  const probe = spawnSync(exe, ["version"], { encoding: "utf8" });
  if (probe.status === 0) return exe;
  throw new Error("找不到 moon：把它放进 PATH，或设置 MOON_BIN=/path/to/moon");
}

function exec(moon, label, args) {
  const started = Date.now();
  const shown = args.length > 6 ? [...args.slice(0, 4), `… ${args.length - 4} 个参数`] : args;
  process.stdout.write(`[${label}] ${shown.join(" ")}\n`);
  const r = spawnSync(moon, args, { cwd: root, stdio: "inherit" });
  const secs = ((Date.now() - started) / 1000).toFixed(1);
  const code = r.status > 2147483647 ? r.status - 4294967296 : r.status;
  return { code: r.status === 0 ? 0 : (code ?? r.signal), secs };
}

function run(moon, label, args) {
  const { code, secs } = exec(moon, label, args);
  if (code !== 0) {
    console.error(`\n✗ ${label} 失败（exit ${code}，${secs}s）\n`);
    process.exit(1);
  }
  console.log(`✓ ${label} ${secs}s\n`);
}

// native 后端要本机装 C 工具链（Linux 的 gcc / Windows 的 MSVC Build Tools）。
// CI 上必跑；本机缺工具链时跳过而不是让整个验收失败。
function runOptional(moon, label, args) {
  const { code, secs } = exec(moon, label, args);
  if (code !== 0) {
    console.log(`○ ${label} 跳过（exit ${code}，多半是本机没有 C 工具链，${secs}s）\n`);
    return false;
  }
  console.log(`✓ ${label} ${secs}s\n`);
  return true;
}

// 打包/构建产物在 workspace 模式下落在模块根的上一级 _build 里
function findDemoWasm() {
  const bases = [join(root, "_build"), resolve(root, "..", "_build")];
  for (const base of bases) {
    if (!existsSync(base)) continue;
    const hit = walk(base, "demo.wasm");
    if (hit) return hit;
  }
  return null;
}

function walk(dir, name) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      const hit = walk(full, name);
      if (hit) return hit;
    } else if (entry.name === name && statSync(full).size > 0) {
      return full;
    }
  }
  return null;
}

function trackedMbtFiles() {
  const r = spawnSync("git", ["ls-files", "*.mbt"], { cwd: root, encoding: "utf8" });
  if (r.status !== 0) throw new Error("git ls-files 失败；fmt 步骤需要 git");
  return r.stdout.split("\n").map((s) => s.trim()).filter(Boolean);
}

const moon = findMoon();
console.log(`moon: ${moon}\n项目: ${root}\n`);

run(moon, "check", ["check", "--deny-warn"]);
run(moon, "fmt", ["fmt", "--check", ...trackedMbtFiles()]);
run(moon, "test wasm-gc", ["test", "--target", "wasm-gc"]);
run(moon, "test js", ["test", "--target", "js"]);

if (!quick) {
  runOptional(moon, "build native", ["build", "--target", "native"]);
  for (const name of EXAMPLES) run(moon, `example ${name}`, ["run", `examples/${name}`]);
  run(moon, "build demo", ["build", "--target", "wasm-gc", "--release"]);

  const built = findDemoWasm();
  if (!built) throw new Error("没找到 demo.wasm");
  console.log(`demo wasm: ${built}\n`);
  // 提交进仓库的那份和刚构建的那份各跑一遍：字节可以因工具链版本而不同，
  // 但两边都必须 0 分叉地跑完 1800 帧脚本对局。
  run(process.execPath, "selftest shipped", [join(here, "check-demo.mjs")]);
  run(process.execPath, "selftest built", [join(here, "check-demo.mjs"), built]);
}

console.log("全部通过。");
