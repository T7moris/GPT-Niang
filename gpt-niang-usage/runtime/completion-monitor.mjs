import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {StringDecoder} from 'node:string_decoder';
import {fileURLToPath} from 'node:url';
import {startDesktopWorkSource} from './desktop-work-state.mjs';

const TERMINAL_EVENTS = new Set(['task_complete', 'turn_complete', 'turn_aborted']);
const START_EVENTS = new Set(['task_started', 'turn_started']);
const MAX_READ_BYTES = 4 * 1024 * 1024;
const MAX_LINE_CHARACTERS = 1024 * 1024;
const MAX_SEEN_TURNS = 4096;

export function completionMessage(payload, eventType, maxCharacters = 28) {
  if (eventType === 'turn_aborted' || payload?.error) return '本轮已结束';

  const cleaned = cleanMessage(payload?.last_agent_message);
  if (!cleaned) return 'Codex 本轮已完成';

  const characters = Array.from(cleaned);
  const excerpt = characters.length > maxCharacters
    ? characters.slice(0, Math.max(0, maxCharacters - 1)).join('') + '…'
    : cleaned;
  return `Codex 已完成：${excerpt}`;
}

export function cleanMessage(value) {
  if (typeof value !== 'string') return '';
  return value
    .replace(/```[^\r\n]*\r?\n?([\s\S]*?)```/g, '$1')
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/^\s{0,3}#{1,6}\s+/gm, '')
    .replace(/^\s*>\s?/gm, '')
    .replace(/^\s*[-*+]\s+/gm, '')
    .replace(/\*\*(.+?)\*\*/g, '$1')
    .replace(/__(.+?)__/g, '$1')
    .replace(/\*(.+?)\*/g, '$1')
    .replace(/_(.+?)_/g, '$1')
    .replace(/`([^`]+)`/g, '$1')
    .replace(/`+/g, '')
    .replace(/[\r\n\t]+/g, ' ')
    .replace(/\s{2,}/g, ' ')
    .trim();
}

export function parseCompletionRecord(record, {sessionId = '', seenTurns = null} = {}) {
  if (record?.type !== 'event_msg') return null;
  const payload = record.payload;
  const eventType = payload?.type;
  if (!TERMINAL_EVENTS.has(eventType)) return null;

  const turnId = payload.turn_id ?? payload.task_id ?? record.turn_id ?? record.id;
  const fallbackId = record.timestamp ?? JSON.stringify(record);
  const key = `${sessionId}\0${String(turnId ?? fallbackId)}`;
  if (seenTurns?.has(key)) return null;
  if (seenTurns) {
    seenTurns.add(key);
    if (seenTurns.size > MAX_SEEN_TURNS) seenTurns.delete(seenTurns.values().next().value);
  }

  return {
    message: completionMessage(payload, eventType),
    turnId: String(turnId ?? fallbackId),
    eventType,
    success: eventType !== 'turn_aborted' && !payload?.error,
  };
}

export function parseWorkStartRecord(record, {seenStarts = null, seenTurns = null, sessionId = ''} = {}) {
  if (record?.type !== 'event_msg' || !START_EVENTS.has(record.payload?.type)) return null;
  const turnId = record.payload.turn_id ?? record.payload.task_id ?? record.turn_id;
  if (typeof turnId !== 'string' || !turnId.trim()) return null;
  const key = `${sessionId}\0${turnId}`;
  if (seenStarts?.has(key) || seenTurns?.has(key)) return null;
  seenStarts?.add(key);
  if (seenStarts?.size > MAX_SEEN_TURNS) seenStarts.delete(seenStarts.values().next().value);
  return {eventType: record.payload.type, turnId, started: true};
}

// Recover only the latest activity in a recently written parent conversation.
// Old interrupted conversations and historical completions are never replayed.
export function recoverWorkingTurn(file, stat = fs.statSync(file), now = Date.now()) {
  if (now - stat.mtimeMs > 120000 || file.split(path.sep).includes('archived_sessions')) return null;
  const count = Math.min(stat.size, MAX_READ_BYTES), start = stat.size - count;
  const buffer = Buffer.alloc(count); let fd;
  try {
    fd = fs.openSync(file, 'r'); fs.readSync(fd, buffer, 0, count, start);
    const lines = buffer.toString('utf8').split('\n');
    if (start) lines.shift();
    for (let i = lines.length - 1; i >= 0; i--) {
      if (lines[i].length > MAX_LINE_CHARACTERS || !lines[i].includes('"event_msg"')) continue;
      try {
        const record = JSON.parse(lines[i]);
        if (record?.type !== 'event_msg') continue;
        if (TERMINAL_EVENTS.has(record.payload?.type)) return null;
        const activity = parseWorkStartRecord(record);
        if (activity) return activity;
      } catch {}
    }
  } finally { if (fd !== undefined) fs.closeSync(fd); }
  return null;
}

