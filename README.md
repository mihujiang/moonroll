# moonroll

> Sans-IO deterministic rollback netcode for MoonBit.

MoonBit 生态里"把两个玩家连起来还不漂移"这一层是空白。
`moonroll` 补的就是这一层：不绑定任何引擎的确定性回滚同步（rollback netcode）。

**状态：V0.9（分叉恢复）**。定点数、状态哈希、每个玩家一条输入环、
预测 / 确认 / 回滚重放、紧凑字节协议（含区间帧、变化掩码与全量状态帧）、确定性延迟 / 抖动 / 丢包 / 乱序模拟器，
一个把两个 `moonphys` 物理世界连起来的可视化演示，以及七个 `moon run` 就能跑的示例
（含四人对局重放成本对比、掉线前后确认帧走势对比、五种发包策略的带宽对比、分叉后的全量重同步）。
`moon check --deny-warn` 与 `moon fmt --check` 在 CI 里全绿。

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
  fn save(Self) -> Bytes                     // 编码完整状态
  fn restore(Self, Bytes) -> Unit            // 与 save 严格互逆
  fn step_players(Self, Array[UInt64])       // 推进一帧，inputs[i] 是第 i 个玩家的输入位图
  fn hash(Self) -> UInt64                    // 状态哈希，不一致即 desync
}
```

接入成本约 30~50 行。库不假设任何引擎结构，只在每帧调用这四个方法。
`step_players` 收到的数组由会话复用，只读不存，需要留用就把元素拷贝出来。

## 快速开始

```bash
moon add weopqrst/moonroll
```

```moonbit
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

// 4) 所有玩家定期在同一个已确认帧上比对
if peer.hash_at(peer.confirmed()) != remote_hash_at_confirmed {
  // desync
}
```

双人局可以继续用 `Session::with_window(world, local_id, 128)` 和 `receive(frame, input)`，
后者会自己推断对端是另一个玩家；3 人以上必须用 `receive_from`。

有人掉线时，别让他的沉默把全房确认帧拖死：

```moonbit
// 5) 什么时候算掉线是上层的策略（超时、房主踢人），本库只提供同步点
if frame - last_heard[who] > 30 {
  ignore(peer.set_player_active(who, false))   // 本地生效
  // 并把同样的决定同步给其他人：@protocol.Active(who, false)
}
peer.is_active(who)                            // false
peer.online_count()                            // 3
```

确认帧等的是**所有在线玩家**：宣布之后确认帧立刻补到当前帧，剩下的人继续同步推进。
掉线者的槽位仍然保留（模拟器的输入表长度不变），他的输入退化成
「窗口内最近一次已知值、否则 0」——所有对等体用同一套确定性规则，所以不会分叉。
重连用 `set_player_active(who, true)`，确认帧不会因此回退。

带宽上能省的地方在「重发多少帧」和「怎么表示这段帧」。收到对端的确认包时记一下水位，
就能把「固定重发 16 帧」换成「只发对方还没确认的那一段」：

```moonbit
peer.receive_confirm(who, msg.frame)   // 收到 who 的 Confirm 包
peer.peer_confirmed(who)               // 它已确认到哪一帧（从没收到过就是 0）

// 于是重发区间从 peer.peer_confirmed(who) + 1 开始，而不是盲发最近 16 帧
```

水位只会前进，迟到/重复的确认包不会把重发区间拽回去；丢包时水位停住，区间自动变长，
被丢的输入照样补上。

真出现分叉时，光报警没用：两端世界已经不同，回滚是从**本端**快照恢复的，只会把同一个
错误再算一遍。V0.9 因此提供「取状态 / 换状态」两个动作，把落后的一端整段掰回来：

```moonbit
// 落后端：在对端确认帧上比对失败，那一帧就是最合适的恢复点
if peer.hash_at(frame) != remote_hash {
  // 1) 请求这一帧的完整状态
  @protocol.SnapRequest(@protocol.SnapRequestFrame::new(frame))
}

// 权威端：把状态原样搬上线路（协议层不解释内容）
if let Some(state) = peer.export_state(frame) {
  @protocol.Snap(@protocol.SnapFrame::new(frame, state))
}

