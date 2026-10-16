import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {RolloutTail, allowedRollout, readRecentThreads} from './thread-speed.mjs';

// Only explicit event metadata is retained. No titles, responses or paths leave
// this process. Baseline each file at EOF, never replay completed history.
export class CompletionEvents {
  constructor(threadId) { this.threadId = threadId; this.reset(); this.events = []; }
  reset() { this.running = null; }
  accept(record) {
    if (record?.type !== 'event_msg') return;
    const event = record.payload, at = Date.parse(record.timestamp);
    if (!Number.isFinite(at)) return;
    const turnId = typeof event?.turn_id === 'string' ? event.turn_id : null;
    if (event?.type === 'task_started') { this.running = {turnId, at}; return; }
    if (!this.running || (turnId && this.running.turnId && turnId !== this.running.turnId)) return;
    if (event?.type === 'turn_aborted' || event?.type === 'task_failed') { this.reset(); return; }
    if (event?.type !== 'task_complete') return;
    if (event.error != null) { this.reset(); return; }
    if (at < this.running.at) return;
    this.events.push({threadId: this.threadId, eventId: `${this.threadId}:${this.running.turnId ?? this.running.at}:${at}`, at});
    this.reset();
  }
  drain() { const events = this.events; this.events = []; return events; }
}
export class CompletionMonitor {
  constructor(codexHome, startedAt = Date.now()) { this.home = codexHome; this.startedAt = startedAt; this.firstScan = true; this.tails = new Map(); }
  update(rows) {
    const active = new Set(), events = [];
    for (const row of rows.slice(0, 12)) {
      // Internal guardian/subagent turns also emit task_complete, but do not
      // finish a user conversation. Accept only explicit interactive sources.
      if (!['cli', 'vscode'].includes(row.source)) continue;
      if (typeof row.id !== 'string' || row.id.length > 200) continue;
      const file = allowedRollout(row.rollout_path, this.home);
      if (!file) continue;
      const key = row.id + ':' + file;
      active.add(key);
      try {
        if (!this.tails.has(key)) {
          const collector = new CompletionEvents(row.id);
          const tail = new RolloutTail(file, {liveOnly: this.firstScan, onRecord: record => {
            if (Date.parse(record.timestamp) >= this.startedAt) collector.accept(record);
          }});
          tail.onReset = () => collector.reset();
          this.tails.set(key, {tail, collector});
        }
        const {tail, collector} = this.tails.get(key);
        tail.update(); tail.liveOnly = true; events.push(...collector.drain());
      } catch { this.tails.delete(key); }
    }
    for (const key of this.tails.keys()) if (!active.has(key)) this.tails.delete(key);
    this.firstScan = false;
    return events;
  }
}
function run() {
  const home = process.env.CODEX_HOME || path.join(process.env.HOME || '', '.codex');
  const monitor = new CompletionMonitor(home);
  const send = value => process.stdout.write(JSON.stringify(value) + '\n');
  const update = () => {
    try { const rows = readRecentThreads(home, {userFacingOnly: true}); send({events: monitor.update(rows), sessionCount: rows.length, error: null}); }
    catch { send({events: [], sessionCount: 0, error: 'LOCAL_INDEX_UNAVAILABLE'}); }
  };
  update(); const timer = setInterval(update, 3000);
  process.stdin.resume();
  process.stdin.on('end', () => { clearInterval(timer); process.exit(0); });
  process.on('SIGTERM', () => { clearInterval(timer); process.exit(0); });
}
if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) run();
