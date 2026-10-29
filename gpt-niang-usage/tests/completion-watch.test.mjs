import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {CompletionEvents, CompletionMonitor} from '../runtime/completion-watch.mjs';
import {RolloutCounters, readRecentThreads} from '../runtime/thread-speed.mjs';
import {quotaPresenceActive} from '../runtime/worker-state.mjs';
const event=(type,at=1000,turn_id='turn1')=>({type:'event_msg',timestamp:new Date(at).toISOString(),payload:{type,turn_id,privateText:'never emit'}});
const question=(at=2000,id='call-q',name='request_user_input_async')=>({type:'response_item',timestamp:new Date(at).toISOString(),payload:{type:'function_call',name,call_id:id,arguments:'private question and options'}});
const accepted=(at=2100,id='call-q',output='{"accepted":true}')=>({type:'response_item',timestamp:new Date(at).toISOString(),payload:{type:'function_call_output',call_id:id,output}});

test('accepted local interactive questions emit once before completion without forwarding question content',()=>{
  const events=new CompletionEvents('thread');events.accept(event('task_started'));
  events.accept(question());assert.deepEqual(events.drain(),[]);
  events.accept(accepted());events.accept(question());events.accept(accepted());
  const alerts=events.drain();assert.equal(alerts.length,1);
  assert.equal(alerts[0].kind,'question');assert.equal(alerts[0].threadId,'thread');assert.equal(alerts[0].at,2100);
  assert.equal(JSON.stringify(alerts).includes('private'),false);
  assert.equal(JSON.stringify(alerts).includes('call-q'),false);
  events.accept(event('task_complete',3000));assert.deepEqual(events.drain(),[{threadId:'thread',eventId:'thread:turn1',at:3000}]);
});

test('question calls without a live start or explicit acceptance never announce a question',()=>{
  const events=new CompletionEvents('thread');
  events.accept(question());events.accept(accepted());assert.deepEqual(events.drain(),[]);
  events.accept(event('task_started'));
  for(const output of ['{"accepted":false}','{"error":"not available"}','not json','{"accepted":"true"}']) {
    events.accept(question());events.accept(accepted(2100,'call-q',output));assert.deepEqual(events.drain(),[]);
  }
  events.accept(question(2200,'other','some_other_tool'));events.accept(accepted(2300,'other'));assert.deepEqual(events.drain(),[]);
  events.accept(question(2400,'cancelled'));events.accept(event('turn_aborted',2500));events.accept(accepted(2600,'cancelled'));assert.deepEqual(events.drain(),[]);
  events.accept(event('task_started',3000,'two'));
  events.accept(question(3100,'new','functions.request_user_input_async'));events.accept(accepted(3200,'new'));assert.equal(events.drain()[0]?.kind,'question');
});

test('local question writes are incremental, historical questions and truncated pending calls are ignored',t=>{
  const {home,file,row,append}=fixture(t);
  append(event('task_started'),question(),accepted());
  const monitor=new CompletionMonitor(home,0);assert.deepEqual(monitor.update([row]),[]);
  append(event('task_started',3000));monitor.update([row]);
  const record=JSON.stringify(question(4000));fs.appendFileSync(file,record.slice(0,30));assert.deepEqual(monitor.update([row]),[]);
  fs.appendFileSync(file,record.slice(30)+'\n');append(accepted(4100));
  assert.equal(monitor.update([row])[0]?.kind,'question');assert.deepEqual(monitor.update([row]),[]);
  append(question(4200,'pending'));monitor.update([row]);fs.writeFileSync(file,'');monitor.update([row]);
  append(accepted(4300,'pending'));assert.deepEqual(monitor.update([row]),[]);
});

