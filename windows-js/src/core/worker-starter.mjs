import { healthyWorker } from "../../runtime/worker-state.mjs";
import { widgetUpdating } from "../../runtime/refresh-client.mjs";

// Presence polling stays at one second; only failed starts are backed off.
export class WorkerStarter {
  constructor({dataDir, launch, now = Date.now, healthy = healthyWorker, updating = widgetUpdating}) {
    Object.assign(this, {dataDir, launch, now, healthy, updating});
    this.child = null;
    this.lastStart = -Infinity;
  }
  ensure() {
    const now = this.now();
    if (this.updating(this.dataDir) || this.healthy(this.dataDir, this.now)) return;
    if (this.child && this.child.exitCode === null) return;
    if (now - this.lastStart < 5000) return;
    this.lastStart = now;
    const child = this.child = this.launch();
    child.once("error", () => { if (this.child === child) this.child = null; });
    return child;
  }
}
