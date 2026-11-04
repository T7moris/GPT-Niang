// Rolling animation callback timings. These measure scheduling, not display scanout.
export class FrameStats {
  constructor() {
    this.samples = [];
    this.last = null;
    this.started = 0;
  }
  sample(now, active) {
    if (!active) {
      this.last = null;
      return;
    }
    if (this.last === null) this.started = now;
    else if (now - this.started > 1000)
      this.samples.push({ at: now, gap: now - this.last });
    this.last = now;
    while (this.samples[0]?.at < now - 10000) this.samples.shift();
  }
  read() {
    const gaps = this.samples.map((s) => s.gap).sort((a, b) => a - b),
      n = gaps.length;
    if (!n) return { samples: 0 };
    const mean = gaps.reduce((a, b) => a + b, 0) / n,
      round = (v) => Math.round(v * 100) / 100;
    return {
      samples: n,
      fps: round(1000 / mean),
      medianMs: round(gaps[Math.floor((n - 1) * 0.5)]),
      p95Ms: round(gaps[Math.floor((n - 1) * 0.95)]),
      maxMs: round(gaps.at(-1)),
      over50ms: gaps.filter((v) => v > 50).length,
    };
  }
}
