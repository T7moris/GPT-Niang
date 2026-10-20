import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {randomUUID} from 'node:crypto';

const app = process.env.GPT_NIANG_WORKER_TEST_SOURCE || fileURLToPath(new URL('../', import.meta.url));
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const read = file => { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; } };

async function fixture(t, parentPid = process.pid, inheritStop = true, watchFixture = null, holdQuota = false) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'niang-worker-stop-'));
  fs.cpSync(path.join(app, 'runtime'), path.join(root, 'runtime'), {recursive: true});
  fs.cpSync(path.join(app, '.codex-plugin'), path.join(root, '.codex-plugin'), {recursive: true});
  if (watchFixture) fs.copyFileSync(watchFixture, path.join(root, 'runtime', 'watch.mjs'));
  // Stub only the quota service boundary. Actual ownership, heartbeat, parent
  // liveness, stop detection and cleanup all run in the real worker process.
  fs.renameSync(path.join(root, 'runtime', 'usage.mjs'), path.join(root, 'runtime', 'usage-real.mjs'));
  fs.writeFileSync(path.join(root, 'runtime', 'usage.mjs'), `
    import fs from 'node:fs';
    export {atomicJson,resolveCodexExecutable} from './usage-real.mjs';
    export async function readUsage() {
      if(${holdQuota})while(!fs.existsSync(${JSON.stringify(path.join(root, 'release-query.flag'))}))await new Promise(resolve=>setTimeout(resolve,20));
      return {ok:false,queryOk:false,error:'fixture',windows:[],clearPrevious:true};
    }
  `);
  const dataDir = path.join(root, 'state'); fs.mkdirSync(dataDir);
  const stop = path.join(dataDir, 'stop.flag'), initial = 'previous-session:' + randomUUID();
  fs.writeFileSync(stop, initial);
  const config = path.join(root, 'installation.json');
  fs.writeFileSync(config, JSON.stringify({dataDir, codexPath: process.execPath}));
  const args = [path.join(root, 'runtime', 'watch.mjs'), config, String(parentPid)];
  if (inheritStop) args.push('--inherit-stop');
  const child = spawn(process.execPath, args, {stdio: ['ignore', 'ignore', 'pipe']});
  let result, diagnostic = '';
  child.stderr.on('data', bytes => { diagnostic += bytes; });
  const exited = new Promise(resolve => {
    child.once('error', error => { result = {error}; resolve(result); });
    child.once('close', (code, signal) => { result = {code, signal}; resolve(result); });
  });
  t.after(async () => {
    if (!result) { child.kill(); await exited; }
    assert.equal(path.dirname(path.resolve(root)), path.resolve(os.tmpdir()));
    assert.ok(path.basename(root).startsWith('niang-worker-stop-'));
    fs.rmSync(root, {recursive: true, force: true});
  });
  const healthFile = path.join(dataDir, 'worker-status.json'), ownerFile = path.join(dataDir, 'worker.lock');
  const deadline = Date.now() + 7000;
  let health;
  while (Date.now() < deadline && !result) {
    health = read(healthFile);
    if (health?.pid === child.pid) break;
    await pause(20);
  }
  assert.equal(health?.pid, child.pid, diagnostic);
  return {root, dataDir, stop, initial, child, healthFile, ownerFile, exited, result: () => result};
}

async function stopped(worker) {
  let timer;
  const result = await Promise.race([worker.exited, new Promise(resolve => { timer = setTimeout(() => resolve({timeout: true}), 4500); })]);
  clearTimeout(timer);
  assert.equal(result.code, 0, JSON.stringify(result));
  assert.equal(fs.existsSync(worker.healthFile), false);
  assert.equal(fs.existsSync(worker.ownerFile), false);
}

test('Mac resume option lets a GUI-owned worker inherit a stop request without deleting it', {timeout: 15000}, async t => {
  const worker = await fixture(t), first = read(worker.healthFile).at;
  await pause(1300);
  assert.equal(worker.result(), undefined, 'A request from before this worker started must not stop the new session.');
  assert.ok(read(worker.healthFile)?.at > first);
  assert.equal(fs.readFileSync(worker.stop, 'utf8'), worker.initial);
});

