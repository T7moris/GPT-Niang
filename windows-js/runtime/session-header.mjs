import fs from 'node:fs';

export const MAX_SESSION_HEADER_BYTES = 4 * 1024 * 1024;
// Read only the first complete JSONL record. Metadata can contain long startup
// instructions; ordinary message bodies must never be retained by this helper.
export function readSessionMetadata(file, {fd: supplied, maxBytes = MAX_SESSION_HEADER_BYTES} = {}) {
  let fd = supplied;
  try {
    fd ??= fs.openSync(file, 'r');
    const parts = [];
    let offset = 0;
    while (offset < maxBytes) {
      const bytes = Buffer.alloc(Math.min(64 * 1024, maxBytes - offset));
      const count = fs.readSync(fd, bytes, 0, bytes.length, offset);
      if (!count) return {status: 'pending'};
      const chunk = bytes.subarray(0, count), newline = chunk.indexOf(10);
      if (newline >= 0) {
        parts.push(chunk.subarray(0, newline));
        const record = JSON.parse(Buffer.concat(parts).toString('utf8').replace(/^\uFEFF/, ''));
        if (record?.type !== 'session_meta' || !record.payload || typeof record.payload !== 'object') return {status: 'invalid'};
        return {status: 'ok', metadata: record.payload, bytes: offset + newline + 1};
      }
      parts.push(chunk);
      offset += count;
    }
    return {status: 'too-large'};
  } catch {
    return {status: 'unavailable'};
  } finally {
    if (supplied === undefined && fd !== undefined) fs.closeSync(fd);
  }
}
