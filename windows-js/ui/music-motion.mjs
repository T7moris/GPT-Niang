export const clamp = (x, l, h) => Math.max(l, Math.min(h, x));
// .NET's default Math.Round is ties-to-even. Phase correction must use the same rule.
const round = (x) => {
  const f = Math.floor(x),
    r = x - f;
  return r === 0.5 ? (f % 2 === 0 ? f : f + 1) : Math.round(x);
};
export class MusicMotion {
  constructor(x, y, width, floor, figure, dpi) {
    Object.assign(this, {
      X: x,
      Y: y,
      Width: width,
      Floor: floor,
      FigureWidth: figure,
      FigureHeight: figure,
      Dpi: dpi,
      Vx: 0,
      Vy: 0,
      Time: 0,
      Bend: 0,
      BendSpeed: 0,
      Rock: 0,
      RockSpeed: 0,
      Lamp: 0,
      LampSpeed: 0,
      Pulse: 0,
      Energy: 0,
      Cycle: 0,
      Impacts: 0,
      Phase: 0,
      Props: 0,
      Direction: -1,
      ThrowX: 0,
      ThrowY: 0,
      ReleaseIdleMs: 0,
      Held: false,
      landed: 0,
      lockStartPose: 0,
      lastPointerX: 0,
      lastPointerY: 0,
      flightCeiling: 0,
      pointerIdle: 0,
      wasLocked: false,
      hasPointer: false,
      throwMomentum: false,
    });
  }
  spring(key, speed, target, dt, frequency, damping) {
    for (let remaining = dt; remaining > 0;) {
      const s = Math.min(remaining, 1 / 240);
      this[speed] +=
        ((target - this[key]) * frequency * frequency -
          2 * damping * frequency * this[speed]) *
        s;
      this[key] += this[speed] * s;
      remaining -= s;
    }
  }
  beginHold(x, y) {
    Object.assign(this, {
      Held: true,
      wasLocked: false,
      Energy: 0,
      BendSpeed: 4,
      Vy: 0,
      Props: 0,
      ThrowX: 0,
      ThrowY: 0,
      pointerIdle: 0,
      ReleaseIdleMs: 0,
      hasPointer: x !== undefined,
      throwMomentum: false,
      lastPointerX: x,
      lastPointerY: y,
    });
  }
  samplePointer(x, y, dt) {
    if (dt <= 0) return;
    if (this.hasPointer) {
      const dx = x - this.lastPointerX,
        dy = y - this.lastPointerY;
      if (Math.abs(dx) + Math.abs(dy) > 0.1 * this.Dpi) {
        this.pointerIdle = 0;
        const vx = dx / dt,
          vy = dy / dt,
          length = Math.hypot(vx, vy),
          limit = Math.min(1, (2000 * this.Dpi) / Math.max(1, length)),
          blend = 1 - Math.exp(-dt / 0.025);
        this.ThrowX += (vx * limit - this.ThrowX) * blend;
        this.ThrowY += (vy * limit - this.ThrowY) * blend;
      } else {
        const old = this.pointerIdle;
        this.pointerIdle += dt;
        const decay = Math.exp(
          -(Math.max(0, this.pointerIdle - 0.08) - Math.max(0, old - 0.08)) /
            0.025,
        );
        this.ThrowX *= decay;
        this.ThrowY *= decay;
      }
    }
    this.lastPointerX = x;
    this.lastPointerY = y;
    this.hasPointer = true;
  }
  moveHeld(x, y, dt, px = x, py = y) {
    this.samplePointer(px, py, dt);
    const margin = this.flightMargin;
    this.X = clamp(x, margin, Math.max(margin, this.Width - margin));
    const target = clamp(y, 16 * this.Dpi, this.Floor);
    this.spring("Y", "Vy", target, dt, 22, 0.72);
    if (this.Y > this.Floor) {
      this.Y = this.Floor;
      this.Vy = Math.min(0, this.Vy);
    }
  }
  release() {
    if (!this.Held) return;
    Object.assign(this, {
      Held: false,
      Phase: 0,
      Impacts: 0,
      Props: 0,
      Vx: this.ThrowX,
      Vy: this.ThrowY,
      ReleaseIdleMs: this.pointerIdle * 1000,
    });
    this.throwMomentum = Math.abs(this.Vx) > 120 * this.Dpi;
    this.flightCeiling = Math.min(
      this.Y,
      this.Floor,
      this.FigureHeight * 1.22 + 16 * this.Dpi,
    );
    if (Math.abs(this.Vx) + Math.abs(this.Vy) < 60 * this.Dpi)
      this.Vy = -90 * this.Dpi;
    if (Math.abs(this.Vx) > 5 * this.Dpi) this.Direction = this.Vx > 0 ? 1 : -1;
  }
  resize(width, floor, figure, dpi) {
    if (this.FigureWidth > 0) this.FigureHeight *= figure / this.FigureWidth;
    if (this.Width > 0) this.X = (this.X / this.Width) * width;
    this.Y += floor - this.Floor;
    Object.assign(this, {
      Width: width,
      Floor: floor,
      FigureWidth: figure,
      Dpi: dpi,
    });
    if (this.Phase > 0 && !this.Held) this.Y = this.Floor;
    const m = this.margin;
    this.X = clamp(this.X, m, Math.max(m, this.Width - m));
  }
  get margin() {
    return Math.min(this.Width / 2, 24 * this.Dpi + this.FigureWidth * 0.86);
  }
  get flightMargin() {
    return Math.min(this.Width / 2, 4 * this.Dpi + this.FigureWidth * 0.52);
  }
  moveAir(dt, drag) {
    this.X += this.Vx * dt;
    this.Vx *= Math.exp(-dt * drag);
    const m = this.flightMargin;
    if (this.X < m) {
      this.X = m;
      if (this.Vx < 0) this.Vx = -this.Vx * 0.62;
      this.Direction = 1;
    }
    if (this.X > this.Width - m) {
      this.X = this.Width - m;
      if (this.Vx > 0) this.Vx = -this.Vx * 0.62;
      this.Direction = -1;
    }
  }
  static beatPose(phase) {
    phase -= Math.floor(phase);
    if (phase < 0.32) return 0.12 + 0.28 * Math.cos((Math.PI * phase) / 0.32);
    if (phase < 0.66)
      return -0.08 * (1 + Math.cos((Math.PI * (phase - 0.32)) / 0.34));
    if (phase < 0.78) return 0;
    return 0.2 * (1 - Math.cos((Math.PI * (phase - 0.78)) / 0.22));
  }
  step(dt, paused, locked, phase, period, strength, clockElapsed = dt) {
    dt = clamp(dt, 0, 0.12);
    if (dt <= 0) return;
    clockElapsed = Math.max(0, clockElapsed);
    if (paused) {
      this.spring("Bend", "BendSpeed", 0, dt, 20, 0.8);
      this.spring("Rock", "RockSpeed", 0, dt, 14, 0.8);
      this.spring("Lamp", "LampSpeed", 0, dt, 7, 0.8);
      if (this.Phase >= 2) this.Vx *= Math.exp(-dt * 12);
      this.Pulse *= Math.exp(-dt * 10);
      this.Energy = 0;
      this.wasLocked = false;
      return;
    }
    this.Time += dt;
    if (this.Held) {
      this.spring("Bend", "BendSpeed", -0.045, dt, 20, 0.42);
      this.Pulse = 0;
      return;
    }
    if (this.Phase === 0) {
      for (let remaining = dt; remaining > 0 && this.Phase === 0;) {
        const s = Math.min(remaining, 1 / 240);
        this.moveAir(s, 0.3);
        this.Vy += 1180 * this.Dpi * s;
        this.Y += this.Vy * s;
        let ceiling = Math.min(
          this.Floor,
          this.FigureHeight * 1.22 + 16 * this.Dpi,
        );
        if (this.flightCeiling > 0)
          ceiling = Math.min(ceiling, this.flightCeiling);
        if (this.Y < ceiling && this.Vy < 0) {
          this.Y = ceiling;
          this.Vy = -this.Vy * 0.42;
        }
        if (this.Y >= this.Floor && this.Vy > 0) {
          this.Y = this.Floor;
          this.Impacts++;
          this.Bend = Math.min(0.3, this.Vy / (2500 * this.Dpi));
          this.BendSpeed = 0;
          this.Vx *= this.throwMomentum ? 0.94 : 0.68;
          if (this.Impacts <= 2) this.Vy = -this.Vy * 0.52;
          else {
            this.Vy = 0;
            this.Phase = 1;
            this.landed = this.Time;
          }
        }
        remaining -= s;
      }
      this.spring("Bend", "BendSpeed", 0, dt, 20, 0.67);
      return;
    }
    this.Y = this.Floor;
    this.Vy = 0;
    if (this.Phase === 1) {
      this.Props = Math.min(1, (this.Time - this.landed) / 0.25);
      this.moveAir(dt, this.throwMomentum ? 0.75 : 10);
      this.spring("Bend", "BendSpeed", 0, dt, 20, 0.67);
      if (this.Props >= 1) this.Phase = 2;
      return;
    }
    const old = this.Bend;
    locked = locked && period >= 0.28 && period <= 1;
    if (locked) {
      if (!this.wasLocked) {
        this.Cycle = phase;
        this.lockStartPose = this.Bend;
        this.Energy = 0;
      } else {
        const predicted = this.Cycle + clockElapsed / period;
        let error = phase - predicted;
        error -= round(error);
        this.Cycle =
          predicted + clamp(error, -0.08, 0.08) * (1 - Math.exp(-dt / 0.12));
      }
      this.Energy += (1 - this.Energy) * (1 - Math.exp(-dt / 0.12));
      this.Bend =
        this.lockStartPose * (1 - this.Energy) +
        MusicMotion.beatPose(this.Cycle) *
          clamp(strength, 0.8, 1) *
          this.Energy;
    } else {
      this.Energy *= Math.exp(-dt / 0.12);
      this.Bend *= Math.exp(-dt / 0.1);
    }
    this.wasLocked = locked;
    this.BendSpeed = (this.Bend - old) / dt;
    this.Pulse = clamp(this.Bend / 0.4, 0, 1);
    this.spring(
      "Rock",
      "RockSpeed",
      locked
        ? 7.5 * Math.sin(2 * Math.PI * (this.Cycle - 0.04)) * this.Energy
        : 0,
      dt,
      18,
      0.7,
    );
    this.spring(
      "Lamp",
      "LampSpeed",
      locked ? 8 * Math.sin(Math.PI * this.Cycle) * this.Energy : 0,
      dt,
      9,
      0.75,
    );
    if (this.throwMomentum && Math.abs(this.Vx) > 35 * this.Dpi) {
      this.moveAir(dt, 0.75);
      return;
    }
    this.throwMomentum = false;
    const margin = this.margin;
    if (this.X < margin) this.Direction = 1;
    if (this.X > this.Width - margin) this.Direction = -1;
    const available =
        this.Direction < 0 ? this.X - margin : this.Width - margin - this.X,
      rate = locked ? 4 : 10,
      wanted =
        this.Direction *
        25 *
        this.Dpi *
        this.Energy *
        Math.min(1, Math.max(0, available) / (28 * this.Dpi)),
      decay = Math.exp(-dt * rate),
      previous = this.Vx;
    this.Vx = wanted + (previous - wanted) * decay;
    this.X += wanted * dt + ((previous - wanted) * (1 - decay)) / rate;
    if (this.X < margin + this.Dpi && this.Direction < 0) this.Direction = 1;
    if (this.X > this.Width - margin - this.Dpi && this.Direction > 0)
      this.Direction = -1;
    this.X = clamp(
      this.X,
      this.flightMargin,
      Math.max(this.flightMargin, this.Width - this.flightMargin),
    );
    if (Math.abs(this.Bend) < 0.00001 && Math.abs(this.BendSpeed) < 0.0001)
      this.Bend = this.BendSpeed = 0;
    if (this.Energy < 0.00001) this.Energy = 0;
    if (this.Pulse < 0.00001) this.Pulse = 0;
  }
  respondToOnset(age, strength) {
    if (this.Held || this.Phase < 2 || age < 0 || age > 0.34) return;
    this.Bend = MusicMotion.beatPose(age / 0.5) * clamp(strength, 0.8, 1);
    this.BendSpeed = 0;
    this.Pulse = clamp(this.Bend / 0.4, 0, 1);
    this.Energy = Math.max(this.Energy, Math.exp(-age / 0.12));
  }
  get moving() {
    return (
      this.Phase < 2 ||
      this.Energy > 0.001 ||
      Math.abs(this.Bend) > 0.0001 ||
      Math.abs(this.Rock) > 0.005 ||
      Math.abs(this.RockSpeed) > 0.01 ||
      Math.abs(this.Lamp) > 0.005 ||
      Math.abs(this.LampSpeed) > 0.01 ||
      Math.abs(this.Vx) > 0.05
    );
  }
}
