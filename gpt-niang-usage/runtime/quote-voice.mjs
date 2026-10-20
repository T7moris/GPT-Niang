import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {renderBlipWav} from './voice-synth.mjs';

export const QUOTE_VOICE_OPTIONS = Object.freeze({speed: .9, pitch: 2, variation: 99, length: 57, volume: 45, mood: 'normal'});
export function quoteTokens(text) {
  if (typeof text !== 'string' || [...text].length > 200) throw Error('INVALID_QUOTE');
  const result = [];
  for (const part of text.matchAll(/\p{Script=Han}|\p{Number}|[a-zA-Z]+|[,，、;；:：.!?。！？…\s]+/gu)) {
    const source = part[0];
    if (/^[\s,，、;；:：.!?。！？…]+$/u.test(source)) {
      result.push({source, kind: 'pause', pauseMs: /[.!?。！？…\n]/u.test(source) ? 250 : /[,，、;；:：]/u.test(source) ? 120 : 30});
    } else {
      // English words stay grouped; these are character blips, not letter names.
      const count = /^[a-z]+$/i.test(source) ? Math.max(1, Math.min(5, (source.toLowerCase().replace(/e$/, '').match(/[aeiouy]+/g) || []).length)) : 1;
      for (let i = 0; i < count; i++) result.push({source, kind: 'vowel'});
    }
  }
  return result;
}
export async function renderQuote(text) {
  const tokens = quoteTokens(text);
  if (!tokens.some(t => t.kind === 'vowel')) throw Error('EMPTY_QUOTE');
  return Buffer.from(await renderBlipWav(tokens, QUOTE_VOICE_OPTIONS).arrayBuffer());
}
export async function cacheQuote(text, directory) {
  const key = crypto.createHash('sha256').update('moon-quote-v2\0' + text).digest('hex');
  const root = path.resolve(directory), target = path.join(root, key + '.wav');
  fs.mkdirSync(root, {recursive: true});
  let valid = false;
  try {
    const stat = fs.lstatSync(target);
    if (stat.isFile() && !stat.isSymbolicLink() && stat.size > 44 && stat.size < 4 * 1024 * 1024) {
      const bytes = fs.readFileSync(target);
      valid = bytes.toString('ascii', 0, 4) === 'RIFF' && bytes.toString('ascii', 8, 12) === 'WAVE' && bytes.readUInt32LE(40) + 44 === bytes.length;
    }
  } catch {}
  if (!valid) {
    const bytes = await renderQuote(text), temp = target + '.' + process.pid + '.tmp';
    try { fs.writeFileSync(temp, bytes); fs.renameSync(temp, target); }
    finally { try { fs.unlinkSync(temp); } catch {} }
  }
  const files = fs.readdirSync(root).filter(name => /^[a-f0-9]{64}\.wav$/.test(name))
    .map(name => ({name, time: fs.statSync(path.join(root, name)).mtimeMs})).sort((a, b) => b.time - a.time);
  // Keep the returned path, even when this request hit an older cached entry.
  const others = files.filter(item => path.join(root, item.name) !== target);
  for (const item of others.slice(31)) { try { fs.unlinkSync(path.join(root, item.name)); } catch {} }
  return target;
}
async function run() {
  process.stdin.setEncoding('utf8');
  let input = '';
  for await (const chunk of process.stdin) {
    input += chunk.toString('utf8');
    if (Buffer.byteLength(input) > 16384) throw Error('INPUT_TOO_LARGE');
  }
  const {text} = JSON.parse(input);
  quoteTokens(text); // Validate before deriving a cache key or touching disk.
  const file = await cacheQuote(text, process.argv[2]);
  process.stdout.write(JSON.stringify({file}));
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  run().catch(() => { process.stderr.write('QUOTE_VOICE_FAILED'); process.exitCode = 1; });
}
