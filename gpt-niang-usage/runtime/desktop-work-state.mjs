import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import {spawn} from 'node:child_process';

const CONTEXT_FILE = 'desktop-work-context.json';
const ACTIVE = new Set(['active', 'inProgress', 'in_progress', 'running']);
const INACTIVE = new Set(['idle', 'notLoaded', 'systemError', 'completed', 'failed', 'interrupted', 'needsAttention', 'waitingOnUserInput', 'waitingOnApproval']);
const THREAD_ID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;

function readJson(file) { return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '')); }
function writeJson(file, data) {
  const temp = file + '.' + process.pid + '.tmp';
  try { fs.writeFileSync(temp, JSON.stringify(data), {mode: 0o600}); fs.renameSync(temp, file); }
  finally { try { fs.unlinkSync(temp); } catch {} }
}

// The desktop supplies this local endpoint. Never scan for endpoints, read
// account tokens, or invent a caller identity. Refresh it when MCP restarts.
export function captureDesktopWorkContext(root, metadata = {}, env = process.env) {
  try {
    const {dataDir} = readJson(path.join(root, 'installation.json'));
    if (typeof dataDir !== 'string' || !path.isAbsolute(dataDir)) return false;
    const file = path.join(dataDir, CONTEXT_FILE);
    let old = {}; try { old = readJson(file); } catch {}
    let turn = metadata['x-codex-turn-metadata'];
    if (typeof turn === 'string') { try { turn = JSON.parse(turn); } catch { turn = null; } }
    const candidates = [metadata.codexThreadId, metadata['openai/threadId'], metadata['openai/thread_id'], metadata.threadId, turn?.thread_id, env.CODEX_THREAD_ID, env.CODEX_SESSION_ID, old.callerThreadId];
    const callerThreadId = candidates.find(value => typeof value === 'string' && THREAD_ID.test(value));
    const pipePath = env.CODEX_APP_TOOLS_PIPE_PATH;
    if (typeof pipePath !== 'string' || !pipePath.startsWith('\\\\.\\pipe\\') || pipePath.includes('\0') || pipePath.length > 512 || !callerThreadId) return false;
    fs.mkdirSync(dataDir, {recursive: true});
    writeJson(file, {schemaVersion: 1, pipePath, callerThreadId, capturedAt: Date.now()});
    return true;
  } catch { return false; }
}

export function findAppToolsServer(codexHome) {
  const root = path.join(codexHome, 'plugins', 'cache', 'openai-bundled', 'codex-app-tools');
  let versions; try { versions = fs.readdirSync(root).filter(name => /^\d+\.\d+\.\d+$/.test(name)); } catch { return null; }
  versions.sort((a, b) => { const aa = a.split('.').map(Number), bb = b.split('.').map(Number); for (let i = 0; i < 3; i++) if (aa[i] !== bb[i]) return bb[i] - aa[i]; return 0; });
  for (const version of versions) { const file = path.join(root, version, 'server.mjs'); if (fs.existsSync(file)) return file; }
  return null;
}

