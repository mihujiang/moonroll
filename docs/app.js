// Browser shell around docs/engine.wasm (built from moonroll/demo by tools/build-demo.ps1).
// The wasm module is plain wasm-gc with no imports: every value crosses the
// boundary as an i32 or f64, so this file only wires DOM to the mr_* exports.
(() => {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const overlay = $("overlay");
  const canvases = [$("canvas0"), $("canvas1")];
  const contexts = canvases.map((c) => c.getContext("2d"));

  const LEFT = 0b001;
  const RIGHT = 0b010;
  const JUMP = 0b100;
  const FPS = 60;
  const DT = 1 / FPS;

  let engine = null;
  let paused = false;
  let accumulator = 0;
  let lastTime = 0;
  let fpsFrames = 0;
  let fpsClock = 0;
  let fpsValue = 0;
  const manual = [false, false];
  const keys = new Set();

  const sliders = {
    delay: { el: $("delay"), out: $("delayOut"), format: (v) => `${v} 帧 · ${Math.round((v / FPS) * 1000)} ms` },
    jitter: { el: $("jitter"), out: $("jitterOut"), format: (v) => `${v} 帧 · ${Math.round((v / FPS) * 1000)} ms` },
    loss: { el: $("loss"), out: $("lossOut"), format: (v) => `${v} %` },
    reorder: { el: $("reorder"), out: $("reorderOut"), format: (v) => `${v} %` },
  };

  const u32 = (v) => (v >>> 0).toString(16).padStart(8, "0");
  const hashOf = (player) => u32(engine.mr_hash_hi(player)) + u32(engine.mr_hash_lo(player));

  function syncSliderLabels() {
    for (const key of Object.keys(sliders)) {
      const s = sliders[key];
      s.out.textContent = s.format(Number(s.el.value));
    }
  }

  function reset() {
    if (!engine) return;
    engine.mr_reset(
      Number(sliders.delay.el.value),
      Number(sliders.jitter.el.value),
      Number(sliders.loss.el.value),
      Number(sliders.reorder.el.value),
    );
    accumulator = 0;
    manual[0] = false;
    manual[1] = false;
  }

  // Scripted stand-in so the arena never freezes when nobody is typing.
  function autoBits(slot, frame) {
    const t = (frame * (slot === 0 ? 1 : 1.37)) % 200;
    let bits = 0;
    if (t < 72) bits |= RIGHT;
    else if (t < 148) bits |= LEFT;
    if (t > 156 && t < 163) bits |= JUMP;
    return bits;
  }

  function manualBits(slot) {
    let bits = 0;
    if (slot === 0) {
      if (keys.has("KeyA")) bits |= LEFT;
      if (keys.has("KeyD")) bits |= RIGHT;
      if (keys.has("KeyW")) bits |= JUMP;
    } else {
      if (keys.has("ArrowLeft")) bits |= LEFT;
      if (keys.has("ArrowRight")) bits |= RIGHT;
      if (keys.has("ArrowUp")) bits |= JUMP;
    }
    return bits;
  }

  function inputBits(slot, frame) {
    const bits = manualBits(slot);
    if (bits !== 0) {
      manual[slot] = true;
      return bits;
    }
    if (manual[slot]) return 0;
    return autoBits(slot, frame);
  }

  function tick() {
    const frame = engine.mr_frame();
    engine.mr_step(inputBits(0, frame), inputBits(1, frame));
  }

  const VIEW = { minX: -7, maxX: 7, minY: -1.5, maxY: 6.5 };

  function fitCanvas(canvas, ctx) {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const rect = canvas.getBoundingClientRect();
    const w = Math.max(1, Math.round(rect.width * dpr));
    const h = Math.max(1, Math.round(rect.height * dpr));
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w;
      canvas.height = h;
    }
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, w, h);
    return { w, h };
  }

  function makeProjector(w, h) {
    const spanX = VIEW.maxX - VIEW.minX;
    const spanY = VIEW.maxY - VIEW.minY;
    const scale = Math.min(w / spanX, h / spanY) * 0.92;
    const midX = (VIEW.minX + VIEW.maxX) / 2;
    const midY = (VIEW.minY + VIEW.maxY) / 2;
    return {
      scale,
      x: (wx) => w / 2 + (wx - midX) * scale,
      y: (wy) => h / 2 - (wy - midY) * scale,
    };
  }

  function drawGrid(ctx, w, h, proj) {
    ctx.save();
    ctx.strokeStyle = "rgba(148, 163, 184, 0.07)";
    ctx.lineWidth = 1;
    for (let gx = -12; gx <= 12; gx++) {
      const px = proj.x(gx);
      if (px < 0 || px > w) continue;
      ctx.beginPath();
      ctx.moveTo(px, 0);
      ctx.lineTo(px, h);
      ctx.stroke();
    }
    for (let gy = -2; gy <= 8; gy++) {
      const py = proj.y(gy);
      if (py < 0 || py > h) continue;
      ctx.beginPath();
      ctx.moveTo(0, py);
      ctx.lineTo(w, py);
      ctx.stroke();
    }
    ctx.restore();
  }

  function drawFloor(ctx, w, h, proj) {
    const y0 = proj.y(0);
    const y1 = proj.y(VIEW.minY);
    const grad = ctx.createLinearGradient(0, y0, 0, y1);
    grad.addColorStop(0, "rgba(148, 163, 184, 0.26)");
    grad.addColorStop(1, "rgba(148, 163, 184, 0.05)");
    ctx.fillStyle = grad;
    ctx.fillRect(0, y0, w, y1 - y0);
    ctx.strokeStyle = "rgba(226, 232, 240, 0.4)";
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.moveTo(0, y0);
    ctx.lineTo(w, y0);
    ctx.stroke();
  }

  function drawBox(ctx, proj, x, y, rotation, half, color, ghost) {
    const s = half * 2 * proj.scale;
    ctx.save();
    ctx.translate(proj.x(x), proj.y(y));
    ctx.rotate(-rotation);
    const r = Math.min(s * 0.22, 9);
    const e = s / 2;
    ctx.beginPath();
    ctx.moveTo(-e + r, -e);
    ctx.arcTo(e, -e, e, e, r);
    ctx.arcTo(e, e, -e, e, r);
    ctx.arcTo(-e, e, -e, -e, r);
    ctx.arcTo(-e, -e, e, -e, r);
    ctx.closePath();
    if (ghost) {
      ctx.setLineDash([4, 4]);
      ctx.lineWidth = 1.2;
      ctx.strokeStyle = color;
      ctx.globalAlpha = 0.6;
      ctx.stroke();
    } else {
      const grad = ctx.createLinearGradient(-e, -e, e, e);
      grad.addColorStop(0, color);
      grad.addColorStop(1, "rgba(15, 23, 42, 0.92)");
      ctx.globalAlpha = 0.94;
      ctx.fillStyle = grad;
      ctx.fill();
      ctx.globalAlpha = 1;
      ctx.lineWidth = 1.4;
      ctx.strokeStyle = "rgba(255, 255, 255, 0.7)";
      ctx.stroke();
    }
    ctx.restore();
  }

  // Body 1 is player 0's box, body 2 is player 1's (body 0 is the floor).
  const BODY_COLORS = ["#64748b", "#38bdf8", "#f472b6"];

  function drawWorld(slot) {
    const ctx = contexts[slot];
    const { w, h } = fitCanvas(canvases[slot], ctx);
    const proj = makeProjector(w, h);
    drawGrid(ctx, w, h, proj);
    drawFloor(ctx, w, h, proj);

    const other = 1 - slot;
    const count = engine.mr_body_count(slot);
    const otherCount = engine.mr_body_count(other);
    for (let i = 0; i < count; i++) {
      if (engine.mr_body_is_static(slot, i) === 1) continue;
      if (i < otherCount && engine.mr_body_is_static(other, i) !== 1) {
        drawBox(ctx, proj,
          engine.mr_body_x(other, i), engine.mr_body_y(other, i),
          engine.mr_body_rotation(other, i), 0.45, BODY_COLORS[i], true);
      }
      drawBox(ctx, proj,
        engine.mr_body_x(slot, i), engine.mr_body_y(slot, i),
        engine.mr_body_rotation(slot, i), 0.45, BODY_COLORS[i], false);
    }
  }

  function renderHud() {
    const frame = engine.mr_frame();
    const desyncs = engine.mr_desync();
    $("p0frame").textContent = frame;
    $("p1frame").textContent = frame;
    $("p0confirmed").textContent = engine.mr_confirmed(0);
    $("p1confirmed").textContent = engine.mr_confirmed(1);
    $("p0rollbacks").textContent = engine.mr_rollbacks(0);
    $("p1rollbacks").textContent = engine.mr_rollbacks(1);
    $("p0hash").textContent = hashOf(0);
    $("p1hash").textContent = hashOf(1);
    $("hudFrame").textContent = frame;
    $("hudInFlight").textContent = engine.mr_in_flight();
    $("hudDropped").textContent = engine.mr_dropped();
    $("hudDesync").textContent = desyncs;
    $("hudFps").textContent = fpsValue;

    const badge = $("badge");
    const badgeText = $("badgeText");
    if (desyncs > 0) {
      badge.className = "badge desync";
      badgeText.textContent = `分叉 ${desyncs}`;
    } else if (engine.mr_synced() === 1) {
      badge.className = "badge synced";
      badgeText.textContent = "两侧世界一致";
    } else {
      badge.className = "badge";
      badgeText.textContent = "预测中";
    }
  }

  function frameLoop(now) {
    if (!engine) return;
    if (!lastTime) lastTime = now;
    const delta = Math.min((now - lastTime) / 1000, 0.25);
    lastTime = now;

    if (!paused) {
      accumulator += delta;
      let steps = 0;
      while (accumulator >= DT && steps < 8) {
        tick();
        accumulator -= DT;
        steps++;
      }
      if (steps === 8) accumulator = 0;
    }

    fpsFrames++;
    fpsClock += delta;
    if (fpsClock >= 0.5) {
      fpsValue = Math.round(fpsFrames / fpsClock);
      fpsFrames = 0;
      fpsClock = 0;
    }

    drawWorld(0);
    drawWorld(1);
    renderHud();
    requestAnimationFrame(frameLoop);
  }

  function setPaused(value) {
    paused = value;
    $("pause").textContent = paused ? "继续" : "暂停";
  }

  function bindUi() {
    syncSliderLabels();
    for (const key of Object.keys(sliders)) {
      sliders[key].el.addEventListener("input", () => {
        syncSliderLabels();
        reset();
      });
    }

    $("pause").addEventListener("click", () => setPaused(!paused));

    $("stepBtn").addEventListener("click", () => {
      setPaused(true);
      tick();
    });

    $("resetBtn").addEventListener("click", () => {
      reset();
      setPaused(false);
      $("selftestOut").textContent = "自检：1800 帧脚本对局";
    });

    $("selftestBtn").addEventListener("click", () => {
      const button = $("selftestBtn");
      const out = $("selftestOut");
      button.disabled = true;
      out.textContent = "自检运行中…（1800 帧，含 200 ms 延迟）";
      // Yield one frame so the label paints before the wasm call blocks.
      setTimeout(() => {
        const code = engine.mr_selftest();
        out.innerHTML = code === 0
          ? '自检 <b class="pass">通过</b>：两侧确认到第 1800 帧且 hash 一致'
          : '自检 <b class="fail">失败</b>：两侧未收敛';
        reset();
        button.disabled = false;
      }, 40);
    });

    window.addEventListener("keydown", (event) => {
      if (event.code === "Space") {
        event.preventDefault();
        setPaused(!paused);
        return;
      }
      if (event.code === "KeyR") {
        reset();
        return;
      }
      keys.add(event.code);
      if (event.code.startsWith("Arrow")) event.preventDefault();
    });
    window.addEventListener("keyup", (event) => keys.delete(event.code));
    window.addEventListener("blur", () => keys.clear());
  }

  async function boot() {
    overlay.classList.add("show");
    try {
      if (location.protocol === "file:") {
        throw new Error("需要通过 HTTP 服务器打开：在仓库根目录运行 python -m http.server");
      }
      const response = await fetch("./engine.wasm");
      if (!response.ok) throw new Error(`engine.wasm 加载失败（HTTP ${response.status}）`);
      let instance;
      try {
        ({ instance } = await WebAssembly.instantiateStreaming(response, {}));
      } catch (error) {
        const buffer = await (await fetch("./engine.wasm")).arrayBuffer();
        ({ instance } = await WebAssembly.instantiate(buffer, {}));
      }
      engine = instance.exports;
      bindUi();
      reset();
      overlay.classList.remove("show");
      requestAnimationFrame(frameLoop);
    } catch (error) {
      overlay.classList.add("error", "show");
      overlay.textContent = `启动失败：${error.message}\n\n提示：wasm 需要 HTTP 环境（file:// 不可用）。`;
    }
  }

  boot();
})();
