import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { healthyWorker } from '../runtime/worker-state.mjs';
import { WorkerStarter } from '../src/core/worker-starter.mjs';

test('a heartbeat written during observation stays healthy and does not start a duplicate worker', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gpt-js-heartbeat-clock-'));
  t.after(() => { assert.equal(path.dirname(path.resolve(dir)), path.resolve(os.tmpdir())); fs.rmSync(dir, { recursive: true, force: true }); });
  const status = path.join(dir, 'worker-status.json');
  const owner = { pid: process.pid, token: 'test-heartbeat' };
  fs.writeFileSync(path.join(dir, 'worker.lock'), JSON.stringify(owner));
  fs.writeFileSync(status, JSON.stringify({ ...owner, at: 1001 }));
  const originalRead = fs.readFileSync, originalNow = Date.now;
  let clock = 1000;
  try {
    Date.now = () => clock;
    fs.readFileSync = (file, ...args) => {
      const value = originalRead(file, ...args);
      if (String(file) === status) clock = 1002;
      return value;
    };
    assert.equal(healthyWorker(dir)?.pid, process.pid);
    clock = 1000;
    let launched = 0;
    const starter = new WorkerStarter({ dataDir: dir, now: () => clock, updating: () => false,
      launch: () => { launched++; throw Error('unexpected duplicate worker'); } });
    starter.ensure();
    assert.equal(launched, 0);
  } finally {
    fs.readFileSync = originalRead;
    Date.now = originalNow;
  }
});
