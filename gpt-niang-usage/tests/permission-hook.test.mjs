import nodeTest from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync, spawn} from 'node:child_process';
import {createInterface} from 'node:readline';
import {PermissionHookMonitor, permissionHookEvent, writePermissionEvent} from '../runtime/permission-hook.mjs';

// This optional receiver is launched by the macOS app only. Unix fixtures rely
// on private file modes and symlinks; Windows has no consumer for this path.
const test = process.platform === 'win32' ? nodeTest.skip : nodeTest;

const hook = new URL('../runtime/permission-hook.mjs', import.meta.url).pathname;
const helper = new URL('../runtime/completion-watch.mjs', import.meta.url).pathname;
const input = (hook_event_name='PermissionRequest',tool_name='Bash') => ({
  hook_event_name,tool_name,session_id:'session',turn_id:'turn',tool_use_id:'call-1',
  tool_input:{command:'private command',description:'private reason',token:'private token'},
});
function fixture(t) {
  const root=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'niang-permission-')));
  t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
  const directory=path.join(root,'events');fs.mkdirSync(directory);
  return {root,directory};
}
function invoke(directory,value) {
  return spawnSync(process.execPath,[hook,'--events-dir',directory],{
    input:typeof value==='string'?value:JSON.stringify(value),encoding:'utf8',timeout:3000,
  });
}

test('a real hook command writes only permission metadata and never returns an approval decision',t=>{
  const {directory}=fixture(t);const r=invoke(directory,input());
  assert.equal(r.status,0,r.stderr);assert.equal(r.stdout,'');assert.equal(r.stderr,'');
  const files=fs.readdirSync(directory);assert.equal(files.length,1);
  const content=fs.readFileSync(path.join(directory,files[0]),'utf8');const event=JSON.parse(content);
  assert.deepEqual(Object.keys(event).sort(),['at','eventId','kind','threadId']);
  assert.equal(event.threadId,'session');assert.equal(event.kind,'command');
  assert.ok(Math.abs(Date.now()-event.at)<3000);assert.equal(content.includes('private'),false);
  assert.equal(content.includes('call-1'),false);assert.equal(fs.statSync(path.join(directory,files[0])).mode & 0o777,0o600);
});

test('dedicated permission-tool hooks cover nested requests but ordinary tools and completion hooks do not alert',t=>{
  const {directory}=fixture(t);
  for(const [hookName,tool,expected] of [
    ['PreToolUse','request_permissions','permission'],['PreToolUse','functions.request_permissions','permission'],
    ['PermissionRequest','apply_patch','permission'],['PermissionRequest','mcp__test__tool','permission'],
    ['PreToolUse','exec_command',null],['PostToolUse','request_permissions',null],
  ]) {
    for(const file of fs.readdirSync(directory))fs.unlinkSync(path.join(directory,file));
    const r=invoke(directory,input(hookName,tool));assert.equal(r.status,0,r.stderr);
    const files=fs.readdirSync(directory);assert.equal(files.length,expected?1:0);
    if(expected)assert.equal(JSON.parse(fs.readFileSync(path.join(directory,files[0]))).kind,expected);
  }
});

test('invalid identities, malformed input, bypass mode and oversized input remain advisory and emit nothing',t=>{
  const {directory}=fixture(t);
  for(const value of ['not json',{...input(),session_id:''},{...input(),turn_id:null},
    {...input(),permission_mode:'bypassPermissions'},'x'.repeat(1024*1024+1)]) {
    const r=invoke(directory,value);assert.equal(r.status,0);assert.equal(r.stdout,'');assert.equal(r.stderr,'');
  }
  assert.deepEqual(fs.readdirSync(directory),[]);
});

test('hook output refuses symlink directories and does not write through them',t=>{
  const {root,directory}=fixture(t);const link=path.join(root,'link');fs.symlinkSync(directory,link);
  const r=invoke(link,input());assert.equal(r.status,0);assert.equal(r.stdout,'');assert.equal(r.stderr,'');
  assert.deepEqual(fs.readdirSync(directory),[]);
});

test('the permission reader skips historical, future and invalid metadata without replaying consumed requests',t=>{
  const {directory}=fixture(t);const now=Date.now();
  writePermissionEvent(directory,permissionHookEvent(input(),now-10000));
  const reader=new PermissionHookMonitor(directory,now);assert.deepEqual(reader.update(),[]);
  writePermissionEvent(directory,permissionHookEvent(input(),now+10000));assert.deepEqual(reader.update(),[]);
  writePermissionEvent(directory,{...permissionHookEvent(input(),now),private:'never forward'});assert.deepEqual(reader.update(),[]);
  writePermissionEvent(directory,permissionHookEvent(input(),now));
  assert.equal(reader.update()[0]?.kind,'command');assert.deepEqual(reader.update(),[]);
});

test('the permission reader does not follow linked event files or linked directories',t=>{
  const {root,directory}=fixture(t);const now=Date.now();
  writePermissionEvent(directory,permissionHookEvent(input(),now));
  const file=path.join(directory,fs.readdirSync(directory)[0]);const outside=path.join(root,'outside.json');
  fs.renameSync(file,outside);fs.symlinkSync(outside,file);
  assert.deepEqual(new PermissionHookMonitor(directory,now-1).update(),[]);assert.ok(fs.existsSync(outside));
  const link=path.join(root,'linked');fs.symlinkSync(directory,link);
  assert.deepEqual(new PermissionHookMonitor(link,now-1).update(),[]);
});

test('the live helper receives fresh permission events on file writes without native notifications', {timeout:10000},async t=>{
  const {root,directory}=fixture(t);const home=path.join(root,'codex');fs.mkdirSync(home);
  const child=spawn(process.execPath,[helper],{env:{...process.env,CODEX_HOME:home,
    GPT_NIANG_NOTIFICATION_LOG_ROOT:path.join(root,'no-logs'),GPT_NIANG_PERMISSION_EVENT_DIR:directory},stdio:['pipe','pipe','pipe']});
  t.after(()=>child.kill());const reader=createInterface({input:child.stdout});t.after(()=>reader.close());
  const it=reader[Symbol.asyncIterator]();const first=JSON.parse((await it.next()).value);assert.deepEqual(first.events,[]);
  const next=new Promise(resolve=>{
    const listener=line=>{const frame=JSON.parse(line);if(frame.events.length){clearTimeout(timer);reader.off('line',listener);resolve(frame);}};
    const timer=setTimeout(()=>{reader.off('line',listener);resolve(null);},4000);reader.on('line',listener);
  });
  const r=invoke(directory,input('PreToolUse','request_permissions'));assert.equal(r.status,0,r.stderr);
  const frame=await next;assert.ok(frame,'permission metadata must arrive before the reconciliation timer');
  assert.equal(frame.events.length,1);assert.equal(frame.events[0].kind,'permission');
  assert.equal(JSON.stringify(frame).includes('private'),false);
  const closed=new Promise(resolve=>child.once('exit',resolve));child.stdin.end();assert.equal(await closed,0);
});
