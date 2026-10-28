# moonroll

> Sans-IO deterministic rollback netcode for MoonBit.

MoonBit 生态里 ECS、物理、寻路、渲染、行为树都已经有人做，但"把两个玩家连起来还不漂移"这一层是空白。
`moonroll` 补的就是这一层：不绑定任何引擎的确定性回滚同步（rollback netcode）。

**状态：V0.1（基础层）**。已实现 Q16.16 定点数、FNV-1a 状态哈希、输入环形缓冲；
回滚会话（预测 / 确认 / 重模拟）在 V0.2。

---

## 为什么需要定点数

回滚同步的前提是：**同一串输入，在任何后端、任何 CPU 上必须产生逐位相同的轨迹**。

浮点不是不能用：本项目实测 `js` 与 `wasm-gc` 后端对同一份代码输出**完全相同的位模式**
（12 个采样 + 1000 / 10000 步非线性迭代，见下表）。但 native 与跨平台仍会受编译器优化、
FMA 收缩、超越函数实现差异影响，所以提供一条纯整数的路径：

- 加减乘除、开方、插值全部是整数运算，语义由 MoonBit 的 `Int64` 保证；
- 不依赖任何浮点库，也就不存在"换个编译器结果就变"的问题。

## 实测：跨后端浮点一致性

| 后端 | 结果 |
| --- | --- |
| `js` | 输出位模式 |
| `wasm-gc` | 与 `js` 逐位完全相同 |
| `native` | 待验证（需要本机 C 编译器；CI 上用 ubuntu + gcc 覆盖） |

结论：wasm 端可以直接用 `Double`；要跨平台保险，用 `@fixed.Fixed`。

## 快速开始

```bash
moon add weopqrst/moonroll
```

```moonbit nocheck
// Q16.16 定点数：整数运算，跨后端一致
let a = @fixed.Fixed::from_double(1.5)
let b = @fixed.Fixed::from_double(2.25)
let c = a * b
let s = @fixed.Fixed::from_int(2).sqrt()

// 状态哈希：两侧每 N 帧比对一次，不一致即 desync
let d = @digest.Digest::new()
d.feed_bytes(b"state")
let checksum = d.finish()

// 输入环：按帧号随机存取，容量固定
let ring = @input.InputRing::new(64)
ring.set(frame, 0b101UL)
```

## 包结构

| 包 | 内容 | 状态 |
| --- | --- | --- |
| `weopqrst/moonroll/fixed` | Q16.16 定点数（`+ - * /`、开方、lerp、clamp） | V0.1 |
| `weopqrst/moonroll/digest` | FNV-1a 64 状态哈希 | V0.1 |
| `weopqrst/moonroll/input` | 帧号 -> 输入位图的环形缓冲 | V0.1 |
| `weopqrst/moonroll/session` | 预测 / 确认 / 回滚重模拟 | V0.2 |
| `weopqrst/moonroll/protocol` | 输入帧、确认帧、校验和帧的字节编解码 | V0.3 |
| `weopqrst/moonroll/sim_net` | 延迟 / 抖动 / 丢包 / 乱序模拟器 | V0.3 |

## 验证

```bash
moon test --target wasm-gc
moon test --target js
moon run cmd/main --target wasm-gc
```

当前 19 个测试，两个后端全绿。核心断言：

- 定点数与 `Double` 对拍误差不超过 4 个 LSB；
- FNV-1a 64 对 `"hello"` 命中标准向量 `0xa430d84680aabd0b`；
- 输入环回绕后只保留窗口内帧，旧帧不会误命中。

## Roadmap

- **V0.1** 基础层：定点数、状态哈希、输入环（当前）
- **V0.2** 回滚会话：预测、确认、快照/恢复、重放；双对等体 3000 帧终态哈希一致
- **V0.3** 字节协议 + 延迟/抖动/丢包/乱序模拟 + fuzz
- **V0.4** 接入 `moonphys` 的 wasm-gc 可视化演示（帧时间线、回滚计数、延迟滑块）
- **V1.0** CI 三后端一致性、文档、mooncakes 发布

## 明确不做

- 真 UDP/TCP 联机（`moonbitlang/async` 的 socket 不支持 `wasm-gc`，浏览器内不可用）
- 服务端权威模式、房间匹配
- 具体引擎绑定（只提供 `Sim` 接口，接入成本目标 30 行）

## License

Apache-2.0
