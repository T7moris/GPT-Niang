import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {makeWave} from './wave-fixtures.mjs';
import {normalizeWave, importWave, MAX_WAVE_BYTES} from '../runtime/audio-import.mjs';

const rejects = (bytes, code = 'invalid') => assert.throws(() => normalizeWave(bytes), error => error.code === code);
test('integer PCM at each bit depth normalizes peaks, silence and rounding without overflow', () => {
  for (const bits of [8, 16, 24, 32]) for (const extensible of [false, true]) {
    const max = 2 ** (bits - 1) - 1, min = -(2 ** (bits - 1));
    const values = bits === 8 ? [0, 128, 255] : [min, 0, max];
    const out = normalizeWave(makeWave({bits, extensible, frames: 3, values}));
    assert.equal(out.bytes.readInt16LE(44), -32768);
    assert.equal(out.bytes.readInt16LE(46), 0);
    assert.equal(out.bytes.readInt16LE(48), bits === 8 ? 32512 : 32767);
    assert.equal(out.bytes.readUInt16LE(20), 1); assert.equal(out.bytes.readUInt16LE(34), 16);
    assert.equal(out.frames, 3);
  }
});
test('16-bit audio remains sample-exact and metadata padding is handled', () => {
  const input = makeWave({frames: 5, values: [-32768, -2, 0, 1, 32767], metadata: true});
  const result = normalizeWave(input);
  assert.deepEqual(result.bytes.subarray(44), input.subarray(input.length - 10));
});
test('float WAV and extensible float saturate peaks and reject non-finite samples', () => {
  for (const extensible of [false, true]) {
    const result = normalizeWave(makeWave({format: 3, bits: 32, extensible, frames: 5, values: [-2, -0.5, 0, 0.5, 2]}));
    assert.deepEqual(Array.from({length: 5}, (_, i) => result.bytes.readInt16LE(44 + i * 2)), [-32768, -16384, 0, 16384, 32767]);
    for (const value of [NaN, Infinity, -Infinity]) rejects(makeWave({format: 3, bits: 32, extensible, values: [value]}));
  }
});
test('extensible valid-bit alignment and GUID are checked', () => {
  normalizeWave(makeWave({bits: 32, extensible: true, validBits: 24, values: [-2147483648, 0, 2147483392]}));
  rejects(makeWave({bits: 32, extensible: true, validBits: 24, values: [1]}));
  rejects(makeWave({bits: 16, extensible: true, validBits: 17}));
  const bad = makeWave({extensible: true}); bad[44] = 99; rejects(bad, 'unsupported');
});
test('five-second boundary uses frame count at every sample rate and channel count', () => {
  for (const sampleRate of [8000, 11025, 44100, 48000, 96000, 192000]) for (const channels of [1, 2]) {
    for (const delta of [-1, 0]) assert.equal(normalizeWave(makeWave({sampleRate, channels, frames: sampleRate * 5 + delta})).frames, sampleRate * 5 + delta);
    rejects(makeWave({sampleRate, channels, frames: sampleRate * 5 + 1}), 'too_long');
  }
});
test('five-second 192k stereo 32-bit file above the old 2MB cap is accepted', () => {
  const input = makeWave({sampleRate: 192000, channels: 2, bits: 32, frames: 960000});
  assert.ok(input.length > 2 * 1024 * 1024); assert.equal(normalizeWave(input).duration, 5);
});
test('malformed headers, false byte rates, bad alignment, truncation and empty audio fail', () => {
  rejects(Buffer.from('not audio')); rejects(makeWave({frames: 0}));
  for (const [offset, value, width] of [[4, 1, 4], [28, 1, 4], [32, 3, 2]]) {
    const bad = makeWave(); bad.writeUIntLE(value, offset, width); rejects(bad);
  }
  const input = makeWave(); rejects(input.subarray(0, input.length - 1));
  const odd = Buffer.concat([input, Buffer.from([1])]); odd.writeUInt32LE(odd.length - 8, 4); rejects(odd);
  const duplicate = Buffer.concat([input, input.subarray(12, 36)]); duplicate.writeUInt32LE(duplicate.length - 8, 4); rejects(duplicate);
});
test('unsupported encodings, channels, rates and oversized input fail explicitly', () => {
  for (const format of [2, 6, 7]) { const bad = makeWave(); bad.writeUInt16LE(format, 20); rejects(bad, 'unsupported'); }
  rejects(makeWave({channels: 3}), 'unsupported'); rejects(makeWave({sampleRate: 7999}), 'unsupported');
  rejects(makeWave({sampleRate: 192001}), 'unsupported'); rejects(Buffer.alloc(MAX_WAVE_BYTES + 1), 'too_large');
});
test('file import preserves source, never overwrites a target, and CLI reports bounded reasons', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'gpt-wave-'));
  try {
    const source = path.join(directory, '中文 source.wav'), target = path.join(directory, 'cache.wav');
    const original = makeWave({bits: 24}); fs.writeFileSync(source, original);
    assert.equal(importWave(source, target).ok, true); assert.deepEqual(fs.readFileSync(source), original);
    assert.throws(() => importWave(source, target), error => error.code === 'io');
    const cli = fileURLToPath(new URL('../runtime/audio-import.mjs', import.meta.url));
    fs.writeFileSync(source, makeWave({frames: 40001}));
    const result = spawnSync(process.execPath, [cli, source, path.join(directory, 'rejected.wav')], {encoding: 'utf8'});
    assert.equal(result.status, 1); assert.deepEqual(JSON.parse(result.stdout), {ok: false, error: 'too_long'});
    assert.equal(fs.existsSync(path.join(directory, 'rejected.wav')), false);
  } finally { fs.rmSync(directory, {recursive: true, force: true}); }
});