test('only a matching explicit complete after a start emits metadata, never a cancellation or idle gap',()=>{
  const events=new CompletionEvents('thread');
  events.accept(event('task_complete'));assert.deepEqual(events.drain(),[]);
  events.accept(event('task_started'));events.accept(event('token_count',2000));
  assert.deepEqual(events.drain(),[]);
  events.accept(event('task_complete',3000,'wrong'));assert.deepEqual(events.drain(),[]);
  events.accept(event('task_complete',4000));events.accept(event('task_complete',4000));
  assert.deepEqual(events.drain(),[{threadId:'thread',eventId:'thread:turn1',at:4000}]);
  for(const stop of ['turn_aborted','task_failed']){
    events.accept(event('task_started'));events.accept(event(stop,2000));events.accept(event('task_complete',3000));
    assert.deepEqual(events.drain(),[]);
  }
  events.accept(event('task_started'));
  const failed=event('task_complete',2000);failed.payload.error={message:'failure'};
  events.accept(failed);assert.deepEqual(events.drain(),[]);
  events.accept(event('task_started',3000));
  const success=event('task_complete',4000);success.payload.error=null;
  events.accept(success);assert.equal(events.drain().length,1);
  const counters=new RolloutCounters();counters.accept(event('turn_aborted'));
  assert.equal(counters.state,'cancelled');
});
function fixture(t){
  const home=fs.mkdtempSync(path.join(os.tmpdir(),'niang-completion-'));
  t.after(()=>fs.rmSync(home,{recursive:true,force:true}));
  fs.mkdirSync(path.join(home,'sessions'));fs.mkdirSync(path.join(home,'archived_sessions'));
  const file=path.join(home,'sessions','a.jsonl');fs.writeFileSync(file,'');
  const row={id:'a',rollout_path:file,source:'vscode'};
  const append=(...records)=>fs.appendFileSync(file,records.map(r=>JSON.stringify(r)+'\n').join(''));
  return {home,file,row,append};
}
test('guardian and delegated agent completions never announce that the user reply ended',t=>{
  const {home,row,append}=fixture(t);
  const monitor=new CompletionMonitor(home,0);monitor.update([]);
  append(event('task_started'),event('task_complete',2000));
  for(const source of [JSON.stringify({subagent:{other:'guardian'}}),
    JSON.stringify({subagent:{thread_spawn:{parent_thread_id:'parent'}}}), 'unknown', undefined]) {
    assert.deepEqual(monitor.update([{...row,source}]),[]);
  }
  assert.equal(monitor.update([row]).length,1);
  assert.deepEqual(monitor.update([row]),[]);
});
test('internal sessions are excluded before the recent-chat limit',async t=>{
  const {spawnSync}=await import('node:child_process');
  const {home,file}=fixture(t);
  const guardian=JSON.stringify({subagent:{other:'guardian'}});
  const sql='CREATE TABLE threads(id TEXT,title TEXT,rollout_path TEXT,archived INTEGER,updated_at INTEGER,source TEXT);'+
    `INSERT INTO threads VALUES('chat','private','${file}',0,1,'vscode');`+
    Array.from({length:15},(_,i)=>`INSERT INTO threads VALUES('guard${i}','private','${file}',0,${i+2},'${guardian}');`).join('');
  const result=spawnSync('/usr/bin/sqlite3',[path.join(home,'state_1.sqlite'),sql],{encoding:'utf8'});
  assert.equal(result.status,0,result.stderr);
  assert.equal(readRecentThreads(home).length,12);
  assert.deepEqual(readRecentThreads(home,{userFacingOnly:true}).map(r=>r.id),['chat']);
});
test('baseline skips historical records; same-poll start/complete and partial lines work exactly once',t=>{
  const {home,file,row,append}=fixture(t);
  append(event('task_started'),event('task_complete',2000));
  const monitor=new CompletionMonitor(home,0);
  assert.deepEqual(monitor.update([row]),[]);
  append(event('task_started',3000));
  const complete=JSON.stringify(event('task_complete',4000));fs.appendFileSync(file,complete.slice(0,20));
  assert.deepEqual(monitor.update([row]),[]);
  fs.appendFileSync(file,complete.slice(20)+'\n');
  assert.equal(monitor.update([row]).length,1);assert.deepEqual(monitor.update([row]),[]);
  append(event('task_started',5000,'two'),event('task_complete',6000,'two'));
  assert.equal(monitor.update([row]).length,1);
});
test('new sessions created after enabling are observed, older starts are ignored, and concurrent completions merge',t=>{
  const {home,file,row,append}=fixture(t);const monitor=new CompletionMonitor(home,10000);
  assert.deepEqual(monitor.update([]),[]);
  append(event('task_started',1000),event('task_complete',11000));
  assert.deepEqual(monitor.update([row]),[]);
  const second=path.join(home,'sessions','b.jsonl');
  fs.writeFileSync(second,JSON.stringify(event('task_started',12000))+'\n'+JSON.stringify(event('task_complete',13000))+'\n');
  append(event('task_started',12000,'two'),event('task_complete',13000,'two'));
  const events=monitor.update([row,{id:'b',rollout_path:second,source:'cli'}]);assert.equal(events.length,2);
  assert.equal(JSON.stringify(events).includes('privateText'),false);
  assert.equal(JSON.stringify(events).includes(file),false);
});
test('truncation and replacement reset observed starts without replaying completions',t=>{
  const {home,file,row,append}=fixture(t);const monitor=new CompletionMonitor(home,0);monitor.update([row]);
  append(event('task_started'));monitor.update([row]);
  fs.writeFileSync(file,'');monitor.update([row]);append(event('task_complete',3000));
  assert.deepEqual(monitor.update([row]),[]);
  append(event('task_started',4000));monitor.update([row]);
  fs.renameSync(file,file+'.old');fs.writeFileSync(file,JSON.stringify(event('task_complete',5000))+'\n');
  assert.deepEqual(monitor.update([row]),[]);
});
test('partial historical lines, outside paths and symlink escapes cannot become completion notifications',t=>{
  const {home,file,row}=fixture(t);
  const started=JSON.stringify(event('task_started'));fs.writeFileSync(file,started.slice(0,30));
  const monitor=new CompletionMonitor(home,0);monitor.update([row]);
  fs.appendFileSync(file,started.slice(30)+'\n'+JSON.stringify(event('task_complete',2000))+'\n');
  assert.deepEqual(monitor.update([row]),[]);
  assert.deepEqual(monitor.update([{id:'bad',source:'vscode',rollout_path:path.join(home,'outside.jsonl')}]),[]);
  const link=path.join(home,'sessions','escape.jsonl');fs.symlinkSync(path.join(home,'outside.jsonl'),link);
  assert.deepEqual(monitor.update([{id:'bad',source:'vscode',rollout_path:link}]),[]);
});
test('hidden macOS quota alerts require explicit opt-in and a fresh live heartbeat; Windows stays unchanged',()=>{
  const p={visible:false,backgroundQuota:true,at:1000,pid:123},alive=pid=>pid===123;
  assert.equal(quotaPresenceActive(p,2000,'darwin',alive),true);
  assert.equal(quotaPresenceActive(p,2000,'win32',alive),false);
  assert.equal(quotaPresenceActive({...p,backgroundQuota:false},2000,'darwin',alive),false);
  assert.equal(quotaPresenceActive(p,6000,'darwin',alive),false);
  assert.equal(quotaPresenceActive(p,999,'darwin',alive),false);
  assert.equal(quotaPresenceActive(p,2000,'darwin',()=>false),false);
  assert.equal(quotaPresenceActive({...p,visible:true},2000,'win32',alive),true);
});

