#!/usr/bin/env node
// 发布到 mooncakes：打包前先把「版本号 / 已有 tag / registry 上的最新版本」对一遍，
// 免得手滑把 1.0.0 发两遍（mooncakes 的版本号不能复用，发出去就删不掉）。
//
//   node tools/publish.mjs --dry-run   # 只检查 + 打包，不上传
//   node tools/publish.mjs             # 检查 + 打包 + moon publish
//
// 前置：moon login（token 落在 ~/.moon/credentials.json）。
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");
const dryRun = process.argv.slice(2).includes("--dry-run");

function fail(msg) {
  console.error(`✗ ${msg}`);
  process.exit(1);
}

function moonBin() {
  if (process.env.MOON_BIN) return process.env.MOON_BIN;
  const exe = process.platform === "win32" ? "moon.exe" : "moon";
  const local = resolve(root, "..", "_toolchain", "moonbit", "bin", exe);
  if (existsSync(local)) return local;
  return exe;
}

const mod = readFileSync(join(root, "moon.mod"), "utf8");
const name = /^name\s*=\s*"([^"]+)"/m.exec(mod)?.[1] ?? fail("moon.mod 里没有 name");
const version = /^version\s*=\s*"([^"]+)"/m.exec(mod)?.[1] ?? fail("moon.mod 里没有 version");
console.log(`模块: ${name}\n版本: ${version}\n`);

// mooncakes 现阶段只接受 0.x.y，发 1.0.0 会被服务端 403 拒掉
if (!/^0\.\d+\.\d+$/.test(version)) {
  fail("mooncakes 目前只接受 0.x.y 形式的版本号（服务端会直接 403），先改 moon.mod");
}

// 1) 本地已经打过 tag 说明这个版本可能发过了
const tags = spawnSync("git", ["tag", "-l", `v${version}`], { cwd: root, encoding: "utf8" });
if (tags.stdout.trim()) console.log(`! 本地已有 tag v${version}，确认这不是重复发布\n`);

// 2) registry 上的最新版本不该 >= 当前版本
const [ns, short] = name.split("/");
try {
  const res = await fetch(`https://mooncakes.io/api/v0/modules/${ns}/${short}`);
  if (res.ok) {
    const j = await res.json();
    const latest = j.latest_version ?? j.version;
    if (latest) {
      console.log(`registry 最新版本: ${latest}`);
      const cmp = compare(latest, version);
      if (cmp >= 0) {
        fail(`registry 上已有 ${latest} >= ${version}，先改 moon.mod 的 version`);
      }
    }
  }
} catch {
  console.log("! 查不到 registry 最新版本（离线？），跳过这一步比较");
}

function compare(a, b) {
  const pa = a.split(".").map(Number);
  const pb = b.split(".").map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (d !== 0) return d;
  }
  return 0;
}

// 3) 打包（moon package 不联网，纯粹校验模块能自洽）
const pack = spawnSync(moonBin(), ["package"], { cwd: root, stdio: "inherit" });
if (pack.status !== 0) fail("moon package 失败，先跑 node tools/verify.mjs");

// workspace 模式下产物落在模块根的上一级 _build 里，两种都找
const zipName = `-${version}.zip`;
const zip = [join(root, "_build", "publish"), resolve(root, "..", "_build", "publish")]
  .filter((d) => existsSync(d))
  .flatMap((d) => readdirSync(d).map((f) => join(d, f)))
  .filter((f) => f.endsWith(zipName))
  .sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs)[0];
if (!zip) fail(`没找到 ${zipName} 打包产物`);
console.log(`包: ${zip}\n`);

if (dryRun) {
  console.log("--dry-run：到此为止，没有上传。");
  process.exit(0);
}

// 4) 上传
const pub = spawnSync(moonBin(), ["publish"], { cwd: root, stdio: "inherit" });
if (pub.status !== 0) fail("moon publish 失败（多半是没登录或 token 过期，先 moon login）");
console.log(`\n已发布 ${name}@${version}`);
