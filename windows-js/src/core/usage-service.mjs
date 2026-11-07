import { Worker } from "node:worker_threads";
export class UsageService {
  constructor({
    dataDir,
    codexHome,
    onChange = () => {},
    workerUrl = new URL("../usage-worker.mjs", import.meta.url),
  }) {
    this.dataDir = dataDir;
    this.codexHome = codexHome;
    this.onChange = onChange;
    this.workerUrl = workerUrl;
    this.worker = null;
    this.pending = new Map();
    this.nextId = 0;
    this.value = {
      snapshot: null,
      preferences: { schema: 1, codexHome: null, rules: [] },
      error: null,
    };
  }
  start() {
    if (this.worker) return;
    const worker = new Worker(this.workerUrl, {
      workerData: { dataDir: this.dataDir, codexHome: this.codexHome },
    });
    this.worker = worker;
    const failed = () => {
      if (this.worker !== worker) return;
      this.worker = null;
      this.value = {
        ...this.value,
        error: "本地用量读取已停止，重新打开面板可重试。",
      };
      for (const item of this.pending.values()) {
        clearTimeout(item.timer);
        item.reject(Error(this.value.error));
      }
      this.pending.clear();
      this.onChange();
    };
    worker.on("message", (value) => {
      if (this.worker !== worker) return;
      this.value = {
        snapshot: value.snapshot ?? null,
        preferences: value.preferences ?? this.value.preferences,
        error: value.error ?? null,
      };
      const item = this.pending.get(value.requestId);
      if (item) {
        clearTimeout(item.timer);
        this.pending.delete(value.requestId);
        value.ok ? item.resolve(this.value) : item.reject(Error(value.error));
      }
      this.onChange();
    });
    worker.on("error", failed);
    worker.on("exit", failed);
  }
  request(op, value) {
    this.start();
    const requestId = ++this.nextId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(requestId);
        reject(Error("日志读取仍在进行，请稍后重试。"));
      }, 10000);
      this.pending.set(requestId, { resolve, reject, timer });
      this.worker.postMessage({ requestId, op, value });
    });
  }
  close() {
    const worker = this.worker;
    if (!worker) return;
    this.worker = null;
    for (const item of this.pending.values()) {
      clearTimeout(item.timer);
      item.reject(Error("用量面板已关闭"));
    }
    this.pending.clear();
    worker.postMessage({ op: "stop" });
    worker.unref();
    const timer = setTimeout(() => void worker.terminate(), 2000);
    timer.unref();
    worker.once("exit", () => clearTimeout(timer));
  }
}