function fileIdentity(stat) {
  return `${stat.dev}:${stat.ino}`;
}

export class CompletionRolloutTail {
  constructor(file, {sessionId = path.basename(file), baseline = false, includeStarts = false} = {}) {
    this.file = file;
    this.sessionId = sessionId;
    this.offset = 0;
    this.pending = '';
    this.discardingLongLine = false;
    this.identity = null;
    this.decoder = new StringDecoder('utf8');
    this.seenTurns = new Set();
    this.seenStarts = new Set();
    this.includeStarts = includeStarts;
    this.resetCount = 0;

    const stat = fs.statSync(file);
    this.identity = fileIdentity(stat);
    if (baseline) this.offset = stat.size;
  }

  update() {
    let stat;
    try { stat = fs.statSync(this.file); }
    catch { return []; }
    const identity = fileIdentity(stat);
    if (identity !== this.identity || stat.size < this.offset) {
      // A replaced or truncated file may contain old terminal events. Start at
      // its end so a rotation never replays an already completed turn.
      this.identity = identity;
      this.offset = stat.size;
      this.pending = '';
      this.discardingLongLine = false;
      this.decoder = new StringDecoder('utf8');
      this.resetCount++;
      return [];
    }
    const remaining = Math.min(stat.size - this.offset, MAX_READ_BYTES);
    if (remaining <= 0) return [];

    const buffer = Buffer.alloc(remaining);
    let count = 0;
    let fd;
    try {
      fd = fs.openSync(this.file, 'r');
      count = fs.readSync(fd, buffer, 0, remaining, this.offset);
    } catch { return []; }
    finally { if (fd !== undefined) fs.closeSync(fd); }
    if (!count) return [];
    this.offset += count;

    const lines = (this.pending + this.decoder.write(buffer.subarray(0, count))).split('\n');
    this.pending = lines.pop();
    const notifications = [];
    for (const rawLine of lines) {
      if (this.discardingLongLine) { this.discardingLongLine = false; continue; }
      const line = rawLine.endsWith('\r') ? rawLine.slice(0, -1) : rawLine;
      if (line.length > MAX_LINE_CHARACTERS || !line.includes('"event_msg"')) continue;
      try {
        const record = JSON.parse(line);
        const completion = parseCompletionRecord(record, {
          sessionId: this.sessionId,
          seenTurns: this.seenTurns,
        });
        if (completion) notifications.push(completion);
        else if (this.includeStarts) {
          const started = parseWorkStartRecord(record, {sessionId: this.sessionId, seenStarts: this.seenStarts, seenTurns: this.seenTurns});
          if (started) notifications.push(started);
        }
      } catch {}
    }
    if (this.pending.length > MAX_LINE_CHARACTERS) {
      this.pending = '';
      this.discardingLongLine = true;
    }
    return notifications;
  }
}

function isWithin(root, file) {
  const relative = path.relative(root, file);
  return relative !== '' && relative !== '..' && !relative.startsWith('..' + path.sep) && !path.isAbsolute(relative);
}

