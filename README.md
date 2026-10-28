# moonroll

> Sans-IO deterministic rollback netcode for MoonBit.

MoonBit 生态里"把两个玩家连起来还不漂移"这一层是空白。
`moonroll` 补的就是这一层：不绑定任何引擎的确定性回滚同步（rollback netcode）。

**状态：V0.5（示例与 CI 收口）**。定点数、状态哈希、输入环、预测 / 确认 / 回滚重放、
紧凑字节协议、确定性延迟 / 抖动 / 丢包 / 乱序模拟器，一个把两个 `moonphys` 物理世界连起来的
可视化演示，以及三个 `moon run` 就能跑的示例。`moon check --deny-warn` 与 `moon fmt --check`
在 CI 里全绿。

设计取舍见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)。

---

## 为什么需要定点数

回滚同步的前提是：**同一串输入，在任何后端、任何 CPU 上必须产生逐位相同的轨迹**。

浮点不是不能用：本项目实测 `js` 与 `wasm-gc` 后端对同一份代码输出**完全相同的位模式**
（12 个采样 + 1000 / 10000 步非线性迭代）。但 native 与跨平台仍会受编译器优化、
FMA 收缩、超越函数实现差异影响，所以提供一条纯整数的路径：

- 加减乘除、开方、插值全部是整数运算，语义由 MoonBit 的 `Int64` 保证；
- 不依赖任何浮点库，也就不存在"换个编译器结果就变"的问题。

## 接入方式：4 个方法

```moonbit
pub(open) trait Sim {
  fn save(Self) -> Bytes            // 编码完整状态
  fn restore(Self, Bytes) -> Unit   // 与 save 严格互逆
  fn step(Self, UInt64, UInt64)     // 推进一帧，p0 / p1 是双方输入位图
  fn hash(Self) -> UInt64           // 状态哈希，不一致即 desync
}
```

接入成本约 30~50 行。库不假设任何引擎结构，只在每帧调用这四个方法。

## 快速开始

```bash
moon add weopqrst/moonroll
```

```moonbit
// 1) 实现 Sim（略去 save/restore/hash）
impl @session.Sim for World with fn step(self, p0, p1) {
  self.x = self.x * 31UL + p0 + (p1 << 32)
}

// 2) 每个对等体一个会话，local_id 是本地玩家（0 / 1）
let peer = @session.Session::with_window(world, 0, 128)

// 3) 每帧推进；收到对端输入时自动回滚重放
ignore(peer.advance(my_input))
peer.receive(remote_frame, opponent_input)

// 4) 双方定期比对
if peer.hash() != remote_hash {
  // desync
}
```

底层三个包可单独使用：

```moonbit
let a = @fixed.Fixed::from_double(1.5)
let b = @fixed.Fixed::from_double(2.25)
let c = a * b                      // 3.375，整数运算

let d = @digest.Digest::new()
d.feed_bytes(b"state")
let checksum = d.finish()

let ring = @input.InputRing::new(64)
ring.set(frame, 0b101UL)
```

## 字节协议

线上格式（小端；`varint` 为 LEB128，帧号小的时候只占 1 字节）：

| 帧 | 布局 |
| --- | --- |
| Input | `[0x01][varint frame][varint count][varint bits] × count` |
| Confirm | `[0x02][varint frame]` |
| Checksum | `[0x03][varint frame][8 bytes hash]` |

```moonbit
let wire = @protocol.encode(@protocol.Message::Input(
  @protocol.InputFrame::new(42, [0b101UL]),
))
let msg = @protocol.decode(wire)          // Some(Input(...))

// 一条链路每帧只发一个包时，把多个帧塞进同一个包
let batch = @protocol.encode_batch(msgs)
for m in @protocol.decode_batch(batch) { /* ... */ }
```

`encode` 不做数量校验（`count` 由调用方决定），`decode` 对截断、未知标签、垃圾字节、
超过 8 个玩家的帧一律返回 `None`，不会 panic。这是「网络输入不可信」的底线。

## 网络模拟器

```moonbit
let net = @sim_net.NetSim::new(
  @sim_net.Link::new(delay, jitter, loss_pct, reorder_pct, seed),
)
net.send(frame, payload)                 // 可能被丢弃
for packet in net.recv(frame) { /* ... */ } // 到达的包，按到达时间排序
net.delivered()  // 已交付包数
net.dropped()    // 丢弃包数
net.in_flight()  // 在途包数
```

时间单位是逻辑帧（60fps 下 1 帧 ≈ 16.7ms），内部是确定性 LCG：
**同 seed、同发送序列必然得到同到达序列**，所以整条链路可以进单元测试和 fuzz。

## 三个 `moon run` 就能跑的示例

```bash
# 1) 最小闭环：两个 Session + 真实字节协议 + 3 帧延迟链路，逐帧打印收敛过程
moon run examples/two_peer

# 2) 延迟曲线：8 条典型链路跑同一局，输出可贴进文档的表格
moon run examples/latency_chart

# 3) 分叉检测自证：正常局不报警，注入一处输入不一致后被抓到具体帧号
moon run examples/desync_demo
```

