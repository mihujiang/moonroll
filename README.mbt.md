# moonroll

> Sans-IO deterministic rollback netcode for MoonBit.

MoonBit 生态里 ECS、物理、寻路、渲染、行为树都已经有人做，但"把两个玩家连起来还不漂移"这一层是空白。
`moonroll` 补的就是这一层：不绑定任何引擎的确定性回滚同步（rollback netcode）。

**状态：V1.0**。定点数、状态哈希、输入环、预测 / 确认 / 回滚重放、
紧凑字节协议（区间帧 + 变化掩码 + 全量状态帧）、确定性延迟 / 抖动 / 丢包 / 乱序模拟器，
一个把两个 `moonphys` 物理世界连起来的可视化演示，以及七个 `moon run` 就能跑的示例
（含四人对局重放成本对比、掉线走势对比、五种发包策略的带宽对比、分叉后的全量重同步）。

在线演示（浏览器里直接跑）：<https://mihujiang.github.io/moonroll/>

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

```moonbit nocheck
///|
pub(open) trait Sim {
  fn save(Self) -> Bytes // 编码完整状态
  fn restore(Self, Bytes) -> Unit // 与 save 严格互逆
  fn step_players(Self, Array[UInt64]) // 推进一帧，inputs[i] 是第 i 个玩家的输入位图
  fn hash(Self) -> UInt64 // 状态哈希，不一致即 desync
}
```

接入成本约 30~50 行。库不假设任何引擎结构，只在每帧调用这四个方法。
`step_players` 收到的数组由会话复用，只读不存。

## 快速开始

```bash
moon add weopqrst/moonroll
```

```moonbit nocheck
// 1) 实现 Sim（略去 save/restore/hash）
impl @session.Sim for World with fn step_players(self, inputs) {
  let mut x = self.x * 31UL
  for i, bits in inputs {
    x = x + (bits << (i * 4))
  }
  self.x = x
}

// 2) 每个对等体一个会话：with_players(世界, 人数, 本地玩家, 窗口)
let peer = @session.Session::with_players(world, 4, 0, 128)

// 3) 每帧推进；收到某位玩家的输入时自动回滚重放
ignore(peer.advance(my_input))
peer.receive_from(who, frame, that_player_input)

// 4) 所有玩家在同一个已确认帧上比对
if peer.hash_at(peer.confirmed()) != remote_hash_at_confirmed {
  // desync
}
```

双人局仍可用 `Session::with_window(world, local_id, 128)` 与 `receive(frame, input)`。

底层三个包可单独使用：

```moonbit nocheck
let a = @fixed.Fixed::from_double(1.5)
let b = @fixed.Fixed::from_double(2.25)
let c = a * b

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
| Input | `[0x01][varint player][varint frame][varint count][varint bits] × count` |
| Confirm | `[0x02][varint frame]` |
| Checksum | `[0x03][varint frame][8 bytes hash]` |
| Snap | `[0x06][varint frame][varint len][len bytes 状态]` |
| SnapAsk | `[0x07][varint frame]` |

```moonbit nocheck
let wire = @protocol.encode(@protocol.Message::Input(
  @protocol.InputFrame::new_from(player, 42, [0b101UL]),
))
let msg = @protocol.decode(wire)          // Some(Input(...))

// 一条链路每帧只发一个包时，把多个帧塞进同一个包
let batch = @protocol.encode_batch(msgs)
for m in @protocol.decode_batch(batch) { /* ... */ }
```

`encode` 不做数量校验（`count` 由调用方决定），`decode` 对截断、未知标签、垃圾字节、
超过 8 个玩家的帧一律返回 `None`，不会 panic。这是「网络输入不可信」的底线。

`Snap` 是某一帧的完整状态（`Sim::save` 的原始字节，上限 64 KiB），`SnapAsk` 是「把那一帧
的状态给我」。分叉之后落后端先 `SnapAsk`，权威端回 `Snap`，落后端再 `resync_from` 整段替换：

```moonbit nocheck
if peer.hash_at(frame) != remote_hash {
  // 这一帧就是恢复点：它不早于事故帧，之后的输入两端已经一致
  @protocol.SnapRequest(@protocol.SnapRequestFrame::new(frame))
}
if let Some(state) = peer.export_state(frame) {
  @protocol.Snap(@protocol.SnapFrame::new(frame, state))
}
peer.resync_from(frame, state)   // 越界 / 超出快照窗口返回 false
peer.resyncs()                   // 正常情况下恒为 0
```

恢复点必须在快照窗口内（更早的输入已被输入环淘汰，重放会用猜出来的值）；恢复后确认帧
只前进不回退，本地输入环与帧号不动。重同步修的是未来，恢复点之前的旧哈希不会被改写。

## 网络模拟器

```moonbit nocheck
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