function isSubagentRollout(file) {
  let fd;
  try {
    fd = fs.openSync(file, 'r');
    const buffer = Buffer.alloc(64 * 1024);
    const count = fs.readSync(fd, buffer, 0, buffer.length, 0);
    if (!count) return null;
    const contents = buffer.subarray(0, count).toString('utf8');
    const newline = contents.indexOf('\n');
    // Wait for a complete first JSONL record before deciding whether this is
    // a user conversation or an internal agent session.
    if (newline < 0) return null;
    const firstLine = contents.slice(0, newline).trimEnd();
    let record;
    try { record = JSON.parse(firstLine); }
    catch { return null; }
    if (record?.type !== 'session_meta') return false;
    const source = record.payload?.source;
    return Boolean(source && typeof source === 'object' && Object.hasOwn(source, 'subagent'));
  } catch {
    return null;
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

export function listRolloutFiles(codexHome) {
  const files = [];
  for (const name of ['sessions', 'archived_sessions']) {
    const directory = path.join(codexHome, name);
    let root;
    try { root = fs.realpathSync(directory); }
    catch { continue; }

    const pending = [root];
    while (pending.length) {
      const current = pending.pop();
      let entries;
      try { entries = fs.readdirSync(current, {withFileTypes: true}); }
      catch { continue; }
      for (const entry of entries) {
        const candidate = path.join(current, entry.name);
        if (entry.isDirectory()) { pending.push(candidate); continue; }
        if (!entry.isFile() || !entry.name.endsWith('.jsonl')) continue;
        try {
          const real = fs.realpathSync(candidate);
          if (isWithin(root, real)) files.push(real);
        } catch {}
      }
    }
  }
  return [...new Set(files)];
}

export function defaultCodexHome(env = process.env) {
  return path.resolve(env.CODEX_HOME || path.join(env.USERPROFILE || env.HOME || os.homedir(), '.codex'));
}

export class CompletionMonitor {
  constructor({codexHome = defaultCodexHome(), intervalMs = 1000, onNotification = () => {}, onWorkState = () => {}} = {}) {
    this.codexHome = codexHome;
    this.intervalMs = intervalMs;
    this.onNotification = onNotification;
    this.onWorkState = onWorkState;
    this.activeTurns = new Set();
    this.lastActiveCount = -1;
    this.desktopActiveCount = 0;
    this.tails = new Map();
    this.subagentSessions = new Set();
    this.timer = null;
  }

  start() {
    if (this.timer) return;
    this.scan(true);
    this.timer = setInterval(() => this.scan(false), this.intervalMs);
    this.timer.unref?.();
  }

  scan(baseline = false) {
    const present = new Set();
    for (const file of listRolloutFiles(this.codexHome)) {
      const sessionId = path.basename(file);
      present.add(sessionId);
      if (this.subagentSessions.has(sessionId)) continue;
      let tail = this.tails.get(sessionId);
      if (!tail) {
        const isSubagent = isSubagentRollout(file);
        if (isSubagent === null) continue;
        if (isSubagent) {
          this.subagentSessions.add(sessionId);
          continue;
        }
        try { tail = new CompletionRolloutTail(file, {sessionId, baseline, includeStarts: true}); }
        catch { continue; }
        this.tails.set(sessionId, tail);
        if (baseline) {
          try {
            const started = recoverWorkingTurn(file);
            if (started) this.activeTurns.add(`${sessionId}\0${started.turnId}`);
          } catch {}
          continue;
        }
      } else {
        tail.file = file;
      }
      const resetCount = tail.resetCount;
      const updates = tail.update();
      if (tail.resetCount !== resetCount) this.clearSession(sessionId);
      for (const notification of updates) {
        const key = `${sessionId}\0${notification.turnId}`;
        if (notification.started) { this.activeTurns.add(key); continue; }
        this.activeTurns.delete(key);
        try { this.onNotification(notification); } catch {}
      }
    }
    for (const sessionId of this.tails.keys()) if (!present.has(sessionId)) this.clearSession(sessionId);
    this.publishWorkState();
  }

  clearSession(sessionId) {
    for (const key of this.activeTurns) if (key.startsWith(sessionId + '\0')) this.activeTurns.delete(key);
  }

  publishWorkState() {
    const count = this.activeTurns.size + this.desktopActiveCount;
    if (this.lastActiveCount === count) return;
    this.lastActiveCount = count;
    try { this.onWorkState({eventType: 'work_state', working: count > 0, activeTurns: count, localActiveTurns: this.activeTurns.size, cloudActiveTasks: this.desktopActiveCount}); } catch {}
  }

  setDesktopWorkState(state) {
    this.desktopActiveCount = Number.isSafeInteger(state?.activeCount) && state.activeCount >= 0 ? state.activeCount : 0;
    this.publishWorkState();
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    this.activeTurns.clear();
    this.desktopActiveCount = 0;
    this.publishWorkState();
  }
}

function run() {
  const monitor = new CompletionMonitor({
    onNotification: notification => process.stdout.write(JSON.stringify(notification) + '\n'),
    onWorkState: state => process.stdout.write(JSON.stringify(state) + '\n'),
  });
  monitor.start();
  const desktop = startDesktopWorkSource({root: path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..'), codexHome: monitor.codexHome, onState: state => monitor.setDesktopWorkState(state)});
  process.stdin.resume();
  const stop = () => { desktop?.stop(); monitor.stop(); process.exit(0); };
  process.stdin.on('end', stop);
  process.on('SIGTERM', stop);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) run();
