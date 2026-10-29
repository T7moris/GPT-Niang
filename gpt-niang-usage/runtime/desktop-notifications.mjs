import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';

// Read notification metadata only. Never forward titles, command text, answers,
// account-scoped notification IDs, or chat bodies to the pet.
export class DesktopNotificationEvents {
  constructor(startedAt = Date.now()) { this.startedAt = startedAt; this.seen = new Map(); this.approvals = new Map(); }
  accept(line) {
    if (line.length > 32768) return [];
    const at = Date.parse(line.slice(0, 24));
    if (!Number.isFinite(at) || at < this.startedAt || at > Date.now() + 5000) return [];
    for (const [key, time] of this.seen) if (at - time > 86400000) this.seen.delete(key);
    for (const [key, value] of this.approvals) if (at - value.at > 30000) this.approvals.delete(key);
    if (line.includes(' info [electron-message-handler] [desktop-notifications] received approval ')) {
      const request = line.match(/\brequestId=([^ ]+)(?: |$)/)?.[1];
      const kind = line.match(/\bkind=(commandExecution|fileChange|permissionRequest)(?: |$)/)?.[1];
      if (request && kind) this.approvals.set(request, {kind, at});
      return [];
    }
    // Match only the native notification sender, not the renderer/forwarding
    // copies. Suppressed requests never reach this log statement.
    const match = line.match(/ info \[desktop-notifications\] show notification actionCount=\d+ kind=([a-zA-Z][a-zA-Z0-9_-]{0,63}) notificationId=(.+)$/);
    if (!match) return [];
    const [, type, id] = match;
    if (!id || id.length > 4096) return [];
    let kind = type === 'turn-complete' ? 'completion' : ['question','permission'].includes(type) ? type : 'generic';
    let threadId = 'desktop', eventId;
    eventId = 'notice:' + createHash('sha256').update(id).digest('hex');
    if (kind === 'completion') {
      try {
        if (!id.startsWith('turn-')) throw new Error('unrecognized identity');
        const parts = JSON.parse(id.slice(5));
        if (!Array.isArray(parts) || parts.length !== 5 || !parts.slice(3).every(v => typeof v === 'string' && v.length > 0 && v.length <= 200)) throw new Error('unrecognized identity');
        threadId = parts[3]; eventId = `${threadId}:${parts[4]}`;
      } catch { kind = 'generic'; }
    } else if (kind === 'permission') {
      const request = id.startsWith('approval-local-') ? id.slice('approval-local-'.length) : null;
      if (request && this.approvals.get(request)?.kind === 'commandExecution') kind = 'command';
    }
    if (this.seen.has(eventId)) return [];
    this.seen.set(eventId, at);
    if (this.seen.size > 4096) this.seen.delete(this.seen.keys().next().value);
    return [{threadId, eventId, kind, at}];
  }
}

export class NotificationLogMonitor {
  constructor(root, startedAt = Date.now()) {
    this.root = fs.existsSync(root) ? fs.realpathSync(root) : path.resolve(root); this.events = new DesktopNotificationEvents(startedAt);
    this.tails = new Map(); this.first = true; this.available = false;
  }
  files() {
    const directories = [this.root];
    for (let depth = 0; depth < 3; depth++) {
      const previous = directories.splice(0);
      for (const dir of previous) {
        for (const entry of fs.readdirSync(dir, {withFileTypes: true})) {
          if (entry.isDirectory() && /^\d{2,4}$/.test(entry.name)) directories.push(path.join(dir, entry.name));
        }
      }
      directories.sort(); directories.splice(0, Math.max(0, directories.length - 2));
    }
    return directories.flatMap(dir => fs.readdirSync(dir, {withFileTypes:true})
      .filter(e => e.isFile() && /^codex-desktop-.*-t0-.*\.log$/.test(e.name))
      .map(e => path.join(dir, e.name))).sort((a,b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs).slice(0,12);
  }
  update() {
    const lines = [];
    try {
      const files = this.files(); this.available = files.length > 0;
      for (const file of files) {
        // Disallow symlinked files/parents, including rotation replacements.
        if (fs.realpathSync(file) !== file) continue;
        const stat = fs.statSync(file); let tail = this.tails.get(file);
        if (!tail || tail.ino !== stat.ino || stat.size < tail.offset) {
          tail = {ino:stat.ino, offset:this.first ? stat.size : Math.max(0,stat.size-1024*1024), pending:'', skip:false};
          if (tail.offset > 0) {
            const fd=fs.openSync(file,'r'),last=Buffer.alloc(1);
            try {fs.readSync(fd,last,0,1,tail.offset-1);} finally {fs.closeSync(fd);}
            tail.skip=last[0]!==10;
          }
          this.tails.set(file,tail);
        }
        const size = Math.min(1024*1024,stat.size-tail.offset);
        if (size<=0) continue;
        const fd=fs.openSync(file,'r'),buffer=Buffer.alloc(size);let count;
        try {count=fs.readSync(fd,buffer,0,size,tail.offset);} finally {fs.closeSync(fd);}
        tail.offset+=count;
        const chunks=(tail.pending+buffer.subarray(0,count).toString('utf8')).split('\n');tail.pending=chunks.pop();
        if(tail.skip && chunks.length){chunks.shift();tail.skip=false;}
        if(tail.pending.length>32768){tail.pending='';tail.skip=true;}
        lines.push(...chunks.filter(l=>l.includes('[desktop-notifications]')));
      }
      for(const file of this.tails.keys()) if(!files.includes(file)) this.tails.delete(file);
    } catch { this.available=false; }
    this.first=false;
    return lines.sort((a,b) => Date.parse(a.slice(0,24)) - Date.parse(b.slice(0,24))).flatMap(line=>this.events.accept(line));
  }
}
