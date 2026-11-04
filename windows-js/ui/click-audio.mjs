// Original ordering: a short click lets the press clip finish, then waits 60 ms before release.
export class ClickSequence {
  constructor({
    play,
    stop,
    available,
    duration,
    enabled,
    now = () => performance.now(),
    schedule = (callback, delay) => setTimeout(callback, delay),
    cancel = (id) => clearTimeout(id),
  }) {
    Object.assign(this, {
      playClip: play,
      stopClip: stop,
      available,
      duration,
      enabled,
      now,
      schedule,
      cancel,
    });
    this.timer = null;
    this.pressing = false;
    this.at = 0;
  }
  stop() {
    if (this.timer !== null) this.cancel(this.timer);
    this.timer = null;
    this.pressing = false;
    this.stopClip();
  }
  press() {
    this.stop();
    if (
      !this.enabled() ||
      (!this.available("press") && !this.available("release"))
    )
      return;
    this.pressing = true;
    this.at = this.now();
    if (this.available("press")) this.playClip("press");
  }
  release() {
    if (!this.pressing) return;
    this.pressing = false;
    if (!this.enabled()) {
      this.stop();
      return;
    }
    if (!this.available("release")) return;
    const remaining = this.available("press")
      ? this.duration("press") * 1000 + 60 - (this.now() - this.at)
      : 0;
    const play = () => {
      this.timer = null;
      if (this.pressing || !this.enabled()) return;
      this.stopClip();
      this.playClip("release");
    };
    if (remaining <= 2) play();
    else this.timer = this.schedule(play, remaining);
  }
  preview(slot) {
    this.stop();
    if (this.enabled() && this.available("preview-" + slot))
      this.playClip("preview-" + slot);
  }
}