test('the real helper reads a read-only SQLite fixture, emits new completions and exits on stdin EOF', {timeout:12000}, async t=>{
  const {spawn,spawnSync}=await import('node:child_process');
  const {createInterface}=await import('node:readline');
  const {fileURLToPath}=await import('node:url');
  const {home,file,append}=fixture(t);
  const sql=spawnSync('/usr/bin/sqlite3',[path.join(home,'state_1.sqlite'),
    'CREATE TABLE threads(id TEXT,title TEXT,rollout_path TEXT,archived INTEGER,updated_at INTEGER,source TEXT);'+
    `INSERT INTO threads VALUES('a','private title','${file.replaceAll("'","''")}',0,1,'vscode');`],{encoding:'utf8'});
  assert.equal(sql.status,0,sql.stderr);
  const child=spawn(process.execPath,[fileURLToPath(new URL('../runtime/completion-watch.mjs',import.meta.url))],
    {env:{...process.env,CODEX_HOME:home,GPT_NIANG_NOTIFICATION_LOG_ROOT:path.join(home,'no-logs')},stdio:['pipe','pipe','pipe']});
  t.after(()=>child.kill());
  const lines=createInterface({input:child.stdout});
  const iterator=lines[Symbol.asyncIterator]();
  const first=JSON.parse((await iterator.next()).value);assert.deepEqual(first,{events:[],sessionCount:1,error:null,notificationLogAvailable:false});
  const at=Date.now();append(event('task_started',at),question(at+1),accepted(at+2));
  let next;
  do { next=JSON.parse((await iterator.next()).value); } while (!next.events.length);
  assert.equal(next.events[0].kind,'question');assert.ok(Date.now()-at<5000,'question arrives before completion without native notifications');
  assert.equal(JSON.stringify(next).includes('private'),false);
  append(event('task_complete',Date.now()));
  do { next=JSON.parse((await iterator.next()).value); } while (!next.events.length);
  assert.equal(next.events.length,1);assert.equal(next.error,null);
  assert.equal(next.events[0].eventId,'a:turn1');
  assert.equal(JSON.stringify(next).includes('private'),false);
  const closed=new Promise(resolve=>child.once('exit',resolve));child.stdin.end();
  assert.equal(await closed,0);lines.close();
});