`latency_chart` 的真实输出（300 帧，60fps）：

| 场景 | 延迟 | 抖动 | 丢包 | 乱序 | 回滚次数 | 重放帧数 | 最大深度 | 确认帧 | 分叉帧 | 一致 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 局域网 16ms | 0 | 0 | 0% | 0% | 300 | 300 | 1 | 300/300 | - | yes |
| 同城 33ms | 2 | 0 | 0% | 0% | 300 | 897 | 3 | 300/300 | - | yes |
| 跨城 100ms | 6 | 0 | 0% | 0% | 300 | 2079 | 7 | 300/300 | - | yes |
| 跨城 100ms ±50ms | 6 | 3 | 0% | 0% | 300 | 2443 | 10 | 300/300 | - | yes |
| 跨城 100ms +10% 乱序 | 6 | 3 | 0% | 10% | 300 | 2464 | 11 | 300/300 | - | yes |
| 跨城 100ms +5% 丢包 | 6 | 3 | 5% | 0% | 300 | 2468 | 11 | 300/300 | - | yes |
| 跨洋 200ms ±50ms | 12 | 3 | 0% | 0% | 300 | 4180 | 16 | 300/300 | - | yes |
| 跨洋 200ms ±50ms +25% 乱序 | 12 | 3 | 0% | 25% | 300 | 4229 | 17 | 300/300 | - | yes |

延迟 / 抖动单位是逻辑帧（1 帧 ≈ 16.7ms），丢包 / 乱序是百分比。

**回滚次数恒等于帧数**——每帧都会收到一帧更早的输入，必然重放一次。真正随延迟
增长的是「重放帧数」和「最大深度」，那才是 CPU 成本：局域网 300 帧重放 300 帧，
跨洋 200ms 要重放 4229 帧（约 14 倍）。

`two_peer` 的循环是手写的，可以当接入模板读：每帧打包「最近 8 帧输入 + 确认帧 +
校验和帧」，接收端解码后逐条投递。`desync_demo` 里那处故障注入用的是「本地执行 A、
发出去的是 B」——不能直接去改内存里的状态，回滚会从快照恢复并把它洗掉。

## 演示：两个物理世界互相同步

`adapters/phys` 把 `moonphys` 的 `World` 包成 `Sim`：`save` / `restore` 走
`World::save_state` / `World::load_state`（含位姿、速度、暖启动冲量与世界时钟），
`hash` 走 `state_hash`。`demo/` 里跑一局真实对局：两个独立物理世界、两个 `Session`、
两条带延迟 / 抖动 / 丢包 / 乱序的模拟链路，每帧互发最近 8 帧输入。

```bash
# 构建 wasm 产物到 docs/engine.wasm（产物已提交，改代码后重跑）
pwsh tools/build-demo.ps1

# 无头验收：1800 帧脚本对局，200ms 延迟 + 50ms 抖动
node tools/check-demo.mjs
# 自检 frames=1860 confirmed=1846/1846 rollbacks=1846/1846 desync=0 bodies=3

# 本地预览页面（wasm 不能走 file://）
python -m http.server --directory docs 8123
```

页面在 `docs/index.html` + `docs/app.js`，零外部依赖，导出全是数值 ABI：

| 导出 | 作用 |
| --- | --- |
| `mr_reset(delay, jitter, loss, reorder)` | 重建一局，参数单位是帧 / 百分比 |
| `mr_step(i0, i1)` | 推进一帧，`i0` / `i1` 是双方输入位图 |
| `mr_confirmed` / `mr_rollbacks` / `mr_desync` | 确认帧、回滚次数、分叉次数 |
| `mr_synced` / `mr_hash_lo` / `mr_hash_hi` | 两端状态哈希是否一致 |
| `mr_body_*` | 刚体位姿，供 canvas 直接画 |
| `mr_selftest()` | 跑完整 1800 帧验收，0 表示通过 |

页面上左侧是 P0 的本地世界、右侧是 P1 的本地世界，同色虚线框是对端眼中同一物体的位置：
延迟拉大时能看到虚线与实体暂时错开，回滚重放后重新贴合，`desync` 始终为 0。

分叉判定只比**已确认帧**的历史哈希（`Session::hash_at`）。直接比当前帧会把两端各自不同的
预测误判成分叉——预测本来就可以合法地不同，只有双方输入都到齐的帧才必须逐位一致。

## 性能

`moon bench -p weopqrst/moonroll/session`（wasm-gc，Windows x64）：

| 场景 | 耗时（均值） |
| --- | --- |
| 每帧预测 + 深度 16 回滚重放 | 0.51 µs |
| 每帧预测 + 深度 128 回滚重放 | 14.4 µs |

