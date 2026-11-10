import path from 'node:path';
import fs from 'node:fs';
import {createHash} from 'node:crypto';
import {NotificationLogMonitor} from './desktop-notifications.mjs';
import {PermissionHookMonitor} from './permission-hook.mjs';
import {fileURLToPath} from 'node:url';
import {RolloutTail, allowedRollout, readRecentThreads} from './thread-speed.mjs';

// Only explicit event metadata is retained. No titles, responses or paths leave
// this process. Baseline each file at EOF, never replay completed history.
export class CompletionEvents {
  constructor(threadId) { this.threadId = threadId; this.reset(); this.events = []; }
  reset() { this.running = null; this.questions = new Map(); this.announcedQuestions = new Set(); }
  accept(record) {
    const event = record?.payload, at = Date.parse(record?.timestamp);
    if (!Number.isFinite(at)) return;
    if (record.type === 'response_item') {
      if (!this.running || at < this.running.at) return;
      const id = event?.call_id;
      if (typeof id !== 'string' || !id || id.length > 200 || this.announcedQuestions.has(id)) return;
      if (event.type === 'function_call' && ['request_user_input_async', 'functions.request_user_input_async'].includes(event.name)) {
        this.questions.set(id, at);
        if (this.questions.size > 256) this.questions.delete(this.questions.keys().next().value);
      } else if (event.type === 'function_call_output' && this.questions.has(id)) {
        const startedAt = this.questions.get(id); this.questions.delete(id);
        if (at < startedAt || typeof event.output !== 'string' || event.output.length > 4096) return;
        // An async call alone can fail or be unavailable. Announce only its
        // explicit acceptance, without reading question/answer arguments.
        let result; try { result = JSON.parse(event.output); } catch { return; }
        if (result?.accepted !== true) return;
        this.announcedQuestions.add(id);
        if (this.announcedQuestions.size > 4096) this.announcedQuestions.delete(this.announcedQuestions.values().next().value);
        const eventId = 'notice:' + createHash('sha256').update('question-local-' + id).digest('hex');
        this.events.push({threadId: this.threadId, eventId, kind: 'question', at});
      }
      return;
    }
    if (record.type !== 'event_msg') return;
    const turnId = typeof event?.turn_id === 'string' ? event.turn_id : null;
    if (event?.type === 'task_started') { this.reset(); this.running = {turnId, at}; return; }
    if (!this.running || (turnId && this.running.turnId && turnId !== this.running.turnId)) return;
    if (event?.type === 'turn_aborted' || event?.type === 'task_failed') { this.reset(); return; }
    if (event?.type !== 'task_complete') return;
    if (event.error != null) { this.reset(); return; }
    if (at < this.running.at) return;
    this.events.push({threadId: this.threadId, eventId: `${this.threadId}:${this.running.turnId ?? this.running.at}`, at});
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
          const tail = new RolloutTail(file, {liveOnly: this.firstScan, includeToolCalls: true, onRecord: record => {
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
  const logRoot = process.env.GPT_NIANG_NOTIFICATION_LOG_ROOT || path.join(process.env.HOME || '', 'Library/Logs/com.openai.codex');
  const monitor = new CompletionMonitor(home);
  const notices = new NotificationLogMonitor(logRoot);
  const permissions = new PermissionHookMonitor(process.env.GPT_NIANG_PERMISSION_EVENT_DIR);
  const send = value => process.stdout.write(JSON.stringify(value) + '\n');
  let rows = [], indexedAt = 0, indexError = null, pending = null, stopped = false;
  const watchers = new Map();
  const schedule = () => { if (!pending && !stopped) pending = setTimeout(() => {pending = null; update();}, Math.max(200, 1000 - (Date.now() - indexedAt))); };
  const watch = (directory, recursive) => {
    if (watchers.has(directory) || !fs.existsSync(directory)) return;
    try {
      const watcher = fs.watch(directory, {recursive}, event => {
        if (event === 'rename' && !recursive) { watcher.close(); watchers.delete(directory); }
        schedule();
      });
      watchers.set(directory, watcher);
      watcher.on('error', () => {watcher.close(); watchers.delete(directory);});
    } catch { /* Slow reconciliation remains available on unsupported filesystems. */ }
  };
  const update = () => {
    // Index discovery is bounded even during sustained token streaming. Existing
    // file tails are read on writes; the 30-second timer only repairs missed events.
    if (Date.now() - indexedAt >= 1000) {
      indexedAt = Date.now();
      try { rows = readRecentThreads(home, {userFacingOnly:true}); indexError = null; }
      catch { indexError = 'LOCAL_INDEX_UNAVAILABLE'; }
    }
    const events = [...monitor.update(rows), ...notices.update(), ...permissions.update()];
    const unique = [...new Map(events.map(e => [e.eventId, e])).values()];
    watch(home, false); watch(path.join(home, 'sessions'), true); watch(logRoot, true);
    if (permissions.root) watch(permissions.root, false);
    for (const {tail} of monitor.tails.values()) watch(tail.file, false);
    for (const file of notices.tails.keys()) watch(file, false);
    const keep = new Set([home, path.join(home, 'sessions'), logRoot, permissions.root,
      ...[...monitor.tails.values()].map(v => v.tail.file), ...notices.tails.keys()]);
    for (const [file, watcher] of watchers) if (!keep.has(file)) {watcher.close(); watchers.delete(file);}
    send({events:unique, sessionCount:rows.length, error:indexError,
      notificationLogAvailable:notices.available});
  };
  update(); schedule(); const timer = setInterval(update, 30000);
  process.stdin.resume();
  const stop = () => {
    stopped = true; clearInterval(timer); clearTimeout(pending);
    for (const watcher of watchers.values()) watcher.close();
    process.exit(0);
  };
  process.stdin.on('end', stop); process.on('SIGTERM', stop);
}
if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) run();
