import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {quoteTokens, renderQuote, cacheQuote} from '../runtime/quote-voice.mjs';

test('custom Chinese/English quotes produce original voiced PCM and stable output', async () => {
  const bytes = await renderQuote('任务完成');
  assert.deepEqual(bytes, fs.readFileSync(new URL('../assets/task-complete.wav', import.meta.url)));
  const mixed = await renderQuote('Hello，今天辛苦啦！');
  assert.equal(mixed.toString('ascii', 0, 4), 'RIFF');
  let peak = 0;
  for (let i = 44; i < mixed.length; i += 2) peak = Math.max(peak, Math.abs(mixed.readInt16LE(i)) / 32768);
  assert.ok(peak > .05 && peak < .99);
  assert.equal(quoteTokens('Hello').filter(t => t.kind === 'vowel').length, 2);
  assert.throws(() => quoteTokens('字'.repeat(201)), /INVALID_QUOTE/);
  await assert.rejects(renderQuote('？！'), /EMPTY_QUOTE/);
});
test('cache repairs corrupt WAVs, contains no quote text and remains bounded', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'quote-voice-test-'));
  try {
    const file = await cacheQuote('你好', root);
    fs.writeFileSync(file, 'broken');
    await cacheQuote('你好', root);
    assert.equal(fs.readFileSync(file).toString('ascii', 0, 4), 'RIFF');
    for (let i = 0; i < 35; i++) await cacheQuote('你好' + i, root);
    const reused = await cacheQuote('你好', root);
    assert.ok(fs.existsSync(reused));
    assert.ok(fs.readdirSync(root).length <= 32);
    assert.ok(fs.readdirSync(root).every(name => /^[a-f0-9]{64}\.wav$/.test(name)));
  } finally { fs.rmSync(root, {recursive: true, force: true}); }
});
test('CLI accepts quoted Unicode through stdin and does not execute its contents', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'quote-voice-cli-'));
  try {
    const text = '你好 " $() ` Hello，星星！';
    const child = spawn(process.execPath, [fileURLToPath(new URL('../runtime/quote-voice.mjs', import.meta.url)), root], {windowsHide: true});
    let out = '', err = '';
    child.stdout.setEncoding('utf8'); child.stdout.on('data', x => out += x);
    child.stderr.setEncoding('utf8'); child.stderr.on('data', x => err += x);
    const exit = new Promise((resolve, reject) => {child.on('error', reject); child.on('exit', resolve);});
    child.stdin.end(JSON.stringify({text}));
    assert.equal(await exit, 0, err);
    assert.equal(path.dirname(JSON.parse(out).file), root);
    assert.deepEqual(fs.readFileSync(JSON.parse(out).file), await renderQuote(text));
  } finally { fs.rmSync(root, {recursive: true, force: true}); }
});
