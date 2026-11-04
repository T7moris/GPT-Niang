import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {sampleInterval, RolloutCounters, RolloutTail, allowedRollout} from '../runtime/thread-speed.mjs';
const usage = (at, output) => ({timestamp: new Date(at).toISOString(), type: 'event_msg', payload: {type: 'token_count', info: {total_token_usage: {output_tokens: output}}}});
test('interval output average uses counter deltas, including elapsed wait time', () => {
  assert.deepEqual(sampleInterval({at: 1000, outputTokens: 100}, {at: 11000, outputTokens: 400}), {at: 11000, outputTokens: 300, seconds: 10, tokensPerSecond: 30});
  assert.equal(sampleInterval(null, {at: 1000, outputTokens: 1}), null);
  assert.equal(sampleInterval({at: 1000, outputTokens: 5}, {at: 1000, outputTokens: 10}), null);
  assert.equal(sampleInterval({at: 1000, outputTokens: 100}, {at: 2000, outputTokens: 5}), null);
});
test('duplicate quota updates do not shorten the accounting interval', () => {
  const counters = new RolloutCounters();
  counters.accept(usage(1000, 100)); counters.accept(usage(2000, 100)); counters.accept(usage(11000, 400));
  assert.equal(counters.latest.tokensPerSecond, 30);
  counters.accept({type: 'response_item', payload: {text: 'private content'}});
  assert.equal(counters.latest.tokensPerSecond, 30);
});
test('incremental reads tolerate partial lines, truncation, and omit chat content', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'niang-speed-')); t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  const file = path.join(root, 'sample.jsonl'); fs.writeFileSync(file, JSON.stringify(usage(1000, 100)) + '\n');
  const tail = new RolloutTail(file); assert.equal(tail.update().latest, null);
  const next = JSON.stringify(usage(11000, 400)); fs.appendFileSync(file, next.slice(0, 30)); assert.equal(tail.update().latest, null);
  fs.appendFileSync(file, next.slice(30) + '\n'); assert.equal(tail.update().latest.tokensPerSecond, 30);
  fs.writeFileSync(file, JSON.stringify(usage(20000, 5)) + '\n'); assert.equal(tail.update().latest, null);
});
test('paths outside session directories and symlink escapes are rejected', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'niang-path-')); t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  fs.mkdirSync(path.join(root, 'sessions'));
  const file = path.join(root, 'sessions', 'a.jsonl'); fs.writeFileSync(file, '');
  const outside = path.join(root, 'private.jsonl'); fs.writeFileSync(outside, '');
  assert.equal(allowedRollout(file, root), fs.realpathSync(file));
  assert.equal(allowedRollout(outside, root), null);
  if (process.platform !== 'win32') {
    fs.symlinkSync(outside, path.join(root, 'sessions', 'escape.jsonl'));
    assert.equal(allowedRollout(path.join(root, 'sessions', 'escape.jsonl'), root), null);
  }
});

test('a new task excludes overnight human idle time and clears the old speed', () => {
  const counters = new RolloutCounters();
  counters.accept(usage(1000, 100));
  counters.accept({type: 'event_msg', timestamp: new Date(2000).toISOString(), payload: {type: 'task_complete'}});
  counters.accept({type: 'event_msg', timestamp: new Date(86401000).toISOString(), payload: {type: 'task_started'}});
  assert.equal(counters.latest, null);
  counters.accept(usage(86411000, 400));
  assert.equal(counters.latest.tokensPerSecond, 30);
  assert.equal(counters.state, 'running');
});