test('GUI-owned worker still honors a new stop request and preserves the requester file', {timeout: 15000}, async t => {
  const worker = await fixture(t), token = 'new-stop:' + randomUUID();
  fs.writeFileSync(worker.stop, token);
  await stopped(worker);
  assert.equal(fs.readFileSync(worker.stop, 'utf8'), token);
});

test('default GUI startup retains the existing Windows inherited-stop behavior', {timeout: 15000}, async t => {
  const worker = await fixture(t, process.pid, false);
  await stopped(worker);
  assert.equal(fs.readFileSync(worker.stop, 'utf8'), worker.initial);
});

test('same-content stop request with a different timestamp remains a new request', {timeout: 15000}, async t => {
  const worker = await fixture(t);
  const later = new Date(Date.now() + 2000);
  fs.utimesSync(worker.stop, later, later);
  await stopped(worker);
  assert.equal(fs.readFileSync(worker.stop, 'utf8'), worker.initial);
});

test('headless worker retains inherited-request and new-request behavior', {timeout: 15000}, async t => {
  const worker = await fixture(t, 0);
  await pause(1300);
  assert.equal(worker.result(), undefined);
  const token = 'headless-stop:' + randomUUID(); fs.writeFileSync(worker.stop, token);
  await stopped(worker);
  assert.equal(fs.readFileSync(worker.stop, 'utf8'), token);
});

test('GUI-owned worker still exits when its parent dies even with an inherited stop request', {timeout: 15000}, async t => {
  const parent = spawn(process.execPath, ['-e', 'setInterval(()=>{},1000)'], {stdio: 'ignore'});
  let parentDone = false;
  const parentExited = new Promise(resolve => { parent.once('close', () => { parentDone = true; resolve(); }); });
  t.after(async () => { if (!parentDone) { parent.kill(); await parentExited; } });
  const worker = await fixture(t, parent.pid);
  parent.kill(); await parentExited;
  await stopped(worker);
  assert.equal(fs.readFileSync(worker.stop, 'utf8'), worker.initial);
});

test('Mac handoff compatibility token stops only its matching owner', {timeout: 15000}, async t => {
  const worker = await fixture(t, 0), owner = read(worker.ownerFile);
  const token = 'worker-handoff:' + owner.token + ':' + randomUUID();
  fs.writeFileSync(worker.stop, token);
  await stopped(worker);
  assert.equal(fs.readFileSync(worker.stop, 'utf8'), token);
});

test('late Mac compatibility request cannot stop a different newly started owner', {timeout: 15000}, async t => {
  const worker = await fixture(t, 0), first = read(worker.healthFile).at;
  fs.writeFileSync(worker.stop, 'worker-handoff:' + randomUUID() + ':' + randomUUID());
  await pause(1300);
  assert.equal(worker.result(), undefined);
  assert.ok(read(worker.healthFile)?.at > first);
  fs.writeFileSync(worker.stop, 'ordinary-stop:' + randomUUID());
  await stopped(worker);
});

test('Mac private handoff request stops its owner and cleans only its private request', {timeout: 15000}, async t => {
  const worker = await fixture(t, 0), owner = read(worker.ownerFile);
  const request = path.join(worker.dataDir, 'worker-handoff-' + owner.token + '.flag');
  fs.writeFileSync(request, randomUUID(), {flag: 'wx'});
  await stopped(worker);
  assert.equal(fs.existsSync(request), false);
  assert.equal(fs.readFileSync(worker.stop, 'utf8'), worker.initial);
});

test('Mac worker ignores and preserves private requests belonging to another owner', {timeout: 15000}, async t => {
  const worker = await fixture(t, 0);
  const other = path.join(worker.dataDir, 'worker-handoff-' + randomUUID() + '.flag'), token = randomUUID();
  fs.writeFileSync(other, token, {flag: 'wx'});
  await pause(1300);
  assert.equal(worker.result(), undefined);
  assert.equal(read(worker.healthFile).handoffProtocol, 1);
  fs.writeFileSync(worker.stop, 'ordinary-stop:' + randomUUID());
  await stopped(worker);
  assert.equal(fs.readFileSync(other, 'utf8'), token);
});

