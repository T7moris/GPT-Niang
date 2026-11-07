import { EventEmitter } from "node:events";
export class Scene extends EventEmitter {
  constructor({ settings, quote, now = Date.now }) {
    super();
    this.settings = settings;
    this.quote = quote;
    this.now = now;
    this.collapsed = true;
    this.mode = "quota";
    this.revision = 0;
    this.startedAt = 0;
    this.deadline = 0;
    this.text = "";
    this.resetTimeMode = "countdown";
    this.preview = false;
  }
  snapshot() {
    return {
      collapsed: this.collapsed,
      mode: this.mode,
      revision: this.revision,
      startedAt: this.startedAt,
      deadline: this.deadline,
      text: this.text,
      resetTimeMode: this.resetTimeMode,
      preview: this.preview,
    };
  }
  changed() {
    this.emit("change", this.snapshot());
  }
  restart(delay = 0) {
    this.startedAt = this.now() + delay;
    this.deadline = this.startedAt + 5000;
    this.resetTimeMode = "countdown";
    this.changed();
  }
  show(mode, { text, animate = true } = {}) {
    const opening = this.collapsed;
    if (!opening && mode !== "quote" && this.mode === mode) {
      this.restart();
      return;
    }
    this.collapsed = false;
    this.mode = mode;
    this.revision++;
    if (mode === "quote") this.text = this.quote();
    else if (mode === "completion") this.text = text || "Codex\n有回复已结束";
    this.restart(animate ? (opening ? 520 : 280) : 0);
  }
  hide() {
    if (this.collapsed) return;
    this.collapsed = true;
    this.deadline = 0;
    this.preview = false;
    this.changed();
  }
  next() {
    if (this.collapsed) return;
    else if (this.mode === "quota") this.show("quote");
    else this.hide();
  }
  characterClick() {
    if (this.collapsed) this.show("quota");
    else if (this.settings.characterQuoteRepeat) this.show('quote');
    else if (this.settings.bubbleTapAdvance) this.next();
    else if (this.mode !== "quota") this.show("quota");
    else this.restart();
  }
  bubbleClick() {
    this.next();
  }
  refreshInside() {
    if (!this.collapsed) this.restart();
    this.emit("refresh");
  }
  refreshFromMenu() {
    this.emit("refresh");
  }
  tick(now = this.now()) {
    if (this.collapsed || this.preview || !this.deadline) return;
    if (now >= this.deadline) {
      this.hide();
      return;
    }
    if (
      this.mode === "quota" &&
      this.resetTimeMode !== "fixed" &&
      now >= this.startedAt + 2000
    ) {
      this.resetTimeMode = "fixed";
      this.changed();
    }
  }
}