// Use the bundled MCP service rather than depending on the private pipe's wire
// format. This client can only call the two read-only status/retrieval tools.
export class DesktopAppStatusClient {
  constructor({dataDir, codexHome, nodePath = process.execPath, timeoutMs = 20000, spawnProcess = spawn}) {
    Object.assign(this, {dataDir, codexHome, nodePath, timeoutMs, spawnProcess});
    this.pending = new Map(); this.sequence = 0; this.child = null; this.ready = null; this.identity = null; this.context = null; this.stopped = false;
  }
  async connect() {
    if (this.stopped) throw Error('SOURCE_STOPPED');
    let context; try { context = readJson(path.join(this.dataDir, CONTEXT_FILE)); } catch { throw Error('DESKTOP_CONTEXT_MISSING'); }
    if (context.schemaVersion !== 1 || typeof context.pipePath !== 'string' || !context.pipePath.startsWith('\\\\.\\pipe\\') || !THREAD_ID.test(context.callerThreadId || '')) throw Error('DESKTOP_CONTEXT_INVALID');
    const server = findAppToolsServer(this.codexHome);
    if (!server) throw Error('APP_TOOLS_UNAVAILABLE');
    const identity = JSON.stringify([context.pipePath, context.callerThreadId, server]);
    if (identity !== this.identity) { this.disconnect(); this.identity = identity; }
    this.context = context;
    if (this.ready) return this.ready;
    this.ready = (async () => {
      const child = this.spawnProcess(this.nodePath, [server], {windowsHide: true, env: {...process.env, CODEX_APP_TOOLS_PIPE_PATH: context.pipePath}, stdio: ['pipe', 'pipe', 'pipe']});
      this.child = child;
      const lines = readline.createInterface({input: child.stdout});
      this.lines = lines;
      lines.on('line', line => {
        if (line.length > 8 * 1024 * 1024) { this.disconnect(); return; }
        try { const message = JSON.parse(line), pending = this.pending.get(message.id); if (!pending) return;
          clearTimeout(pending.timer); this.pending.delete(message.id);
          message.error ? pending.reject(Error('APP_RPC_ERROR')) : pending.resolve(message.result);
        } catch {}
      });
      child.stderr.resume();
      child.on('error', () => { if (this.child === child) this.disconnect(); });
      child.on('exit', () => { if (this.child === child) this.disconnect(); });
      child.stdin.on('error', () => { if (this.child === child) this.disconnect(); });
      await this.request('initialize', {protocolVersion: '2024-11-05', capabilities: {}, clientInfo: {name: 'gpt-niang-work-state', version: '1'}});
      child.stdin.write(JSON.stringify({jsonrpc: '2.0', method: 'notifications/initialized'}) + '\n');
      const catalog = await this.request('tools/list', {});
      this.tools = new Set((catalog.tools || []).map(tool => tool.name));
      if (!this.tools.has('list_threads') || !this.tools.has('read_thread')) throw Error('APP_STATUS_TOOLS_UNAVAILABLE');
    })().catch(error => { this.disconnect(); throw error; });
    return this.ready;
  }
  request(method, params) {
    if (!this.child) return Promise.reject(Error('APP_DISCONNECTED'));
    return new Promise((resolve, reject) => {
      const id = ++this.sequence;
      const timer = setTimeout(() => { this.pending.delete(id); reject(Error('APP_STATUS_TIMEOUT')); this.disconnect(); }, this.timeoutMs);
      this.pending.set(id, {resolve, reject, timer});
      this.child.stdin.write(JSON.stringify({jsonrpc: '2.0', id, method, params}) + '\n');
    });
  }
  async call(name, args) {
    if (!['list_threads', 'read_thread'].includes(name)) throw Error('READ_ONLY_TOOL_REQUIRED');
    await this.connect();
    const result = await this.request('tools/call', {name, arguments: args, _meta: {codexThreadId: this.context.callerThreadId}});
    if (result.isError) throw Error('APP_STATUS_READ_FAILED');
    const text = result.content?.find(item => item.type === 'text')?.text;
    try { return JSON.parse(text); } catch { throw Error('APP_STATUS_INVALID'); }
  }
  list() { return this.call('list_threads', {limit: 50}); }
  async read(thread) {
    const args = {threadId: thread.id, turnLimit: 1, includeOutputs: false, maxOutputCharsPerItem: 1};
    if (thread.kind === 'codex' && thread.hostId) args.hostId = thread.hostId;
    const result = await this.call('read_thread', args);
    return result.thread;
  }
  disconnect() {
    const child = this.child; this.child = null; this.ready = null;
    this.lines?.close(); this.lines = null;
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(Error('APP_DISCONNECTED')); }
    this.pending.clear();
    if (child) { try { child.kill(); } catch {} }
  }
  stop() { this.stopped = true; this.disconnect(); }
}

function workStatus(thread) {
  const status = typeof thread?.status === 'string' ? thread.status : thread?.status?.type;
  return ACTIVE.has(status) ? true : INACTIVE.has(status) ? false : null;
}
function cloudThread(thread) { return thread?.kind === 'chatgpt' || (thread?.kind === 'codex' && thread.hostId && thread.hostId !== 'local'); }
function key(thread) { return `${thread.kind}:${thread.hostId || ''}:${thread.id}`; }

