///|
/// moonroll —— 确定性回滚同步（sans-IO），纯 MoonBit 实现。
///
/// 基础层：
/// - `weopqrst/moonroll/fixed`：Q16.16 定点数，整数运算、跨后端逐位一致
/// - `weopqrst/moonroll/digest`：FNV-1a 64 状态哈希，用于检测 desync
/// - `weopqrst/moonroll/input`：帧号 -> 输入位图的环形缓冲
///
/// 回滚层（V0.2）：
/// - `weopqrst/moonroll/session`：`Sim` 接入协议 + `Session` 预测/确认/重放
///
/// 字节协议与网络模拟见 Roadmap V0.3。
pub using @fixed {type Fixed}

///|
pub using @digest {type Digest}

///|
pub using @input {type InputRing}

///|
pub using @session {trait Sim, type Session, type SnapshotRing}

///|
pub fn version() -> String {
  "0.2.0"
}