test('released v1.3.4 headless loop accepts the targeted compatibility stop token', {timeout: 15000}, async t => {
  const worker = await fixture(t, 0, false, new URL('./fixtures/watch-v1.3.4.mjs', import.meta.url));
  const owner = read(worker.ownerFile);
  assert.equal(read(worker.healthFile).version, undefined);
  assert.equal(read(worker.healthFile).handoffProtocol, undefined);
  const token = 'worker-handoff:' + owner.token + ':' + randomUUID();
  fs.writeFileSync(worker.stop, token);
  await stopped(worker);
  assert.equal(fs.readFileSync(worker.stop, 'utf8'), token);
});

// On macOS the handoff protocol is always enabled (see watch.mjs), so this
// Windows-only compatibility token is intentionally interpreted as a handoff
// request there. Keep the assertion for the platform that has the mode.
test('default Windows mode keeps ordinary interpretation of compatibility tokens', {skip: process.platform === 'darwin', timeout: 15000}, async t => {
  const worker = await fixture(t, process.pid, false);
  assert.equal(read(worker.healthFile).handoffProtocol, undefined);
  fs.writeFileSync(worker.stop, 'worker-handoff:' + randomUUID() + ':' + randomUUID());
  await stopped(worker);
});

test('Mac private handoff finishes its query and replacement serves queued requests', {timeout: 20000}, async t => {
  const worker = await fixture(t, process.pid, true, null, true);
  const deadline = Date.now() + 4000;
  while (Date.now() < deadline && read(worker.healthFile)?.busy !== true && !worker.result()) await pause(20);
  assert.equal(read(worker.healthFile)?.busy, true);
  const owner = read(worker.ownerFile), request = path.join(worker.dataDir, 'worker-handoff-' + owner.token + '.flag');
  fs.writeFileSync(request, randomUUID(), {flag: 'wx'});
  const id = randomUUID(), queue = path.join(worker.dataDir, 'refresh-requests');
  fs.mkdirSync(queue, {recursive: true});
  const queued = path.join(queue, id + '.json');
  fs.writeFileSync(queued, JSON.stringify({id, at: Date.now(), expiresAt: Date.now() + 45000}));
  await pause(1100);
  assert.equal(worker.result(), undefined, 'An in-flight quota query must finish before private handoff exits.');
  assert.equal(read(worker.healthFile)?.busy, true);
  fs.writeFileSync(path.join(worker.root, 'release-query.flag'), 'release');
  await stopped(worker);
  assert.equal(fs.existsSync(request), false);
  assert.equal(fs.readFileSync(worker.stop, 'utf8'), worker.initial);
  assert.equal(fs.existsSync(queued), true, 'Unstarted requests must remain queued for the next owner.');

  const child = spawn(process.execPath, [path.join(worker.root, 'runtime', 'watch.mjs'), path.join(worker.root, 'installation.json'), '0', '--inherit-stop'], {stdio: 'ignore'});
  let result;
  const exited = new Promise(resolve => {
    child.once('error', error => { result = {error}; resolve(result); });
    child.once('close', (code, signal) => { result = {code, signal}; resolve(result); });
  });
  try {
    const resultFile = path.join(worker.dataDir, 'refresh-results', id + '.json'), resultDeadline = Date.now() + 6500;
    while (Date.now() < resultDeadline && !read(resultFile) && !result) await pause(20);
    assert.equal(read(resultFile)?.requestId, id);
    assert.equal(fs.existsSync(queued), false);
    const replacementOwner = read(worker.ownerFile);
    assert.equal(replacementOwner.pid, child.pid);
    assert.notEqual(replacementOwner.token, owner.token);
    const nextRequest = path.join(worker.dataDir, 'worker-handoff-' + replacementOwner.token + '.flag');
    fs.writeFileSync(nextRequest, randomUUID(), {flag: 'wx'});
    await stopped({exited, healthFile: worker.healthFile, ownerFile: worker.ownerFile});
    assert.equal(fs.existsSync(nextRequest), false);
    assert.equal(fs.readFileSync(worker.stop, 'utf8'), worker.initial);
  } finally {
    if (!result) { child.kill(); await exited; }
  }
});
