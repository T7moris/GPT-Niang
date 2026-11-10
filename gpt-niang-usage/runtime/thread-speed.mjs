import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

// Accounting checkpoints include tools, network and reasoning. They are NOT
// decoder/streaming TPS. Only metadata and token counters leave this process.
export function sampleInterval(previous, next) {
  if (!previous || !next || !Number.isFinite(previous.at) || !Number.isFinite(next.at)) return null;
  const seconds = (next.at - previous.at) / 1000;
  const outputTokens = next.outputTokens - previous.outputTokens;
  if (seconds <= 0 || !Number.isSafeInteger(outputTokens) || outputTokens < 0) return null;
  return {outputTokens, seconds, tokensPerSecond: outputTokens / seconds, at: next.at};
}
export class RolloutCounters {
  constructor() { this.previous = null; this.latest = null; this.state = 'unknown'; this.lastAt = null; }
  accept(record) {
    if (record?.type !== 'event_msg') return;
    const event = record.payload;
    const at = Date.parse(record.timestamp);
    if (!Number.isFinite(at)) return;
    if (event?.type === 'task_started') {
      // Never include human idle time between turns in the next sample.
      this.previous = this.previous ? {...this.previous, at} : null;
      this.latest = null; this.state = 'running'; this.lastAt = at; return;
    }
    if (['task_complete', 'turn_aborted'].includes(event?.type)) { this.state = event.type === 'task_complete' ? 'idle' : 'cancelled'; this.lastAt = at; return; }
    if (event?.type !== 'token_count') return;
    const outputTokens = event.info?.total_token_usage?.output_tokens;
    if (!Number.isSafeInteger(outputTokens) || outputTokens < 0) return;
    if (this.previous?.outputTokens === outputTokens) return; // duplicate quota-only updates
    const next = {at, outputTokens};
    this.latest = sampleInterval(this.previous, next);
    this.previous = next; this.lastAt = at;
  }
}
export class RolloutTail {
  constructor(file, {onRecord = null, liveOnly = false, includeToolCalls = false} = {}) { this.file = file; this.offset = 0; this.pending = ''; this.counters = new RolloutCounters(); this.identity = null; this.onRecord = onRecord; this.liveOnly = liveOnly; this.includeToolCalls = includeToolCalls; this.onReset = null; }
  update() {
    const stat = fs.statSync(this.file);
    if (stat.ino !== this.identity || stat.size < this.offset) {
      this.identity = stat.ino; this.offset = this.liveOnly ? stat.size : Math.max(0, stat.size - 4 * 1024 * 1024);
      this.onReset?.();
      this.pending = ''; this.counters = new RolloutCounters();
      this.skipFirst = this.offset > 0;
      if (this.liveOnly && stat.size > 0) {
        const fd = fs.openSync(this.file, 'r');
        const last = Buffer.alloc(1);
        try { fs.readSync(fd, last, 0, 1, stat.size - 1); } finally { fs.closeSync(fd); }
        this.skipFirst = last[0] !== 10;
      }
    }
    const remaining = Math.min(stat.size - this.offset, 4 * 1024 * 1024);
    if (remaining <= 0) return this.counters;
    const buffer = Buffer.alloc(remaining);
    const fd = fs.openSync(this.file, 'r');
    let count;
    try { count = fs.readSync(fd, buffer, 0, remaining, this.offset); } finally { fs.closeSync(fd); }
    this.offset += count;
    // Counters/timestamps are ASCII; a partial UTF-8 content line is never emitted.
    const lines = (this.pending + buffer.subarray(0, count).toString('utf8')).split('\n');
    this.pending = lines.pop();
    if (this.pending.length > 1024 * 1024) { this.pending = ''; this.skipFirst = true; this.onReset?.(); }
    if (this.skipFirst && lines.length) { lines.shift(); this.skipFirst = false; }
    for (const line of lines) {
      // The speed panel keeps its event-only protocol. The alert reader may
      // opt into explicit tool calls/results, never chat-message records.
      if (!line.includes('"event_msg"') && !(this.includeToolCalls && line.includes('"response_item"') && line.includes('"function_call'))) continue;
      try { const record = JSON.parse(line); this.counters.accept(record); this.onRecord?.(record); } catch {}
    }
    return this.counters;
  }
}
export function allowedRollout(file, codexHome) {
  try {
    const real = fs.realpathSync(file);
    return ['sessions', 'archived_sessions'].some(name => {
      let directory;
      try { directory = fs.realpathSync(path.join(codexHome, name)); } catch { return false; }
      const relative = path.relative(directory, real);
      return relative && !relative.startsWith('..' + path.sep) && relative !== '..' && !path.isAbsolute(relative) && real.endsWith('.jsonl');
    }) ? real : null;
  } catch { return null; }
}
export function readRecentThreads(codexHome, {userFacingOnly = false} = {}) {
  const databases = fs.readdirSync(codexHome).filter(name => /^state_\d+\.sqlite$/.test(name))
    .sort((a, b) => Number(b.match(/\d+/)[0]) - Number(a.match(/\d+/)[0]));
  if (!databases.length) throw new Error('目前沒有可讀取的本機聊天索引');
  const result = spawnSync('/usr/bin/sqlite3', ['-readonly', '-json', path.join(codexHome, databases[0]),
    // Filter before LIMIT so internal review/agent sessions cannot crowd out chats.
    userFacingOnly
      ? "SELECT id,title,rollout_path,source FROM threads WHERE archived=0 AND source IN ('cli','vscode') ORDER BY updated_at DESC LIMIT 12;"
      : 'SELECT id,title,rollout_path FROM threads WHERE archived=0 ORDER BY updated_at DESC LIMIT 12;'],
    {encoding: 'utf8', timeout: 2000, maxBuffer: 256 * 1024});
  if (result.status !== 0) throw new Error('本機聊天索引暫時無法讀取');
  const rows = JSON.parse(result.stdout || '[]');
  return rows;
}
function run() {
  const codexHome = process.env.CODEX_HOME || path.join(process.env.HOME || '', '.codex');
  const tails = new Map();
  const send = value => process.stdout.write(JSON.stringify(value) + '\n');
  function update() {
    try {
      const rows = readRecentThreads(codexHome);
      const active = new Set();
      const threads = rows.map(row => {
        const file = allowedRollout(row.rollout_path, codexHome);
        const output = {id: row.id, title: String(row.title || '未命名聊天').slice(0, 160), tokensPerSecond: null, sampleAt: null, state: 'unavailable'};
        if (!file) return output;
        active.add(file);
        try {
          if (!tails.has(file)) tails.set(file, new RolloutTail(file));
          const counters = tails.get(file).update();
          return {...output, state: counters.state, sampleAt: counters.latest?.at ?? null,
            tokensPerSecond: counters.latest?.tokensPerSecond ?? null,
            outputTokens: counters.latest?.outputTokens ?? null, intervalSeconds: counters.latest?.seconds ?? null};
        } catch { return output; }
      });
      for (const file of tails.keys()) if (!active.has(file)) tails.delete(file);
      send({threads, at: Date.now(), error: null});
    } catch (error) { send({threads: [], at: Date.now(), error: error.message}); }
  }
  update();
  const timer = setInterval(update, 3000);
  process.stdin.resume();
  process.stdin.on('end', () => { clearInterval(timer); process.exit(0); });
  process.on('SIGTERM', () => { clearInterval(timer); process.exit(0); });
}
if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) run();
