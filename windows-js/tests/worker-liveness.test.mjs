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

test('owned Mac-protocol worker keeps a fresh heartbeat during a long failed quota query', {timeout: 25000}, async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'niang-worker-liveness-'));
  fs.cpSync(path.join(app, 'runtime'), path.join(root, 'runtime'), {recursive: true});
  fs.cpSync(path.join(app, '.codex-plugin'), path.join(root, '.codex-plugin'), {recursive: true});
  const dataDir = path.join(root, 'state'); fs.mkdirSync(dataDir);
  const release = path.join(root, 'release-query.flag');
  fs.renameSync(path.join(root, 'runtime', 'usage.mjs'), path.join(root, 'runtime', 'usage-real.mjs'));
  // Only the quota service is simulated. Ownership, async queue, heartbeat,
  // snapshot persistence and stop handling are the actual runtime modules.
  fs.writeFileSync(path.join(root, 'runtime', 'usage.mjs'), `
    import fs from 'node:fs';
    export {atomicJson,resolveCodexExecutable} from './usage-real.mjs';
    export async function readUsage() {
      while(!fs.existsSync(${JSON.stringify(release)}))await new Promise(resolve=>setTimeout(resolve,20));
      return {ok:false,queryOk:false,error:'fixture-not-logged-in',windows:[],clearPrevious:true};
    }
  `);
  const config = path.join(root, 'installation.json');
  fs.writeFileSync(config, JSON.stringify({dataDir, codexPath: process.execPath}));
  const child = spawn(process.execPath, [path.join(root, 'runtime', 'watch.mjs'), config, String(process.pid), '--inherit-stop'], {stdio: ['ignore', 'ignore', 'pipe']});
  let result, diagnostic = '';
  child.stderr.on('data', bytes => { diagnostic += bytes; });
  const exited = new Promise(resolve => {
    child.once('error', error => { result = {error}; resolve(result); });
    child.once('close', (code, signal) => { result = {code, signal}; resolve(result); });
  });
  t.after(async () => {
    if (!result) { child.kill(); await exited; }
    assert.equal(path.dirname(path.resolve(root)), path.resolve(os.tmpdir()));
    assert.ok(path.basename(root).startsWith('niang-worker-liveness-'));
    fs.rmSync(root, {recursive: true, force: true});
  });
  const healthFile = path.join(dataDir, 'worker-status.json'), ownerFile = path.join(dataDir, 'worker.lock');
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline && !result) {
    if (read(healthFile)?.busy === true) break;
    await pause(20);
  }
  const owner = read(ownerFile); assert.equal(owner?.pid, child.pid, diagnostic);
  let last = read(healthFile)?.at, advanced = 0;
  const until = Date.now() + 11500;
  while (Date.now() < until) {
    await pause(200);
    assert.equal(result, undefined, diagnostic);
    const health = read(healthFile);
    assert.equal(health?.token, owner.token); assert.equal(health.pid, child.pid);
    assert.equal(health.parentPid, process.pid); assert.equal(health.handoffProtocol, 1);
    assert.equal(health.busy, true);
    assert.ok(Date.now() - health.at >= 0 && Date.now() - health.at < 5000, 'Slow quota query must not stop the independent heartbeat.');
    if (health.at > last) { advanced++; last = health.at; }
  }
  assert.ok(advanced >= 9, `Only ${advanced} heartbeat advances during the held query.`);
  fs.writeFileSync(release, 'release');
  const settled = Date.now() + 4500;
  while (Date.now() < settled && !result) {
    if (read(healthFile)?.busy === false && read(path.join(dataDir, 'status.json'))?.error === 'fixture-not-logged-in') break;
    await pause(20);
  }
  assert.equal(read(healthFile)?.busy, false);
  assert.equal(read(path.join(dataDir, 'status.json'))?.queryOk, false);
  assert.equal(result, undefined, diagnostic);
  const stop = path.join(dataDir, 'stop.flag'), token = randomUUID(); fs.writeFileSync(stop, token, {flag: 'wx'});
  let timer;
  const stopped = await Promise.race([exited, new Promise(resolve => { timer = setTimeout(() => resolve({timeout: true}), 4500); })]);
  clearTimeout(timer);
  assert.equal(stopped.code, 0, diagnostic || JSON.stringify(stopped));
  assert.equal(fs.existsSync(healthFile), false); assert.equal(fs.existsSync(ownerFile), false);
  assert.equal(fs.readFileSync(stop, 'utf8'), token);
});
