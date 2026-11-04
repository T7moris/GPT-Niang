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

test('real worker publishes its bundled version and fresh matching heartbeat without changing stop cleanup', {timeout: 15000}, async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'niang-worker-health-'));
  fs.cpSync(path.join(app, 'runtime'), path.join(root, 'runtime'), {recursive: true});
  fs.cpSync(path.join(app, '.codex-plugin'), path.join(root, '.codex-plugin'), {recursive: true});
  const dataDir = path.join(root, 'state'); fs.mkdirSync(dataDir);
  const config = path.join(root, 'installation.json');
  // A headless idle worker never launches the quota CLI or reads a real account.
  fs.writeFileSync(config, JSON.stringify({dataDir, codexPath: process.execPath}));
  const child = spawn(process.execPath, [path.join(root, 'runtime', 'watch.mjs'), config, '0'], {stdio: ['ignore', 'ignore', 'pipe']});
  let result, diagnostic = '';
  child.stderr.on('data', bytes => { diagnostic += bytes; });
  const exited = new Promise(resolve => {
    child.once('error', error => { result = {error}; resolve(result); });
    child.once('close', (code, signal) => { result = {code, signal}; resolve(result); });
  });
  t.after(async () => {
    if (!result) { child.kill(); await exited; }
    const resolved = path.resolve(root), temporary = path.resolve(os.tmpdir());
    assert.equal(path.dirname(resolved), temporary);
    assert.ok(path.basename(resolved).startsWith('niang-worker-health-'));
    fs.rmSync(resolved, {recursive: true, force: true});
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
  assert.equal(health.version, read(path.join(root, '.codex-plugin', 'plugin.json')).version);
  const owner = read(ownerFile);
  assert.equal(health.token, owner.token);
  assert.equal(health.pid, owner.pid);
  assert.equal(health.parentPid, 0);
  assert.equal(health.busy, false);
  assert.ok(Date.now() - health.at >= 0 && Date.now() - health.at < 5000);
  const first = health.at, nextDeadline = Date.now() + 4000;
  while (Date.now() < nextDeadline && !result) {
    health = read(healthFile);
    if (health?.at > first) break;
    await pause(20);
  }
  assert.ok(health?.at > first, 'The existing one-second heartbeat must keep advancing.');
  assert.equal(health.version, read(path.join(root, '.codex-plugin', 'plugin.json')).version);
  const token = 'health-test-stop:' + randomUUID(), stop = path.join(dataDir, 'stop.flag');
  fs.writeFileSync(stop, token, {flag: 'wx'});
  let timer;
  const stopped = await Promise.race([exited, new Promise(resolve => { timer = setTimeout(() => resolve({timeout: true}), 5000); })]);
  clearTimeout(timer);
  assert.equal(stopped.code, 0, diagnostic || JSON.stringify(stopped));
  assert.equal(fs.existsSync(healthFile), false);
  assert.equal(fs.existsSync(ownerFile), false);
  assert.equal(fs.readFileSync(stop, 'utf8'), token);
});
