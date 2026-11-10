import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {DesktopNotificationEvents, NotificationLogMonitor} from '../runtime/desktop-notifications.mjs';
const at = Date.now();
const line = (kind,id,t=at) => `${new Date(t).toISOString()} info [desktop-notifications] show notification actionCount=0 kind=${kind} notificationId=${id}`;
test('only actual delivered notification requests emit classified metadata; duplicate pipelines do not',()=>{
 const p=new DesktopNotificationEvents(at-1);
 assert.deepEqual(p.accept(`${new Date(at).toISOString()} info [electron-message-handler] [desktop-notifications] show notification conversationId=x kind=question requestId=2`),[]);
 const q=p.accept(line('question','question-local-2'));
 assert.equal(q[0].kind,'question'); assert.equal(q[0].at,at);
 assert.deepEqual(p.accept(line('question','question-local-2')),[]);
 assert.equal(p.accept(line('agent-message','message'))[0].kind,'generic');
 assert.deepEqual(p.accept('chatgpt_conversation_refetch_completed statusAfter=idle'),[]);
 assert.equal(p.accept(line('permission','approval-local-3'))[0].kind,'permission');
 assert.equal(JSON.stringify(q).includes('question-local'),false);
});
test('approval subtype uses metadata only and never labels a file permission as a command',()=>{
 const p=new DesktopNotificationEvents(at-1);
 p.accept(`${new Date(at).toISOString()} info [electron-message-handler] [desktop-notifications] received approval conversationId=thread requestId=7 kind=commandExecution`);
 assert.equal(p.accept(line('permission','approval-local-7'))[0].kind,'command');
 p.accept(`${new Date(at).toISOString()} info [electron-message-handler] [desktop-notifications] received approval conversationId=thread requestId=8 kind=fileChange`);
 assert.equal(p.accept(line('permission','approval-local-8'))[0].kind,'permission');
});
test('completion IDs match local completion deduplication without retaining account fields',()=>{
 const p=new DesktopNotificationEvents(at-1);
 const e=p.accept(line('turn-complete','turn-'+JSON.stringify(['private-account','private-user','local','thread','turn'])))[0];
 assert.equal(e.kind,'completion'); assert.equal(e.threadId,'thread'); assert.equal(e.eventId,'thread:turn');
 assert.equal(JSON.stringify(e).includes('private'),false);
 assert.equal(p.accept(line('turn-complete','unknown-shape'))[0].kind,'generic');
 assert.deepEqual(p.accept(line('question','old',at-10000)),[]);
});
test('incremental logs skip history, join partial lines, handle new files, and reject symlinks',t=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'niang-notify-'));t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
 const day=path.join(root,'2026','10','22');fs.mkdirSync(day,{recursive:true});
 const file=path.join(day,'codex-desktop-fixture-t0-i1-120000-0.log');fs.writeFileSync(file,line('question','old')+'\n');
 const m=new NotificationLogMonitor(root,at-1);
 assert.deepEqual(m.update(),[]);
 const q=line('question','new');fs.appendFileSync(file,q.slice(0,70));assert.deepEqual(m.update(),[]);
 fs.appendFileSync(file,q.slice(70)+'\n');assert.equal(m.update().length,1);assert.deepEqual(m.update(),[]);
 fs.renameSync(file,file+'.old');fs.writeFileSync(file,line('question','rotated')+'\n');assert.equal(m.update().length,1);
 const outside=path.join(root,'outside');fs.writeFileSync(outside,line('question','escape')+'\n');
 fs.symlinkSync(outside,path.join(day,'codex-desktop-escape-t0-i1-120000-0.log'));assert.deepEqual(m.update(),[]);
});

test('helper observes notification writes without a Codex index and never replays history', {timeout:12000},async t=>{
 const {spawn}=await import('node:child_process');const {createInterface}=await import('node:readline');
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'niang-notification-helper-'));
 t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
 const home=path.join(root,'codex');fs.mkdirSync(home);
 const logs=path.join(root,'logs');const day=path.join(logs,'2026','10','22');fs.mkdirSync(day,{recursive:true});
 const file=path.join(day,'codex-desktop-test-t0-i1-120000-0.log');fs.writeFileSync(file,line('question','old')+'\n');
 const child=spawn(process.execPath,[new URL('../runtime/completion-watch.mjs',import.meta.url).pathname],{
  env:{...process.env,CODEX_HOME:home,GPT_NIANG_NOTIFICATION_LOG_ROOT:logs},stdio:['pipe','pipe','pipe']});
 t.after(()=>child.kill());const reader=createInterface({input:child.stdout});const it=reader[Symbol.asyncIterator]();
 const first=JSON.parse((await it.next()).value);assert.deepEqual(first.events,[]);assert.equal(first.notificationLogAvailable,true);
 const started=Date.now();fs.appendFileSync(file,line('question','question-local-new',started)+'\n');
 let next;do{next=JSON.parse((await it.next()).value);}while(!next.events.length);
 assert.equal(next.events[0].kind,'question');assert.ok(Date.now()-started<5000,'write-triggered rather than 30-second reconciliation');
 assert.equal(JSON.stringify(next).includes('question-local-new'),false);
 const closed=new Promise(resolve=>child.once('exit',resolve));child.stdin.end();assert.equal(await closed,0);reader.close();
});

test('same-millisecond approval metadata stays before delivery when reading a batch',t=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'niang-notify-order-'));t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
 const day=path.join(root,'2026','10','22');fs.mkdirSync(day,{recursive:true});
 const file=path.join(day,'codex-desktop-test-t0-i1-120000-0.log');fs.writeFileSync(file,'');
 const m=new NotificationLogMonitor(root,at-1);m.update();
 fs.appendFileSync(file,`${new Date(at).toISOString()} info [electron-message-handler] [desktop-notifications] received approval conversationId=thread requestId=7 kind=commandExecution\n`+line('permission','approval-local-7')+'\n');
 assert.equal(m.update()[0].kind,'command');
});

test('approval fields may be reordered and interleaved with renderer diagnostics',()=>{
 const p=new DesktopNotificationEvents(at-1);
 p.accept(`${new Date(at).toISOString()} info [electron-message-handler] [desktop-notifications] received approval conversationId=thread kind=commandExecution rendererWindowFocused=false requestId=9`);
 assert.equal(p.accept(line('permission','approval-local-9'))[0].kind,'command');
});

test('unclassified native notifications become neutral reminders, never guessed questions or completions',()=>{
 const p=new DesktopNotificationEvents(at-1);
 for(const type of ['agent-message','new-host-kind']) {
  const e=p.accept(line(type,'opaque-'+type))[0];assert.equal(e?.kind,'generic');
  assert.equal(JSON.stringify(e).includes('opaque-'),false);
  assert.deepEqual(p.accept(line(type,'opaque-'+type)),[]);
 }
 assert.equal(p.accept(line('turn-complete','remote-format'))[0]?.kind,'generic');
 assert.deepEqual(p.accept(`${new Date(at).toISOString()} info [electron-message-handler] chatgpt_conversation_refetch_completed statusAfter=idle`),[]);
});
