import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  CompletionMonitor,
  CompletionRolloutTail,
  cleanMessage,
  completionMessage,
  defaultCodexHome,
  listRolloutFiles,
  parseCompletionRecord,
} from '../runtime/completion-monitor.mjs';

function record(type, payload = {}, timestamp = '2026-10-13T00:00:00.000Z') {
  return {type: 'event_msg', timestamp, payload: {type, ...payload}};
}

function sessionMeta(source) {
  return {type: 'session_meta', payload: {source}};
}

function appendRecord(file, value) {
  fs.appendFileSync(file, JSON.stringify(value) + '\n', 'utf8');
}

function withCodexHome(run) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'gpt-niang-completion-'));
  try { run(directory); }
  finally { fs.rmSync(directory, {recursive: true, force: true}); }
}

test('successful completion uses cleaned, bounded final-message excerpt', () => {
  assert.equal(
    completionMessage({last_agent_message: '**已完成**：\n更新了 [气泡](https://example.test)。'}, 'task_complete'),
    'Codex 已完成：已完成： 更新了 气泡。',
  );
  const message = completionMessage({last_agent_message: '龙'.repeat(40)}, 'task_complete');
  assert.equal(message, 'Codex 已完成：' + '龙'.repeat(27) + '…');
  assert.equal(Array.from(message.slice('Codex 已完成：'.length)).length, 28);
});

test('errors, aborts, and absent final messages use generic text', () => {
  assert.equal(completionMessage({last_agent_message: 'secret', error: {message: 'failed'}}, 'task_complete'), '本轮已结束');
  assert.equal(completionMessage({last_agent_message: 'secret'}, 'turn_aborted'), '本轮已结束');
  assert.equal(completionMessage({last_agent_message: null}, 'turn_complete'), 'Codex 本轮已完成');
  assert.equal(completionMessage({last_agent_message: '   `\n`   '}, 'task_complete'), 'Codex 本轮已完成');
});

test('terminal events parse once per session and turn while unrelated records are ignored', () => {
  const seenTurns = new Set();
  const first = record('task_complete', {turn_id: 'turn-1', last_agent_message: 'done'});
  assert.equal(parseCompletionRecord({type: 'response_item', payload: {text: 'private'}}, {sessionId: 'a', seenTurns}), null);
  assert.equal(parseCompletionRecord(record('token_count', {turn_id: 'turn-1'}), {sessionId: 'a', seenTurns}), null);
  assert.equal(parseCompletionRecord(first, {sessionId: 'a', seenTurns}).message, 'Codex 已完成：done');
  assert.equal(parseCompletionRecord(record('turn_complete', {turn_id: 'turn-1'}), {sessionId: 'a', seenTurns}), null);
  assert.equal(parseCompletionRecord(first, {sessionId: 'b', seenTurns}).message, 'Codex 已完成：done');
});

test('message cleanup flattens markdown and whitespace without model calls', () => {
  assert.equal(cleanMessage('## 完成\n\n- **修复** `设置`\n- 第二项'), '完成 修复 设置 第二项');
  assert.equal(cleanMessage('```js\nconst x = 1;\n```'), 'const x = 1;');
});

test('tail buffers partial UTF-8 JSONL records and emits only after the newline', () => {
  withCodexHome(codexHome => {
    const file = path.join(codexHome, 'rollout-one.jsonl');
    fs.writeFileSync(file, '');
    const tail = new CompletionRolloutTail(file, {sessionId: 'one'});
    const line = JSON.stringify(record('task_complete', {turn_id: 'one', last_agent_message: '中文完成'})) + '\n';
    const bytes = Buffer.from(line, 'utf8');
    const split = bytes.indexOf(Buffer.from('完', 'utf8')) + 1;
    fs.appendFileSync(file, bytes.subarray(0, split));
    assert.deepEqual(tail.update(), []);
    fs.appendFileSync(file, bytes.subarray(split));
    assert.deepEqual(tail.update().map(item => item.message), ['Codex 已完成：中文完成']);
    assert.deepEqual(tail.update(), []);
  });
});

test('startup baselines existing sessions, then reports newly appended terminal events', () => {
  withCodexHome(codexHome => {
    const sessions = path.join(codexHome, 'sessions', '2026', '10', '13');
    fs.mkdirSync(sessions, {recursive: true});
    const file = path.join(sessions, 'rollout-a.jsonl');
    appendRecord(file, record('task_complete', {turn_id: 'old', last_agent_message: 'old'}));
    const notifications = [];
    const monitor = new CompletionMonitor({codexHome, intervalMs: 60000, onNotification: item => notifications.push(item)});
    monitor.start();
    try {
      assert.deepEqual(notifications, []);
      appendRecord(file, record('task_complete', {turn_id: 'new', last_agent_message: 'new'}, '2026-10-13T00:00:01.000Z'));
      monitor.scan();
      monitor.scan();
      assert.deepEqual(notifications.map(item => item.message), ['Codex 已完成：new']);
    } finally { monitor.stop(); }
  });
});

test('a new session created after startup can report a fast task', () => {
  withCodexHome(codexHome => {
    fs.mkdirSync(path.join(codexHome, 'sessions'), {recursive: true});
    const notifications = [];
    const monitor = new CompletionMonitor({codexHome, intervalMs: 60000, onNotification: item => notifications.push(item)});
    monitor.start();
    try {
      const file = path.join(codexHome, 'sessions', 'rollout-new.jsonl');
      appendRecord(file, record('task_started', {turn_id: 'fast'}));
      appendRecord(file, record('task_complete', {turn_id: 'fast', last_agent_message: 'fast result'}, '2026-10-13T00:00:01.000Z'));
      monitor.scan();
      assert.deepEqual(notifications.map(item => item.message), ['Codex 已完成：fast result']);
    } finally { monitor.stop(); }
  });
});

