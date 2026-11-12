///|
/// 链路参数。时间单位是「帧」（逻辑 tick），60fps 下 1 帧约 16.7ms。
pub(all) struct Link {
  delay : Int32
  jitter : Int32
  loss_pct : Int32
  reorder_pct : Int32
  seed : UInt64
  /// 每帧允许通过的最大字节数，0 表示不限。
  /// 超出预算的包直接丢弃并计入 `throttled`，模拟上行带宽被占满。
  bandwidth : Int32
}

///|
pub fn Link::new(
  delay : Int32,
  jitter : Int32,
  loss_pct : Int32,
  reorder_pct : Int32,
  seed : UInt64,
) -> Link {
  {
    delay: if delay < 0 {
      0
    } else {
      delay
    },
    jitter: if jitter < 0 {
      0
    } else {
      jitter
    },
    loss_pct: if loss_pct < 0 {
      0
    } else if loss_pct > 100 {
      100
    } else {
      loss_pct
    },
    reorder_pct: if reorder_pct < 0 {
      0
    } else if reorder_pct > 100 {
      100
    } else {
      reorder_pct
    },
    seed,
    bandwidth: 0,
  }
}

///|
/// 带带宽上限的构造：每帧最多通过 `bandwidth` 字节，0 表示不限。
pub fn Link::with_bandwidth(
  delay : Int32,
  jitter : Int32,
  loss_pct : Int32,
  reorder_pct : Int32,
  seed : UInt64,
  bandwidth : Int32,
) -> Link {
  let link = Link::new(delay, jitter, loss_pct, reorder_pct, seed)
  { ..link, bandwidth: if bandwidth < 0 { 0 } else { bandwidth }, }
}

///|
struct Packet {
  arrive_at : Int32
  payload : Bytes
}

///|
/// 确定性链路：同 seed、同发送序列 -> 同到达序列。
pub struct NetSim {
  link : Link
  mut seed : UInt64
  mut queue : Array[Packet]
  mut delivered : Int32
  mut dropped : Int32
  mut throttled : Int32
  mut budget_frame : Int32
  mut budget_left : Int32
}

///|
pub fn NetSim::new(link : Link) -> NetSim {
  {
    link,
    seed: link.seed,
    queue: [],
    delivered: 0,
    dropped: 0,
    throttled: 0,
    budget_frame: -2147483648,
    budget_left: 0,
  }
}

///|
fn NetSim::rand(self : NetSim) -> Int32 {
  self.seed = self.seed * 6364136223846793005UL + 1442695040888963407UL
  ((self.seed >> 33) & 0x7FFFFFFFUL).to_int()
}

///|
/// 在 `now` 时刻发出一个包。可能被丢弃，否则按 delay + jitter 到达。
pub fn NetSim::send(self : NetSim, now : Int32, payload : Bytes) -> Unit {
  // 随机判定（丢包 / 抖动 / 乱序）放在带宽之前：带宽只决定「已经上线的包装不装得下」，
  // 不改变这条链路的随机流，所以给链路加预算不会打乱既有的丢包与到达顺序。
  if self.link.loss_pct > 0 && self.rand() % 100 < self.link.loss_pct {
    self.dropped = self.dropped + 1
    return
  }
  let mut d = self.link.delay
  if self.link.jitter > 0 {
    d = d + self.rand() % (self.link.jitter + 1)
  }
  if self.link.reorder_pct > 0 && self.rand() % 100 < self.link.reorder_pct {
    d = d + 1
  }
  // 带宽预算按「发送时刻」重置：同一帧内的多个包共用一份预算。
  if self.link.bandwidth > 0 {
    if now != self.budget_frame {
      self.budget_frame = now
      self.budget_left = self.link.bandwidth
    }
    let n = payload.length()
    if n > self.budget_left {
      self.throttled = self.throttled + 1
      return
    }
    self.budget_left = self.budget_left - n
  }
  self.queue.push({ arrive_at: now + d, payload, })
}

///|
/// 取出 `now` 时刻已到达的包，按到达时间升序返回（模拟乱序）。
pub fn NetSim::recv(self : NetSim, now : Int32) -> Array[Bytes] {
  let ready : Array[Packet] = []
  let later : Array[Packet] = []
  for p in self.queue {
    if p.arrive_at <= now {
      ready.push(p)
    } else {
      later.push(p)
    }
  }
  self.queue = later
  // 插入排序：同时到达或轻微乱序的包按真实到达顺序交付
  let mut i = 1
  while i < ready.length() {
    let cur = ready[i]
    let mut j = i - 1
    while j >= 0 && ready[j].arrive_at > cur.arrive_at {
      ready[j + 1] = ready[j]
      j = j - 1
    }
    ready[j + 1] = cur
    i = i + 1
  }
  let out : Array[Bytes] = []
  for p in ready {
    out.push(p.payload)
    self.delivered = self.delivered + 1
  }
  out
}

///|
pub fn NetSim::delivered(self : NetSim) -> Int32 {
  self.delivered
}

///|
pub fn NetSim::dropped(self : NetSim) -> Int32 {
  self.dropped
}

///|
/// 因超出每帧字节预算而被丢弃的包数。
pub fn NetSim::throttled(self : NetSim) -> Int32 {
  self.throttled
}

///|
pub fn NetSim::in_flight(self : NetSim) -> Int32 {
  self.queue.length()
}