// 落后端：restore 到那一帧，再用本端输入环重放到当前帧
peer.resync_from(frame, state)   // 帧号越界 / 超出快照窗口时返回 false
peer.resyncs()                   // 正常情况下恒为 0
```

几点约束，都是「重放靠输入环」这一件事推出来的：

- 恢复点必须落在快照窗口内：更早的输入已经被环淘汰，重放会用猜出来的值，等于换一个地方重新分叉；
- 恢复后在线玩家的连续指针抬到恢复点，确认帧只前进不回退；
- 本地输入环和帧号都不动，只是换了一份世界，玩家自己的发送历史不受影响；
- 恢复点之前的旧哈希不会被改写——重同步修的是未来，不改写历史；
- 协议只给 `Snap` 的状态字节设上限（64 KiB），内容只有跑同一个 `Sim` 的对等体读得懂。

谁算权威是上层策略：两人局里就是「本地执行了 A 的那一端」，多人局按房主或多数票决定。
两边同时互相纠正会来回覆盖。

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
| Input | `[0x01][varint player][varint frame][varint count][varint bits] × count` |
| Confirm | `[0x02][varint frame]` |
| Checksum | `[0x03][varint frame][8 bytes hash]` |
| Active | `[0x04][varint player][varint active]`（1 上线 / 0 掉线） |
| InputSpan | `[0x05][varint player][varint start][varint count][varint mask][varint bits] × popcount(mask)` |
| Snap | `[0x06][varint frame][varint len][len bytes 状态]` |
| SnapAsk | `[0x07][varint frame]` |

`Input` 里的 `inputs[i]` 是玩家 `player + i` 的输入：单人单帧就是 `player=自己, count=1`，
`player + count` 不能越过 8 人上限。

`InputSpan` 是同一个玩家的**一段连续帧**：`count` 是帧数（1..64），`mask` 的第 i 位
表示 `start + i` 帧的输入是否随包发出，没置位的帧沿用包里前一个值。重发冗余输入时
一个人一帧一条 `Input` 是 4 字节，一段 16 帧、按键只变三次时 `InputSpan` 只要 9 字节。

`Snap` 携带某一帧的完整状态（`Sim::save` 的原始字节），`SnapAsk` 只是「把那一帧的状态
给我」。两者是分叉恢复的配套帧：请求方发 `SnapAsk`，权威端回 `Snap`。状态长度上限
64 KiB，`len` 越界或与实际字节数不符的包一律 `None`。

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

## 七个 `moon run` 就能跑的示例

```bash
# 1) 最小闭环：两个 Session + 真实字节协议 + 3 帧延迟链路，逐帧打印收敛过程
moon run examples/two_peer

# 2) 延迟曲线：8 条典型链路跑同一局，输出可贴进文档的表格
moon run examples/latency_chart

# 3) 分叉检测自证：正常局不报警，注入一处输入不一致后被抓到具体帧号
moon run examples/desync_demo

# 4) 四人对局：12 条链路全互联，并对比 2 人 / 4 人局的重放成本
moon run examples/four_peer

# 5) 掉线：3 号拔网线，对比「不宣布掉线」与「房主宣布」两种确认帧走势
moon run examples/drop_out

# 6) 带宽：同样一局，五种发包策略的字节数对比（区间帧 / 掩码 / 自适应 / 校验和降频）
moon run examples/bandwidth

# 7) 分叉恢复：输入流出错后两端世界不同，用一份完整状态把落后者掰回来
moon run examples/resync
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

`four_peer` 的真实输出（4 人全互联 = 12 条链路，480 帧，3 帧延迟 + 1 帧抖动）：

```
终态（4 人局）：
  一致 = true，首个分叉帧 = 无，校验失配 = 0
  确认帧 = 480/480/480/480，回滚 = 6983，重放帧数 = 31968，最大深度 = 5

同样 480 帧、同样链路参数下的规模对比：
  玩家数  链路数  回滚次数  重放帧数  最大深度
  2       2       960       4290      5
  4       12      6983      31968     5
```

人数翻倍，重放帧数涨了约 7.5 倍：每个玩家都要为其他所有人的迟到输入各回滚一次。

`drop_out` 的真实输出（4 人，3 号在第 200 帧后拔网线，超时阈值 30 帧）：

```
—— 不宣布掉线 ——                     —— 房主在第 235 帧宣布掉线 ——
确认帧 = 200/200/200/200             确认帧 = 480/480/480/200
其余三人一致 = true                   其余三人一致 = true
校验失配 = 0                          校验失配 = 0
回滚 = 15474，重放 115690             回滚 = 5298，重放 28816
```

