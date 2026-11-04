import { spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import path from "node:path";
import { createInterface } from "node:readline";
export class WindowsBridge extends EventEmitter {
  constructor(root) {
    super();
    this.child = spawn(path.join(root, "native", "GPTNiang.Native.exe"), [], {
      windowsHide: true,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.pending = new Map();
    this.id = 0;
    this.audio = null;
    this.alive = true;
    this.child.stdin.on("error", () => {});
    this.child.on("exit", () => {
      this.alive = false;
      this.audio = null;
      for (const p of this.pending.values()) {
        clearTimeout(p.timer);
        p.resolve(false);
      }
      this.pending.clear();
      this.emit("audio", { snapshot: {}, nowMs: 0 });
    });
    this.child.on("error", (e) => {
      this.error = e.message;
    });
    this.child.stderr.on("data", (b) => {
      this.error = b.toString().slice(0, 512);
    });
    createInterface({ input: this.child.stdout }).on("line", (line) => {
      try {
        const v = JSON.parse(line);
        if (v.type === "audio") {
          this.audio = v;
          this.emit("audio", v);
        } else if (v.type === "ready") {
          const p = this.pending.get(v.id);
          if (p) {
            this.pending.delete(v.id);
            clearTimeout(p.timer);
            p.resolve(v.ready);
          }
        } else if (v.type === "error") this.error = v.error;
      } catch {}
    });
  }
  send(value) {
    if (this.alive && this.child.stdin.writable)
      this.child.stdin.write(JSON.stringify(value) + "\n");
  }
  capture(enabled) {
    if (enabled && !this.alive)
      throw Error("音乐检测已退出，请重新启动挂件后再开启律动。");
    this.send({ op: enabled ? "start" : "stop" });
    if (!enabled) this.audio = null;
  }
  probe(handle) {
    if (!this.alive || this.pending.size) return Promise.resolve(false);
    const id = ++this.id;
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        resolve(false);
      }, 3000);
      this.pending.set(id, { resolve, timer });
      this.send({ op: "probe", id, handle });
    });
  }
  close() {
    this.child.stdin.end();
    for (const p of this.pending.values()) {
      clearTimeout(p.timer);
      p.resolve(false);
    }
    this.pending.clear();
    setTimeout(() => {
      if (this.child.exitCode === null) this.child.kill();
    }, 500).unref();
  }
}