test('subagent completion events are ignored while top-level chat events remain eligible', () => {
  withCodexHome(codexHome => {
    const sessions = path.join(codexHome, 'sessions');
    fs.mkdirSync(sessions, {recursive: true});
    const notifications = [];
    const monitor = new CompletionMonitor({codexHome, intervalMs: 60000, onNotification: item => notifications.push(item)});
    monitor.start();
    try {
      const file = path.join(sessions, 'rollout-guardian.jsonl');
      appendRecord(file, sessionMeta({subagent: {other: 'guardian'}}));
      appendRecord(file, record('task_complete', {
        turn_id: 'guardian-turn',
        last_agent_message: '{"risk_level":"medium","user_authorization":"not supplied"}',
      }));
      monitor.scan();
      assert.deepEqual(notifications, []);

      const topLevel = path.join(sessions, 'rollout-user-chat.jsonl');
      appendRecord(topLevel, sessionMeta('codex_work_desktop'));
      appendRecord(topLevel, record('task_complete', {turn_id: 'user-turn', last_agent_message: '任务已经完成'}));
      monitor.scan();
      assert.deepEqual(notifications.map(item => item.message), ['Codex 已完成：任务已经完成']);
    } finally { monitor.stop(); }
  });
});

test('waits for a complete session header before reading a newly created rollout', () => {
  withCodexHome(codexHome => {
    const sessions = path.join(codexHome, 'sessions');
    fs.mkdirSync(sessions, {recursive: true});
    const notifications = [];
    const monitor = new CompletionMonitor({codexHome, intervalMs: 60000, onNotification: item => notifications.push(item)});
    monitor.start();
    try {
      const file = path.join(sessions, 'rollout-partial.jsonl');
      fs.writeFileSync(file, JSON.stringify(sessionMeta({subagent: {other: 'guardian'}})), 'utf8');
      monitor.scan();
      fs.appendFileSync(file, '\n', 'utf8');
      monitor.scan();
      appendRecord(file, record('task_complete', {turn_id: 'partial-guardian', last_agent_message: 'internal'}));
      monitor.scan();
      assert.deepEqual(notifications, []);
    } finally { monitor.stop(); }
  });
});

test('rollout rename from sessions to archived_sessions keeps its offset and dedupe state', () => {
  withCodexHome(codexHome => {
    const active = path.join(codexHome, 'sessions');
    const archived = path.join(codexHome, 'archived_sessions');
    fs.mkdirSync(active, {recursive: true});
    fs.mkdirSync(archived, {recursive: true});
    const file = path.join(active, 'rollout-move.jsonl');
    fs.writeFileSync(file, '');
    const notifications = [];
    const monitor = new CompletionMonitor({codexHome, intervalMs: 60000, onNotification: item => notifications.push(item)});
    monitor.start();
    try {
      appendRecord(file, record('task_complete', {turn_id: 'one', last_agent_message: 'first'}));
      monitor.scan();
      fs.renameSync(file, path.join(archived, path.basename(file)));
      appendRecord(path.join(archived, path.basename(file)), record('task_complete', {turn_id: 'two', last_agent_message: 'second'}, '2026-10-13T00:00:02.000Z'));
      monitor.scan();
      assert.deepEqual(notifications.map(item => item.message), ['Codex 已完成：first', 'Codex 已完成：second']);
    } finally { monitor.stop(); }
  });
});

test('truncation establishes a fresh baseline instead of replaying old records', () => {
  withCodexHome(codexHome => {
    const file = path.join(codexHome, 'rollout-truncate.jsonl');
    appendRecord(file, record('task_complete', {turn_id: 'old', last_agent_message: 'old'}));
    const tail = new CompletionRolloutTail(file, {sessionId: 'truncate', baseline: true});
    fs.writeFileSync(file, '');
    appendRecord(file, record('task_complete', {turn_id: 'old', last_agent_message: 'old'}, '2026-10-13T00:00:01.000Z'));
    assert.deepEqual(tail.update(), []);
    appendRecord(file, record('task_complete', {turn_id: 'new', last_agent_message: 'new'}, '2026-10-13T00:00:02.000Z'));
    assert.deepEqual(tail.update().map(item => item.message), ['Codex 已完成：new']);
  });
});

test('scanner is limited to session rollout folders and resolves default Codex home', () => {
  withCodexHome(codexHome => {
    fs.mkdirSync(path.join(codexHome, 'sessions', 'nested'), {recursive: true});
    fs.mkdirSync(path.join(codexHome, 'archived_sessions'), {recursive: true});
    fs.mkdirSync(path.join(codexHome, 'other'), {recursive: true});
    const active = path.join(codexHome, 'sessions', 'nested', 'active.jsonl');
    const archived = path.join(codexHome, 'archived_sessions', 'archived.jsonl');
    fs.writeFileSync(active, '');
    fs.writeFileSync(archived, '');
    fs.writeFileSync(path.join(codexHome, 'other', 'ignored.jsonl'), '');
    assert.deepEqual(listRolloutFiles(codexHome).sort(), [active, archived].sort());
  });
  assert.equal(defaultCodexHome({CODEX_HOME: 'C:\\codex-home'}), path.resolve('C:\\codex-home'));
});
