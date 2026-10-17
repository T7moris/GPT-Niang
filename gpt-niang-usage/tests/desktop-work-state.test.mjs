import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {captureDesktopWorkContext, findAppToolsServer, DesktopAppStatusClient, DesktopWorkTracker} from '../runtime/desktop-work-state.mjs';

const caller = '00000000-0000-4000-8000-000000000001';
const pipe = '\\\\.\\pipe\\gpt-niang-test';
const chat = (id, status = 'active', extras = {}) => ({id, kind: 'chatgpt', status, ...extras});
const snapshot = (threads, extras = {}) => ({schemaVersion: 4, pinnedThreads: [], threads, unavailableSources: [], unavailableHosts: [], ...extras});
function trackerFixture() {
  let now = 1000, current = snapshot([]), readResult = null;
  const states = [], reads = [];
  const client = {async list() { if (current instanceof Error) throw current; return current; }, async read(thread) { reads.push(thread.id); if (readResult instanceof Error) throw readResult; return readResult; }};
  const tracker = new DesktopWorkTracker({client, onState: state => states.push(state), clock: () => now, staleMs: 60000});
  return {tracker, states, reads, setSnapshot: value => {current = value;}, setRead: value => {readResult = value;}, advance: ms => {now += ms;}};
}

test('cloud work is aggregated across projects and clears only when all tasks finish', async () => {
  const f = trackerFixture();
  f.setSnapshot(snapshot([chat('a'), chat('b'), {id: 'local', kind: 'codex', hostId: 'local', status: 'active'}]));
  await f.tracker.poll(); assert.equal(f.states.at(-1).activeCount, 2);
  f.setSnapshot(snapshot([chat('a', 'idle'), chat('b')]));
  await f.tracker.poll(); assert.equal(f.states.at(-1).activeCount, 1);
  f.setSnapshot(snapshot([chat('a', 'idle'), chat('b', 'idle')]));
  await f.tracker.poll(); assert.equal(f.states.at(-1).activeCount, 0);
});
test('cloud code executors and pinned tasks participate; duplicate rows count once', async () => {
  const f = trackerFixture(), remote = {id: 'executor', kind: 'codex', hostId: 'durable', status: 'active'};
  f.setSnapshot(snapshot([remote, chat('p')], {pinnedThreads: [chat('p')]}));
  await f.tracker.poll(); assert.equal(f.states.at(-1).activeCount, 2);
});
test('tasks falling out of the 50-chat listing are read until completion', async () => {
  const f = trackerFixture(); f.setSnapshot(snapshot([chat('long-task')])); await f.tracker.poll();
  f.setSnapshot(snapshot([])); f.setRead({id: 'long-task', status: {type: 'active'}});
  f.advance(30000); await f.tracker.poll(); assert.equal(f.states.at(-1).activeCount, 1);
  f.advance(40000); await f.tracker.poll(); assert.equal(f.states.at(-1).activeCount, 1);
  f.setRead({id: 'long-task', status: {type: 'idle'}}); await f.tracker.poll();
  assert.equal(f.states.at(-1).activeCount, 0); assert.equal(f.reads.length, 3);
});
test('partial and failed sources retain brief outages but expire stale busy state', async () => {
  const f = trackerFixture(); f.setSnapshot(snapshot([chat('a')])); await f.tracker.poll();
  f.advance(10000); f.setSnapshot(snapshot([], {unavailableSources: ['chatgpt']})); await f.tracker.poll();
  assert.equal(f.states.at(-1).status, 'partial'); assert.equal(f.states.at(-1).activeCount, 1);
  f.advance(50000); f.setSnapshot(Error('offline')); await f.tracker.poll();
  assert.equal(f.states.at(-1).status, 'unavailable'); assert.equal(f.states.at(-1).activeCount, 0);
  f.setSnapshot(snapshot([chat('new')])); await f.tracker.poll(); assert.equal(f.states.at(-1).activeCount, 1);
});
test('unrecognized or malformed snapshots never imply a successful idle observation', async () => {
  const f = trackerFixture(); f.setSnapshot(snapshot([chat('a')])); await f.tracker.poll();
  f.setSnapshot({threads: []}); await f.tracker.poll(); assert.equal(f.states.at(-1).activeCount, 1);
  f.setSnapshot(snapshot([chat('a', 'unrecognized')])); await f.tracker.poll(); assert.equal(f.states.at(-1).activeCount, 1);
});
test('polls cannot overlap and stopping clears work without late responses reviving it', async () => {
  let resolve, calls = 0; const states = [];
  const client = {list() { calls++; return new Promise(r => {resolve = r;}); }, stop() {}};
  const tracker = new DesktopWorkTracker({client, onState: state => states.push(state)});
  const a = tracker.poll(), b = tracker.poll(); assert.equal(calls, 1);
  tracker.stop(); resolve(snapshot([chat('a')])); await Promise.all([a, b]);
  assert.equal(states.at(-1).activeCount, 0); assert.equal(states.at(-1).status, 'stopped');
});

