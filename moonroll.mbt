///|
/// moonroll —— 确定性回滚同步（sans-IO），纯 MoonBit 实现。
///
/// 三个基础包：
/// - `weopqrst/moonroll/fixed`：Q16.16 定点数，整数运算、跨后端逐位一致
/// - `weopqrst/moonroll/digest`：FNV-1a 64 状态哈希，用于检测 desync
/// - `weopqrst/moonroll/input`：帧号 -> 输入位图的环形缓冲
///
/// 上层 `session`（预测 / 确认 / 回滚重模拟）见 Roadmap V0.2。
pub using @fixed {type Fixed}

///|
pub using @digest {type Digest}

///|
pub using @input {type InputRing}

///|
pub fn version() -> String {
  "0.1.0"
}
