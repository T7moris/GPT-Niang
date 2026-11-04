import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

export const MAX_WAVE_BYTES = 10 * 1024 * 1024;
export class WaveError extends Error {
  constructor(code) { super(code); this.code = code; }
}
const fail = code => { throw new WaveError(code); };
const pcmGuid = '0100000000001000800000aa00389b71';
const floatGuid = '0300000000001000800000aa00389b71';

// Decode only bounded, uncompressed RIFF audio. No installed codecs are used.
export function normalizeWave(bytes) {
  if (bytes.length > MAX_WAVE_BYTES) fail('too_large');
  if (bytes.length < 12 || bytes.toString('ascii', 0, 4) !== 'RIFF' || bytes.toString('ascii', 8, 12) !== 'WAVE') fail('invalid');
  if (bytes.readUInt32LE(4) + 8 !== bytes.length) fail('invalid');
  let fmt, data;
  let offset = 12;
  while (offset < bytes.length) {
    if (offset + 8 > bytes.length) fail('invalid');
    const tag = bytes.toString('ascii', offset, offset + 4), size = bytes.readUInt32LE(offset + 4);
    const start = offset + 8, end = start + size;
    if (end + (size & 1) > bytes.length) fail('invalid');
    if (tag === 'fmt ') { if (fmt) fail('invalid'); fmt = bytes.subarray(start, end); }
    if (tag === 'data') { if (data) fail('invalid'); data = bytes.subarray(start, end); }
    offset = end + (size & 1);
  }
  if (!fmt || fmt.length < 16 || !data || !data.length) fail('invalid');
  let format = fmt.readUInt16LE(0);
  const channels = fmt.readUInt16LE(2), sampleRate = fmt.readUInt32LE(4);
  const byteRate = fmt.readUInt32LE(8), align = fmt.readUInt16LE(12), bits = fmt.readUInt16LE(14);
  let validBits = bits;
  if (format === 0xfffe) {
    if (fmt.length < 40 || fmt.readUInt16LE(16) < 22 || fmt.length < 18 + fmt.readUInt16LE(16)) fail('invalid');
    validBits = fmt.readUInt16LE(18);
    const mask = fmt.readUInt32LE(20), guid = fmt.subarray(24, 40).toString('hex');
    if (guid === pcmGuid) format = 1;
    else if (guid === floatGuid) format = 3;
    else fail('unsupported');
    if (mask !== 0 && mask !== (channels === 1 ? 4 : 3)) fail('unsupported');
  } else if (fmt.length !== 16 && (fmt.length < 18 || fmt.length < 18 + fmt.readUInt16LE(16))) fail('invalid');
  if (![1, 2].includes(channels) || sampleRate < 8000 || sampleRate > 192000) fail('unsupported');
  if (!((format === 1 && [8, 16, 24, 32].includes(bits)) || (format === 3 && bits === 32))) fail('unsupported');
  if (validBits < 1 || validBits > bits || (format === 3 && validBits !== 32)) fail('invalid');
  if (align !== channels * bits / 8 || byteRate !== sampleRate * align || data.length % align) fail('invalid');
  const frames = data.length / align;
  if (frames > sampleRate * 5) fail('too_long');
  const output = Buffer.alloc(44 + frames * channels * 2);
  output.write('RIFF', 0); output.writeUInt32LE(output.length - 8, 4); output.write('WAVEfmt ', 8);
  output.writeUInt32LE(16, 16); output.writeUInt16LE(1, 20); output.writeUInt16LE(channels, 22);
  output.writeUInt32LE(sampleRate, 24); output.writeUInt32LE(sampleRate * channels * 2, 28);
  output.writeUInt16LE(channels * 2, 32); output.writeUInt16LE(16, 34);
  output.write('data', 36); output.writeUInt32LE(output.length - 44, 40);
  const width = bits / 8, unused = bits - validBits;
  for (let i = 0, j = 44; i < data.length; i += width, j += 2) {
    let sample;
    if (format === 3) {
      const value = data.readFloatLE(i);
      if (!Number.isFinite(value)) fail('invalid');
      sample = value <= -1 ? -32768 : Math.min(1, value) * 32767;
    } else {
      const value = bits === 8 ? data[i] : data.readIntLE(i, width);
      if (unused && value % 2 ** unused !== 0) fail('invalid');
      sample = bits === 8 ? (value - 128) * 256 : value / 2 ** (bits - 16);
    }
    const rounded = sample < 0 ? -Math.round(-sample) : Math.round(sample);
    output.writeInt16LE(Math.max(-32768, Math.min(32767, rounded)), j);
  }
  return {bytes: output, frames, sampleRate, channels, duration: frames / sampleRate};
}

export function importWave(source, target) {
  let fd;
  try {
    fd = fs.openSync(source, 'r');
    const size = fs.fstatSync(fd).size;
    if (size > MAX_WAVE_BYTES) fail('too_large');
    if (size < 12) fail('invalid');
    const bytes = Buffer.alloc(size);
    let read = 0;
    while (read < size) { const n = fs.readSync(fd, bytes, read, size - read, null); if (!n) fail('invalid'); read += n; }
    if (fs.fstatSync(fd).size !== size) fail('invalid');
    const normalized = normalizeWave(bytes);
    // The caller owns a unique target and commits preferences only after preload.
    fs.writeFileSync(target, normalized.bytes, {flag: 'wx', mode: 0o600});
    return {ok: true, frames: normalized.frames, sampleRate: normalized.sampleRate, channels: normalized.channels, duration: normalized.duration};
  } catch (error) {
    if (error instanceof WaveError) throw error;
    throw new WaveError('io');
  } finally { if (fd !== undefined) fs.closeSync(fd); }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv.length !== 4) fail('invalid');
    console.log(JSON.stringify(importWave(process.argv[2], process.argv[3])));
  } catch (error) { console.log(JSON.stringify({ok: false, error: error.code ?? 'invalid'})); process.exitCode = 1; }
}
