export class CloakTransition {
  constructor() {
    this.active = false;
    this.cloaked = false;
    this.previous = null;
    this.deadline = 0;
    this.stableSince = 0;
  }
  begin(now) {
    if (this.active) return;
    this.active = true;
    this.deadline = now + 256;
    this.previous = null;
    this.stableSince = now;
  }
  sample(now, covered) {
    if (!this.active) return 0;
    if (this.previous !== covered) {
      this.previous = covered;
      this.stableSince = now;
    }
    let action = 0;
    if (covered && !this.cloaked) {
      this.cloaked = true;
      action = 1;
    }
    if (
      !covered &&
      this.cloaked &&
      (now - this.stableSince >= 32 || now >= this.deadline)
    ) {
      this.cloaked = false;
      action = -1;
    }
    if (action === -1 || now >= this.deadline) this.active = false;
    return action;
  }
  stop() {
    this.active = false;
    this.cloaked = false;
    this.previous = null;
  }
}
export class OcclusionRecovery {
  constructor(native, handle) {
    this.native = native;
    this.handle = handle;
    this.transition = new CloakTransition();
    this.timer = null;
    this.watch = null;
    this.host = 0;
    this.enabled = false;
    this.cloaked = false;
    this.failed = false;
    this.checks = 0;
    this.toggles = 0;
  }
  configure(host, enabled) {
    if (this.host === host && this.enabled === enabled) return;
    this.restore();
    this.host = host;
    this.enabled = enabled;
    if (enabled) this.begin();
  }
  begin() {
    if (!this.enabled || this.failed || this.timer || !this.host) return;
    clearTimeout(this.watch);
    this.transition.begin(Date.now());
    this.step();
    if (this.transition.active)
      this.timer = setInterval(() => {
        this.step();
        if (!this.transition.active) {
          clearInterval(this.timer);
          this.timer = null;
          if (this.cloaked) this.watch = setTimeout(() => this.begin(), 500);
        }
      }, 32);
  }
  step() {
    if (
      !this.enabled ||
      !this.native.valid(this.handle) ||
      !this.native.visible(this.host)
    ) {
      this.restore();
      return;
    }
    const covered = this.native.fullyCovered(this.host);
    this.checks++;
    if (covered === null) {
      this.restore();
      return;
    }
    const action = this.transition.sample(Date.now(), covered);
    if (action) {
      if (!this.native.cloak(this.handle, action > 0)) {
        this.failed = true;
        this.restore();
        return;
      }
      this.cloaked = action > 0;
      this.toggles++;
    }
  }
  restore() {
    clearInterval(this.timer);
    clearTimeout(this.watch);
    this.timer = null;
    this.watch = null;
    this.transition.stop();
    if (this.cloaked) this.native.cloak(this.handle, false);
    this.cloaked = false;
  }
  close() {
    this.enabled = false;
    this.restore();
  }
}
