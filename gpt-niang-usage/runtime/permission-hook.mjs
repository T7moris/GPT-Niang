import fs from 'node:fs';
import path from 'node:path';
import {createHash, randomUUID} from 'node:crypto';
import {fileURLToPath} from 'node:url';

const validId = value => typeof value === 'string' && /^[a-zA-Z0-9._:-]{1,200}$/.test(value);
const permissionTool = name => ['request_permissions', 'functions.request_permissions'].includes(name);

// Advisory only: never return a hook decision, alter input, or retain tool arguments.
export function permissionHookEvent(input, now = Date.now()) {
  if (!validId(input?.session_id) || !validId(input?.turn_id) || !validId(input?.tool_name)) return null;
  if (['bypassPermissions', 'dontAsk'].includes(input.permission_mode)) return null;
  const explicitRequest = input.hook_event_name === 'PreToolUse' && permissionTool(input.tool_name);
  const approval = input.hook_event_name === 'PermissionRequest' && !permissionTool(input.tool_name);
  if (!explicitRequest && !approval) return null;
  const id = validId(input.request_id) ? input.request_id : validId(input.tool_use_id) ? input.tool_use_id : randomUUID();
  const eventId = 'permission-hook:' + createHash('sha256').update(JSON.stringify([
    input.session_id, input.turn_id, input.tool_name, id,
  ])).digest('hex');
  return {threadId:input.session_id,eventId,kind:input.tool_name === 'Bash' ? 'command' : 'permission',at:now};
}

export function writePermissionEvent(directory, event) {
  const root = path.resolve(directory), parent = path.dirname(root);
  if (fs.realpathSync(parent) !== parent || !fs.statSync(parent).isDirectory()) return;
  if (!fs.existsSync(root)) fs.mkdirSync(root, {mode:0o700});
  if (fs.realpathSync(root) !== root || !fs.lstatSync(root).isDirectory()) return;
  if (process.getuid && fs.statSync(root).uid !== process.getuid()) return;
  const name = `${event.at}-${randomUUID()}`, temporary = path.join(root, '.' + name + '.tmp');
  try {
    fs.writeFileSync(temporary, JSON.stringify(event) + '\n', {flag:'wx',mode:0o600});
    fs.renameSync(temporary, path.join(root, name + '.json'));
  } finally { try { fs.unlinkSync(temporary); } catch {} }
}

export class PermissionHookMonitor {
  constructor(directory, startedAt = Date.now()) { this.root = directory ? path.resolve(directory) : null; this.startedAt = startedAt; }
  update() {
    if (!this.root) return [];
    const events = [];
    try {
      if (fs.realpathSync(this.root) !== this.root || !fs.lstatSync(this.root).isDirectory()) return [];
      if (process.getuid && fs.statSync(this.root).uid !== process.getuid()) return [];
      const files = fs.readdirSync(this.root).filter(name => /^\d{13}-[a-f0-9-]{36}\.json$/.test(name)).sort().slice(0,256);
      for (const name of files) {
        const file = path.join(this.root,name), stat = fs.lstatSync(file);
        if (!stat.isFile() || stat.size > 4096 || fs.realpathSync(file) !== file) continue;
        if (process.getuid && stat.uid !== process.getuid()) continue;
        let event; try { event = JSON.parse(fs.readFileSync(file,'utf8')); } catch { continue; }
        const valid = event && Object.keys(event).sort().join(',') === 'at,eventId,kind,threadId' && validId(event.threadId)
          && typeof event.eventId === 'string' && /^permission-hook:[a-f0-9]{64}$/.test(event.eventId)
          && ['command','permission'].includes(event.kind) && Number.isSafeInteger(event.at);
        if (!valid) continue;
        // Consume stale files too, but never replay requests from before startup.
        fs.unlinkSync(file);
        if (event.at < this.startedAt || event.at < Date.now()-60000 || event.at > Date.now()+5000) continue;
        events.push(event);
      }
    } catch { /* Missing/unavailable optional hooks must not stop other alerts. */ }
    return events;
  }
}

async function run() {
  const index = process.argv.indexOf('--events-dir'), directory = index >= 0 ? process.argv[index+1] : null;
  if (!directory) return;
  let data = '', size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size <= 1024*1024) data += chunk.toString('utf8');
  }
  if (size > 1024*1024) return;
  const event = permissionHookEvent(JSON.parse(data));
  if (event) writePermissionEvent(directory,event);
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  // A failed optional reminder must never approve, deny, or interrupt an action.
  run().catch(() => {});
}
