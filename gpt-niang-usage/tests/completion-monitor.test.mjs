import test from 'node:test';
import assert from 'node:assert/strict';
import {parseCompletionRecord} from '../runtime/completion-monitor.mjs';

test('successful completion carries the animation signal and keeps its message', () => {
  const result = parseCompletionRecord({
    type: 'event_msg',
    payload: {type: 'turn_complete', turn_id: 'ok', last_agent_message: 'Ready'},
  }, {sessionId: 'session'});

  assert.equal(result.success, true);
  assert.equal(result.eventType, 'turn_complete');
  assert.equal(result.message, 'Codex 已完成：Ready');
  assert.equal(result.turnId, 'ok');
});

test('aborted and errored turns keep text notifications without signaling success', () => {
  for (const payload of [
    {type: 'turn_aborted', turn_id: 'aborted'},
    {type: 'task_complete', turn_id: 'error', error: {message: 'failed'}},
  ]) {
    const result = parseCompletionRecord({type: 'event_msg', payload}, {sessionId: 'session'});
    assert.equal(result.success, false);
    assert.equal(result.message, '本轮已结束');
  }
});

test('terminal-event de-duplication applies to animation and text together', () => {
  const seenTurns = new Set();
  const record = {type: 'event_msg', payload: {type: 'turn_complete', turn_id: 'one'}};

  assert.ok(parseCompletionRecord(record, {sessionId: 'session', seenTurns}));
  assert.equal(parseCompletionRecord(record, {sessionId: 'session', seenTurns}), null);
});
