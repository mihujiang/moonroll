///|
/// 链路参数。时间单位是「帧」（逻辑 tick），60fps 下 1 帧约 16.7ms。
pub(all) struct Link {
  delay : Int
  jitter : Int
  loss_pct : Int
  reorder_pct : Int
  seed : UInt64
}

///|
pub fn Link::new(
  delay : Int,
  jitter : Int,
  loss_pct : Int,
  reorder_pct : Int,
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
  }
}

///|
struct Packet {
  arrive_at : Int
  payload : Bytes
}

///|
/// 确定性链路：同 seed、同发送序列 -> 同到达序列。
pub struct NetSim {
  link : Link
  mut seed : UInt64
  mut queue : Array[Packet]
  mut delivered : Int
  mut dropped : Int
}

///|
pub fn NetSim::new(link : Link) -> NetSim {
  { link, seed: link.seed, queue: [], delivered: 0, dropped: 0 }
}

///|
fn NetSim::rand(self : NetSim) -> Int {
  self.seed = self.seed * 6364136223846793005UL + 1442695040888963407UL
  ((self.seed >> 33) & 0x7FFFFFFFUL).to_int()
}

///|
/// 在 `now` 时刻发出一个包。可能被丢弃，否则按 delay + jitter 到达。
pub fn NetSim::send(self : NetSim, now : Int, payload : Bytes) -> Unit {
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
  self.queue.push({ arrive_at: now + d, payload })
}

///|
/// 取出 `now` 时刻已到达的包，按到达时间升序返回（模拟乱序）。
pub fn NetSim::recv(self : NetSim, now : Int) -> Array[Bytes] {
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
pub fn NetSim::delivered(self : NetSim) -> Int {
  self.delivered
}

///|
pub fn NetSim::dropped(self : NetSim) -> Int {
  self.dropped
}

///|
pub fn NetSim::in_flight(self : NetSim) -> Int {
  self.queue.length()
}