不宣布，全房的确认帧就永远停在掉线前那一帧，剩下三个人一路重放却永远等不到那个输入；
宣布之后确认帧立刻补到当前帧，重放量掉到约四分之一。掉线者自己停在 200——他收到的
是一份不同的世界，这正是「掉线」的语义。

`bandwidth` 的真实输出（4 人全互联，600 帧，3 帧延迟 + 1 帧抖动 + 5% 丢包 + 10% 乱序）：

| 策略 | 发送字节 | 相对第一种 | 平均字节/包 | 平均携带帧数 |
| --- | --- | --- | --- | --- |
| 每帧一条 Input，固定 16 帧 | 761088 | 100% | 105 | 15 |
| 一条 InputSpan，固定 16 帧 | 268860 | 35% | 37 | 15 |
| InputSpan + 变化掩码 | 174696 | 22% | 24 | 15 |
| InputSpan + 掩码 + 对端水位 | 161007 | 21% | 22 | 9 |
| 以上 + 校验和每 8 帧 | 93099 | 12% | 12 | 9 |

五种策略的确认帧都是 600/600/600/600，一致 = yes，回滚与重放次数逐项相等
（8895 / 42082）——省下来的只有字节。105 字节/包压到 12 字节/包，同一局快了 **8 倍**。

延迟比冗余还差的时候（10 帧延迟 + 25% 丢包），前四种的区间都会被对端水位顶到 15~16 帧，
自适应策略自动退回保守值，确认帧照样追平到 600：**冗余可以配大，代价由链路自己决定**。

`resync` 的真实输出（2 人，400 帧，3 帧延迟 + 2 帧抖动 + 4% 丢包 + 8% 乱序，
1 号在第 100 帧把输入序列化错位）：

```
resync：分叉之后用完整状态把落后者掰回来

链路：延迟 3 帧 + 抖动 2 帧 + 丢包 4% + 乱序 8%
事故：1 号在第 100 帧本地执行 A、线上发 B（输入序列化错位）
      两端的输入流从此不同，靠回滚永远追不回来

P0 首次失配：确认帧 100 的状态哈希不同（共 11 次失配）
P0 请求第 100 帧的完整状态：发出 2 个 SnapRequest
P0 已恢复：restore 到第 100 帧（状态 8 字节），再用输入环重放

确认帧：P0 400 / P1 400；回滚 P0 400 / P1 400
重同步次数：P0 1；恢复后失配 0 次
恢复后：从恢复点到结束，两端在共同确认帧上逐帧哈希一致
注：恢复点之前的旧哈希留在落后者本地——重同步修的是未来，不改写历史。
```

11 次失配全在恢复之前：确认帧每前进一帧，落后端都会拿自己的哈希去比对一次，直到状态被替换。
`SnapRequest` 发了 2 个，说明请求或应答被链路吞掉了一个；重试间隔 6 帧，而恢复帧号不变，
所以重复请求是幂等的——这也是为什么恢复流程不需要额外的确认握手。

`two_peer` 的循环是手写的，可以当接入模板读：每帧打包「最近 8 帧输入 + 确认帧 +
校验和帧」，接收端解码后逐条投递。`desync_demo` 里那处故障注入用的是「本地执行 A、
发出去的是 B」——不能直接去改内存里的状态，回滚会从快照恢复并把它洗掉。

## 演示：两个物理世界互相同步