基准里的状态是 8 字节的 `UInt64` 计数器，真实引擎的重放成本按「快照大小 × 回滚深度」线性放大，
可以直接用这个数估上限。

## 包结构

| 包 | 内容 | 状态 |
| --- | --- | --- |
| `weopqrst/moonroll/fixed` | Q16.16 定点数（`+ - * /`、开方、lerp、clamp） | V0.1 |
| `weopqrst/moonroll/digest` | FNV-1a 64 状态哈希 | V0.1 |
| `weopqrst/moonroll/input` | 帧号 -> 输入位图的环形缓冲 | V0.1 |
| `weopqrst/moonroll/session` | `Sim` 协议 + 预测 / 确认 / 回滚重放 / 历史哈希 | V0.2 |
| `weopqrst/moonroll/protocol` | 输入帧、确认帧、校验和帧的字节编解码 | V0.3 |
| `weopqrst/moonroll/sim_net` | 延迟 / 抖动 / 丢包 / 乱序模拟器 | V0.3 |
| `weopqrst/moonroll/adapters/phys` | `moonphys` 参考适配层（`PhysSim`） | V0.4 |
| `weopqrst/moonroll/demo` | wasm-gc 演示引擎（`mr_*` 数值导出） | V0.4 |
| `weopqrst/moonroll/examples/scene` | 示例共用场景与对局运行器 | V0.5 |
| `weopqrst/moonroll/examples/two_peer` | 最小联机闭环 | V0.5 |
| `weopqrst/moonroll/examples/latency_chart` | 延迟 / 抖动 / 丢包扫描表 | V0.5 |
| `weopqrst/moonroll/examples/desync_demo` | 分叉检测自证 | V0.5 |

## 验证

```bash
moon check --deny-warn     # 零警告
moon fmt --check           # 格式一致
moon test --target wasm-gc
moon test --target js
node tools/check-demo.mjs  # 1800 帧 wasm 自检
```

CI（`.github/workflows/ci.yml`）跑的就是这一串，外加三个示例的冒烟和
「提交的 `docs/engine.wasm` 必须与重新构建的产物逐字节一致」。

122 个测试，两个后端全绿。核心断言：

- 定点数与 `Double` 对拍误差不超过 4 个 LSB；
- FNV-1a 64 对 `"hello"` 命中标准向量 `0xa430d84680aabd0b`；
- **双对等体 3000 帧、2 帧固定延迟：终态哈希与顺序参考实现完全一致；**
- **乱序 + 0~3 帧抖动（不丢包）600 帧：终态哈希仍然一致；**
- **8 条链路曲线（0 / 50 / 100 / 200 / 300ms、±50ms 抖动、5% 丢包、25% 乱序）× 300 帧，
  两端终态哈希都等于顺序参考实现；**
- **1000 组随机 (delay, jitter, loss, reorder, seed) fuzz：两端哈希一致；**
- 协议 round-trip：1000 组随机输入帧 + 500 组确认 / 校验和帧逐位还原；
  所有前缀截断与随机垃圾字节只返回 `None`，不 panic；
- 模拟器同种子可复现（同发送序列 → 同到达序列），抖动确实产生逆序交付；
- 输入环 / 快照环回绕后只保留窗口内帧，旧帧不会误命中；
- **两个 `moonphys` 物理世界 240 帧逐位相同；120 帧快照恢复后重放至 300 帧，hash 仍与不中断运行一致；**
- **200ms 延迟 + 50ms 抖动下 600 帧真实对局：`desync=0`，两端在已确认帧上哈希逐步一致；**
- **15% 丢包下回滚次数大于零，但两端仍是 `desync=0`（重发把丢掉的输入补齐）；**
- **`hash_at` 在回滚重放后返回重放结果，超出快照窗口后返回 `None`；**
- **示例层：干净链路零失配；注入一处输入不一致后，分叉被报在**恰好那一帧**上，
  且两端哈希不同；同参数两次运行的统计量逐项相等；重放帧数随延迟显著增长而
  回滚次数恒等于帧数。**

## Roadmap

- **V0.1** 基础层：定点数、状态哈希、输入环（已完成）
- **V0.2** 回滚会话：预测、确认、快照/恢复、重放（已完成）
- **V0.3** 字节协议 + 延迟/抖动/丢包/乱序模拟 + fuzz（已完成）
- **V0.4** 接入 `moonphys` 的 wasm-gc 可视化演示（双世界对照、回滚计数、延迟滑块）（已完成）
- **V0.5** 三个可运行示例 + 零警告 CI（`--deny-warn`、`fmt --check`、demo 产物校验）+ 架构文档（当前）
- **V1.0** GitHub Pages 在线演示、验收脚本、mooncakes 发布

## 明确不做

- 真 UDP/TCP 联机（`moonbitlang/async` 的 socket 不支持 `wasm-gc`，浏览器内不可用）
- 服务端权威模式、房间匹配
- 具体引擎绑定（只提供 `Sim` 接口，接入成本目标 30 行）

## License

Apache-2.0