## 七个 `moon run` 就能跑的示例

```bash
moon run examples/two_peer        # 最小闭环：两个 Session + 字节协议 + 3 帧延迟
moon run examples/latency_chart   # 8 条典型链路的回滚成本表
moon run examples/desync_demo     # 分叉检测自证：注入输入不一致，报出确切帧号
moon run examples/four_peer       # 四人对局：12 条链路全互联 + 2/4 人成本对比
moon run examples/drop_out        # 掉线：宣布 / 不宣布掉线的确认帧走势对比
moon run examples/bandwidth       # 带宽：五种发包策略的字节数对比
moon run examples/resync          # 分叉恢复：用一份完整状态把落后者掰回来
```

`latency_chart` 的真实输出（300 帧，60fps，全部 `desync=0`）：

| 场景 | 延迟(帧) | 抖动 | 丢包 | 乱序 | 回滚次数 | 重放帧数 | 最大深度 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 局域网 16ms | 0 | 0 | 0% | 0% | 300 | 300 | 1 |
| 同城 33ms | 2 | 0 | 0% | 0% | 300 | 897 | 3 |
| 跨城 100ms | 6 | 0 | 0% | 0% | 300 | 2079 | 7 |
| 跨城 100ms ±50ms | 6 | 3 | 0% | 0% | 300 | 2443 | 10 |
| 跨城 100ms +5% 丢包 | 6 | 3 | 5% | 0% | 300 | 2468 | 11 |
| 跨洋 200ms ±50ms | 12 | 3 | 0% | 0% | 300 | 4180 | 16 |
| 跨洋 200ms ±50ms +25% 乱序 | 12 | 3 | 0% | 25% | 300 | 4229 | 17 |

回滚次数恒等于帧数（每帧都会收到一帧更早的输入），真正随延迟增长的是「重放帧数」
与「最大深度」——那才是 CPU 成本。

## 演示：两个物理世界互相同步

`adapters/phys` 把 `moonphys` 的 `World` 包成 `Sim`（`save` / `restore` 走
`World::save_state` / `World::load_state`），`demo/` 里两个独立物理世界、两个 `Session`、
两条带延迟 / 抖动 / 丢包 / 乱序的链路每帧互发最近 8 帧输入：

```bash
pwsh tools/build-demo.ps1     # 产出 docs/engine.wasm
node tools/check-demo.mjs     # 无头验收：1800 帧、200ms 延迟、50ms 抖动
python -m http.server --directory docs 8123   # 打开 http://localhost:8123/
```

在线版就是 `docs/` 目录本身，由 `.github/workflows/pages.yml` 在每次推送后发布。

页面零外部依赖，导出全是数值 ABI（`mr_reset` / `mr_step` / `mr_confirmed` /
`mr_rollbacks` / `mr_desync` / `mr_synced` / `mr_hash_lo|hi` / `mr_body_*` / `mr_selftest`）。
左侧与右侧分别是两个玩家眼中的世界，同色虚线框是对端眼中的同一物体：延迟拉大时暂时错开，
回滚重放后重新贴合，`desync` 始终为 0。

分叉判定只比**已确认帧**的历史哈希（`Session::hash_at`），比当前帧会把两端各自不同的预测
误判成分叉。

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
| `weopqrst/moonroll/session` | `Sim` 协议 + 预测 / 确认 / 回滚重放 / 历史哈希 + 1..8 人会话 + 分叉重同步 | V0.2 |
| `weopqrst/moonroll/protocol` | 输入帧、确认帧、校验和帧、全量状态帧的字节编解码 | V0.3 |
| `weopqrst/moonroll/sim_net` | 延迟 / 抖动 / 丢包 / 乱序模拟器 | V0.3 |
| `weopqrst/moonroll/adapters/phys` | `moonphys` 参考适配层（`PhysSim`） | V0.4 |
| `weopqrst/moonroll/demo` | wasm-gc 演示引擎（`mr_*` 数值导出） | V0.4 |
| `weopqrst/moonroll/examples/scene` | 示例共用场景与对局运行器 | V0.5 |
| `weopqrst/moonroll/examples/two_peer` | 最小联机闭环 | V0.5 |
| `weopqrst/moonroll/examples/latency_chart` | 延迟 / 抖动 / 丢包扫描表 | V0.5 |
| `weopqrst/moonroll/examples/desync_demo` | 分叉检测自证 | V0.5 |
| `weopqrst/moonroll/examples/four_peer` | 四人对局 + 2/4 人重放成本对比 | V0.6 |
| `weopqrst/moonroll/examples/drop_out` | 掉线前后确认帧走势对比 | V0.7 |
| `weopqrst/moonroll/examples/bandwidth` | 五种发包策略的字节数对比 | V0.8 |
| `weopqrst/moonroll/examples/resync` | 分叉后的全量重同步 | V0.9 |