`adapters/phys` 把 `moonphys` 的 `World` 包成 `Sim`：`save` / `restore` 走
`World::save_state` / `World::load_state`（含位姿、速度、暖启动冲量与世界时钟），
`hash` 走 `state_hash`。`demo/` 里跑一局真实对局：两个独立物理世界、两个 `Session`、
两条带延迟 / 抖动 / 丢包 / 乱序的模拟链路，每帧互发最近 8 帧输入（这里刻意用最朴素的
逐帧 `Input`，好让 `docs/` 里的字节曲线和 `bandwidth` 示例的优化结果形成对照）。

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
| `weopqrst/moonroll/session` | `Sim` 协议 + 预测 / 确认 / 回滚重放 / 历史哈希 + 1..8 人会话 + 掉线语义 + 对端水位 + 分叉重同步 | V0.2 |
| `weopqrst/moonroll/protocol` | 输入帧、区间帧、确认帧、校验和帧、在线状态帧、全量状态帧的字节编解码 | V0.3 |
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
moon check --deny-warn     # 零警告
moon fmt --check           # 格式一致
moon test --target wasm-gc
moon test --target js
node tools/check-demo.mjs  # 1800 帧 wasm 自检
```

CI（`.github/workflows/ci.yml`）跑的就是这一串，外加七个示例的冒烟和
「提交的 `docs/engine.wasm` 必须与重新构建的产物逐字节一致」。

166 个测试，两个后端全绿。核心断言：

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
- **4 人局 200 帧、输入同帧送达：零回滚，四端逐帧历史哈希完全相同；**
- **4 人局里一名玩家恒定迟到 5 帧：其余三端反复回滚，补齐后 240 帧逐帧哈希仍相同；**
- **越界玩家索引、以及 N>2 时误用双人 `receive` 都被安全忽略；玩家数被钳制在 1..8；**
- **四人对局示例：同参数两次运行统计量逐项相等；4 人局重放帧数显著大于 2 人局。**
- **掉线：宣布之后确认帧从掉线前那一帧一路补到当前帧，其余玩家逐帧哈希仍然一致；**
- **重连把连续指针抬到当前确认帧，确认帧不回退，重连者补齐输入后继续前进；**
- **本地玩家不能被标成掉线，最后一名在线玩家不能被踢，越界索引返回 `false`；**
- **掉线示例：不宣布时确认帧停在 200，宣布后余下三人推到 480，重放量降到约四分之一。**
- **区间帧：16 帧重发从 16 条 `Input`（64 字节）压到 1 条 9 字节的 `InputSpan`，展开逐帧相等；**
- **掩码：同一段输入只发变化的值，全同的 4 帧只发 1 个值；首帧未置位、`count` 为 0/超 64、
  `start` 为 0、`player` 越界、掩码越出 `count`、值不足一律返回 `None`；**
- **带宽示例：五种策略喂同一局，回滚与重放次数逐项相等，字节数单调下降；
  25% 丢包 + 10 帧延迟下确认帧仍追平到 600；同参数两次运行字节数完全相同。**
- **重同步：两端分叉后用对端 `export_state` 整段替换，恢复点及之后逐帧哈希重新一致，
  继续推进 30 帧不再分叉；本地输入环与确认帧不回退。**
- **重同步拒绝未来帧、0 帧和超出快照窗口的帧，被拒绝时会话状态不变；同一帧号导出的
  字节与顺序重放到该帧的状态逐字节相同。**
- **状态帧：`Snap` 空状态合法、1000 帧号 + 64 字节状态往返一致；`SnapAsk` 往返一致；
  帧号 0、长度超 64 KiB、声明长度超出实际字节、请求帧号 0 一律 `None`。**
- **resync 示例：无丢包时一次往返修好（失配帧 = 事故帧 = 恢复点）；4% 丢包下靠重试
  收敛；干净局与事故帧在收尾之后的局重同步次数都是 0。**

## Roadmap

- **V0.1** 基础层：定点数、状态哈希、输入环（已完成）
- **V0.2** 回滚会话：预测、确认、快照/恢复、重放（已完成）
- **V0.3** 字节协议 + 延迟/抖动/丢包/乱序模拟 + fuzz（已完成）
- **V0.4** 接入 `moonphys` 的 wasm-gc 可视化演示（双世界对照、回滚计数、延迟滑块）（已完成）
- **V0.5** 三个可运行示例 + 零警告 CI（`--deny-warn`、`fmt --check`、demo 产物校验）+ 架构文档（已完成）
- **V0.6** 1..8 人同局：每玩家一条输入环、`step_players` 接入、协议带玩家索引、四人对局示例（已完成）
- **V0.7** 掉线语义：在线集合、确认帧只等在线玩家、重连不回退、协议 `Active` 帧、掉线示例（已完成）
- **V0.8** 带宽：`InputSpan` 区间帧 + 变化掩码、对端水位自适应重发、校验和降频、带宽示例（已完成）
- **V0.9** 分叉恢复：`export_state` / `resync_from`、`Snap` / `SnapAsk` 帧、重同步示例（当前）
- **V1.0** GitHub Pages 在线演示、验收脚本、mooncakes 发布

## 明确不做

- 真 UDP/TCP 联机（`moonbitlang/async` 的 socket 不支持 `wasm-gc`，浏览器内不可用）
- 服务端权威模式、房间匹配
- 具体引擎绑定（只提供 `Sim` 接口，接入成本目标 30 行）

## License

Apache-2.0