async function withHome(run) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'gpt-desktop-work-test-'));
  try { await run(home); } finally { fs.rmSync(home, {recursive: true, force: true}); }
}
function makeServer(home, version = '1.0.0', hang = false) {
  const root = path.join(home, 'plugins/cache/openai-bundled/codex-app-tools', version); fs.mkdirSync(root, {recursive: true});
  fs.writeFileSync(path.join(root, 'server.mjs'), `import readline from 'node:readline';
readline.createInterface({input:process.stdin}).on('line',line=>{const m=JSON.parse(line);if(m.id===undefined)return;let result={};
if(m.method==='tools/list')result={tools:[{name:'list_threads'},{name:'read_thread'}]};
if(m.method==='tools/call'){if(${hang})return;if(m.params._meta.codexThreadId!==${JSON.stringify(caller)})process.exit(2);
const data=m.params.name==='list_threads'?{pinnedThreads:[],threads:[{id:process.env.CODEX_APP_TOOLS_PIPE_PATH,kind:'chatgpt',status:'active'}]}:{thread:{id:m.params.arguments.threadId,status:{type:'idle'}}};result={content:[{type:'text',text:JSON.stringify(data)}]};}
process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:m.id,result})+'\\n');});`);
}
test('context registration uses only app-provided local endpoint and a real caller ID', async () => withHome(async home => {
  const dataDir = path.join(home, 'state'); fs.writeFileSync(path.join(home, 'installation.json'), JSON.stringify({dataDir}));
  assert.equal(captureDesktopWorkContext(home, {}, {}), false);
  assert.equal(captureDesktopWorkContext(home, {}, {CODEX_APP_TOOLS_PIPE_PATH: 'https://remote', CODEX_THREAD_ID: caller}), false);
  assert.equal(captureDesktopWorkContext(home, {}, {CODEX_APP_TOOLS_PIPE_PATH: pipe, CODEX_THREAD_ID: caller}), true);
  assert.equal(captureDesktopWorkContext(home, {}, {CODEX_APP_TOOLS_PIPE_PATH: pipe + '-new'}), true);
  const saved = JSON.parse(fs.readFileSync(path.join(dataDir, 'desktop-work-context.json')));
  assert.equal(saved.callerThreadId, caller); assert.equal(saved.pipePath, pipe + '-new');
  assert.deepEqual(Object.keys(saved).sort(), ['callerThreadId', 'capturedAt', 'pipePath', 'schemaVersion']);
}));
test('bundled MCP protocol, read-only allowlist, version selection, endpoint refresh and shutdown', async () => withHome(async home => {
  const dataDir = path.join(home, 'state'); fs.writeFileSync(path.join(home, 'installation.json'), JSON.stringify({dataDir}));
  makeServer(home, '0.9.0'); makeServer(home, '1.10.0'); makeServer(home, '1.9.0');
  assert.ok(findAppToolsServer(home).includes('1.10.0'));
  captureDesktopWorkContext(home, {}, {CODEX_APP_TOOLS_PIPE_PATH: pipe, CODEX_THREAD_ID: caller});
  const client = new DesktopAppStatusClient({dataDir, codexHome: home});
  try {
    assert.equal((await client.list()).threads[0].id, pipe);
    assert.equal((await client.read({id: 'a', kind: 'chatgpt'})).status.type, 'idle');
    await assert.rejects(client.call('send_message_to_thread', {}), /READ_ONLY/);
    captureDesktopWorkContext(home, {}, {CODEX_APP_TOOLS_PIPE_PATH: pipe + '-restart', CODEX_THREAD_ID: caller});
    assert.equal((await client.list()).threads[0].id, pipe + '-restart');
  } finally { client.stop(); }
  await assert.rejects(client.list(), /SOURCE_STOPPED/);
}));
test('MCP timeouts disconnect and can reconnect without leaving a child or pending request', async () => withHome(async home => {
  const dataDir = path.join(home, 'state'); fs.writeFileSync(path.join(home, 'installation.json'), JSON.stringify({dataDir}));
  makeServer(home, '1.0.0', true); captureDesktopWorkContext(home, {}, {CODEX_APP_TOOLS_PIPE_PATH: pipe, CODEX_THREAD_ID: caller});
  const client = new DesktopAppStatusClient({dataDir, codexHome: home, timeoutMs: 700});
  try { await assert.rejects(client.list(), /TIMEOUT/); assert.equal(client.child, null); assert.equal(client.pending.size, 0);
    makeServer(home); assert.equal((await client.list()).threads.length, 1);
  } finally { client.stop(); }
}));