export class DesktopWorkTracker {
  constructor({client, onState = () => {}, clock = Date.now, staleMs = 60000, intervalMs = 5000}) {
    Object.assign(this, {client, onState, clock, staleMs, intervalMs});
    this.active = new Map(); this.timer = null; this.polling = null; this.stopped = false; this.lastSuccessAt = 0; this.status = 'starting'; this.snapshotLimit = 50;
  }
  start() { if (this.timer) return; void this.poll(); this.timer = setInterval(() => { this.expire(); this.publish(); void this.poll(); }, this.intervalMs); this.timer.unref?.(); }
  async poll() {
    if (this.stopped) return;
    if (this.polling) return this.polling;
    this.polling = this.update().finally(() => { this.polling = null; });
    return this.polling;
  }
  async update() {
    try {
      const snapshot = await this.client.list();
      if (this.stopped) return;
      if (!Array.isArray(snapshot.threads) || !Array.isArray(snapshot.pinnedThreads)) throw Error('INVALID_SNAPSHOT');
      const rows = [...snapshot.pinnedThreads, ...snapshot.threads], present = new Set(); let unconfirmed = false;
      const unavailableSources = new Set(snapshot.unavailableSources || []), unavailableHosts = new Set(snapshot.unavailableHosts || []);
      const available = thread => !unavailableSources.has(thread.kind) && !(thread.kind === 'codex' && unavailableHosts.has(thread.hostId));
      for (const thread of rows) {
        if (!cloudThread(thread) || typeof thread.id !== 'string' || !available(thread)) continue;
        const id = key(thread); present.add(id); const active = workStatus(thread);
        if (active === true) this.active.set(id, {thread: {id: thread.id, kind: thread.kind, hostId: thread.hostId}, seenAt: this.clock()});
        else if (active === false) this.active.delete(id);
        else unconfirmed = true;
      }
      // The listing is limited to 50 recent chats. A known active task falling
      // out of that window must be checked, never silently marked completed.
      const missing = [...this.active.entries()].filter(([id, entry]) => !present.has(id) && available(entry.thread)).sort((a, b) => a[1].seenAt - b[1].seenAt).slice(0, 8);
      const reads = await Promise.allSettled(missing.map(async ([id, entry]) => {
        const thread = await this.client.read(entry.thread); if (this.stopped) return;
        if (thread?.id !== entry.thread.id) { unconfirmed = true; return; }
        const active = workStatus(thread);
        if (active === true) entry.seenAt = this.clock(); else if (active === false) this.active.delete(id);
        else unconfirmed = true;
      }));
      if (this.stopped) return;
      this.lastSuccessAt = this.clock(); this.status = unavailableSources.size || unavailableHosts.size || unconfirmed || reads.some(result => result.status === 'rejected') ? 'partial' : 'connected';
    } catch { if (this.stopped) return; this.status = 'unavailable'; }
    this.expire(); this.publish();
  }
  expire() { const now = this.clock(); for (const [id, entry] of this.active) if (now - entry.seenAt >= this.staleMs) this.active.delete(id); }
  publish() { try { this.onState({activeCount: this.active.size, status: this.status, lastSuccessAt: this.lastSuccessAt || null, discoveryLimit: this.snapshotLimit}); } catch {} }
  stop() { this.stopped = true; if (this.timer) clearInterval(this.timer); this.timer = null; this.client.stop?.(); this.active.clear(); this.status = 'stopped'; this.publish(); }
}

export function startDesktopWorkSource({root, codexHome, onState}) {
  let config; try { config = readJson(path.join(root, 'installation.json')); } catch { return null; }
  if (typeof config.dataDir !== 'string' || !path.isAbsolute(config.dataDir)) return null;
  captureDesktopWorkContext(root);
  const client = new DesktopAppStatusClient({dataDir: config.dataDir, codexHome, nodePath: config.nodePath || process.execPath});
  const tracker = new DesktopWorkTracker({client, onState: state => {
    try { writeJson(path.join(config.dataDir, 'cloud-work-status.json'), {...state, observedAt: Date.now(), staleAfterMs: 60000, pollIntervalMs: 5000}); } catch {}
    onState(state);
  }}); tracker.start(); return tracker;
}