## 验证

```bash
node tools/verify.mjs    # check + fmt + 双后端测试 + native + 七个示例 + demo 自检
```

166 个测试，两个后端全绿；`moon check --deny-warn` 与 `moon fmt --check` 在 CI 里全绿。核心断言：

- 定点数与 `Double` 对拍误差不超过 4 个 LSB；
- FNV-1a 64 对 `"hello"` 命中标准向量 `0xa430d84680aabd0b`；
- 双对等体 3000 帧、2 帧固定延迟：终态哈希与顺序参考实现完全一致；
- 乱序 + 0~3 帧抖动（不丢包）600 帧：终态哈希仍然一致；
- 8 条链路曲线（0 / 50 / 100 / 200 / 300ms、±50ms 抖动、5% 丢包、25% 乱序）× 300 帧，
  两端终态哈希都等于顺序参考实现；
- 1000 组随机 (delay, jitter, loss, reorder, seed) fuzz：两端哈希一致；
- 协议 round-trip：1000 组随机输入帧 + 500 组确认 / 校验和帧逐位还原；
  所有前缀截断与随机垃圾字节只返回 `None`，不 panic；
- 模拟器同种子可复现（同发送序列 → 同到达序列），抖动确实产生逆序交付；
- 输入环 / 快照环回绕后只保留窗口内帧，旧帧不会误命中；
- 两个 `moonphys` 物理世界 240 帧逐位相同；120 帧快照恢复后重放至 300 帧，hash 仍与不中断运行一致；
- 200ms 延迟 + 50ms 抖动下 600 帧真实对局：`desync=0`，两端在已确认帧上哈希逐步一致；
- 15% 丢包下回滚次数大于零，但两端仍是 `desync=0`（重发把丢掉的输入补齐）；
- `hash_at` 在回滚重放后返回重放结果，超出快照窗口后返回 `None`；
- 示例层：干净链路零失配；注入一处输入不一致后，分叉被报在恰好那一帧上；
  同参数两次运行的统计量逐项相等；
- 掉线：宣布之后确认帧从掉线前那一帧补到当前帧，其余玩家逐帧哈希仍一致；重连不回退；
  本地玩家不能被标成掉线、最后一名在线玩家不能被踢、越界索引返回 `false`；
- 重同步：整段替换后恢复点及之后逐帧哈希重新一致，继续推进不再分叉，确认帧与本地输入环
  不回退；未来帧、0 帧、超出快照窗口的帧一律拒绝且会话不变；
- 状态帧：`Snap` / `SnapAsk` 往返一致，帧号 0、长度超 64 KiB、声明长度超出实际字节一律 `None`；
- resync 示例：无丢包时一次往返修好，4% 丢包下靠重试收敛，干净局重同步次数为 0。

## Roadmap

- **V0.1** 基础层：定点数、状态哈希、输入环（已完成）
- **V0.2** 回滚会话：预测、确认、快照/恢复、重放（已完成）
- **V0.3** 字节协议 + 延迟/抖动/丢包/乱序模拟 + fuzz（已完成）
- **V0.4** 接入 `moonphys` 的 wasm-gc 可视化演示（双世界对照、回滚计数、延迟滑块）（已完成）
- **V0.5** 三个可运行示例 + 零警告 CI + 架构文档（已完成）
- **V0.6** 1..8 人同局：每玩家一条输入环、`step_players` 接入、协议带玩家索引、四人对局示例（已完成）
- **V0.7** 掉线语义：在线集合、确认帧只等在线玩家、重连不回退、协议 `Active` 帧、掉线示例（已完成）
- **V0.8** 带宽：`InputSpan` 区间帧 + 变化掩码、对端水位自适应、校验和降频、带宽示例（已完成）
- **V0.9** 分叉恢复：`export_state` / `resync_from`、`Snap` / `SnapAsk` 帧、重同步示例（已完成）
- **V1.0** GitHub Pages 在线演示、一键验收脚本、mooncakes 发布（已完成）

## 明确不做

- 真 UDP/TCP 联机（`moonbitlang/async` 的 socket 不支持 `wasm-gc`，浏览器内不可用）
- 服务端权威模式、房间匹配
- 具体引擎绑定（只提供 `Sim` 接口，接入成本目标 30 行）

## License

Apache-2.0
