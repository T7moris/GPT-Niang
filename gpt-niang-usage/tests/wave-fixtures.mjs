import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

export function makeWave({bits = 16, format = 1, channels = 1, sampleRate = 8000, frames = 80, extensible = false, validBits = bits, values = [0], metadata = false} = {}) {
  const fmt = Buffer.alloc(extensible ? 40 : 16), align = channels * bits / 8;
  fmt.writeUInt16LE(extensible ? 0xfffe : format, 0); fmt.writeUInt16LE(channels, 2);
  fmt.writeUInt32LE(sampleRate, 4); fmt.writeUInt32LE(sampleRate * align, 8);
  fmt.writeUInt16LE(align, 12); fmt.writeUInt16LE(bits, 14);
  if (extensible) {
    fmt.writeUInt16LE(22, 16); fmt.writeUInt16LE(validBits, 18); fmt.writeUInt32LE(channels === 1 ? 4 : 3, 20);
    Buffer.from(format === 3 ? '0300000000001000800000aa00389b71' : '0100000000001000800000aa00389b71', 'hex').copy(fmt, 24);
  }
  const data = Buffer.alloc(frames * align);
  for (let n = 0; n < frames * channels; n++) {
    const value = values[n % values.length], offset = n * bits / 8;
    if (format === 3) data.writeFloatLE(value, offset);
    else if (bits === 8) data.writeUInt8(value, offset);
    else data.writeIntLE(value, offset, bits / 8);
  }
  const chunk = (name, bytes) => { const h = Buffer.alloc(8); h.write(name); h.writeUInt32LE(bytes.length, 4); return Buffer.concat([h, bytes, Buffer.alloc(bytes.length % 2)]); };
  const body = Buffer.concat([Buffer.from('WAVE'), chunk('fmt ', fmt), ...(metadata ? [chunk('JUNK', Buffer.from([1, 2, 3]))] : []), chunk('data', data)]);
  const header = Buffer.alloc(8); header.write('RIFF'); header.writeUInt32LE(body.length, 4);
  return Buffer.concat([header, body]);
}

export function writeFixtures(directory) {
  fs.mkdirSync(directory, {recursive: true});
  const specs = {
    'silent.wav': {}, 'five.wav': {frames: 40000}, 'long.wav': {frames: 40001},
    'eight.wav': {bits: 8, values: [128]}, 'twenty-four.wav': {bits: 24},
    'thirty-two.wav': {bits: 32, extensible: true}, 'float.wav': {bits: 32, format: 3},
    'stereo.wav': {channels: 2, sampleRate: 48000},
    'high-rate.wav': {bits: 32, channels: 2, sampleRate: 192000, frames: 960000}
  };
  for (const [name, spec] of Object.entries(specs)) fs.writeFileSync(path.join(directory, name), makeWave(spec));
  const unsupported = makeWave(); unsupported.writeUInt16LE(6, 20); fs.writeFileSync(path.join(directory, 'unsupported.wav'), unsupported);
  fs.writeFileSync(path.join(directory, 'broken.wav'), 'not audio');
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) writeFixtures(process.argv[2]);
