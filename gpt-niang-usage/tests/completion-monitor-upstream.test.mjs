import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {CompletionMonitor,CompletionRolloutTail,parseCompletionRecord,listRolloutFiles,defaultCodexHome} from '../runtime/completion-monitor.mjs';

const stamp=Date.parse('2026-10-15T00:00:00Z');
const event=(id,type='task_complete',extra={},at=stamp+1000)=>({type:'event_msg',timestamp:new Date(at).toISOString(),payload:{type,turn_id:id,...extra}});
const header=(source='vscode')=>({type:'session_meta',payload:{source}});
const append=(file,value)=>fs.appendFileSync(file,JSON.stringify(value)+'\n','utf8');
function fixture(run){const root=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-niang-completion-node-'));try{return run(root);}finally{fs.rmSync(root,{recursive:true,force:true});}}

test('normal endings contain identifiers, not summaries or transcript text',()=>{
  assert.deepEqual(parseCompletionRecord(event('a','task_complete',{last_agent_message:'private reply'}),{sessionId:'chat'}),{type:'completion',sessionId:'chat',turnId:'a',endedAt:stamp+1000});
});
test('dedupe is per session and turn, including alternate normal ending names',()=>{
  const seenTurns=new Set();
  assert.ok(parseCompletionRecord(event('a'),{sessionId:'one',seenTurns}));
  assert.equal(parseCompletionRecord(event('a','turn_complete'),{sessionId:'one',seenTurns}),null);
  assert.ok(parseCompletionRecord(event('a'),{sessionId:'two',seenTurns}));
});
test('cancel, failure, unrelated records, and missing identifiers never trigger',()=>{
  for(const record of [event('a','turn_aborted'),event('a','task_started'),event('a','task_complete',{error:{message:'failure'}}),event('a','task_complete',{status:'cancelled'}),event(null),{type:'response_item',payload:{type:'task_complete',turn_id:'a'}}])assert.equal(parseCompletionRecord(record),null);
});
test('time boundary rejects imported old records and malformed timestamps',()=>{
  assert.equal(parseCompletionRecord(event('old','task_complete',{},stamp-1),{since:stamp}),null);
  assert.equal(parseCompletionRecord({...event('bad'),timestamp:'invalid'},{since:stamp}),null);
  assert.ok(parseCompletionRecord(event('new'),{since:stamp}));
});
test('UTF-8 and incomplete JSONL are buffered until the full line arrives',()=>fixture(root=>{
  const file=path.join(root,'tail.jsonl');fs.writeFileSync(file,'');const tail=new CompletionRolloutTail(file);
  const bytes=Buffer.from(JSON.stringify(event('中文轮次'))+'\n'),split=bytes.indexOf(Buffer.from('中'))+1;
  fs.appendFileSync(file,bytes.subarray(0,split));assert.deepEqual(tail.update(),[]);
  fs.appendFileSync(file,bytes.subarray(split));assert.equal(tail.update()[0].turnId,'中文轮次');assert.deepEqual(tail.update(),[]);
}));
test('startup ignores existing completions and receives the next event',()=>fixture(root=>{
  fs.mkdirSync(path.join(root,'sessions'));const file=path.join(root,'sessions','a.jsonl');append(file,header());append(file,event('old'));
  const found=[],monitor=new CompletionMonitor({codexHome:root,since:stamp,onNotification:x=>found.push(x)});
  monitor.scan(true);assert.equal(found.length,0);append(file,event('new'));monitor.scan();monitor.scan();assert.deepEqual(found.map(x=>x.turnId),['new']);
}));
test('fast new sessions work, while historical files imported after startup do not replay',()=>fixture(root=>{
  fs.mkdirSync(path.join(root,'sessions'));const found=[],monitor=new CompletionMonitor({codexHome:root,since:stamp,onNotification:x=>found.push(x)});monitor.scan(true);
  const fast=path.join(root,'sessions','fast.jsonl');append(fast,header());append(fast,event('fast'));monitor.scan();
  const old=path.join(root,'sessions','imported.jsonl');append(old,header());append(old,event('history','task_complete',{},stamp-5000));monitor.scan();
  assert.deepEqual(found.map(x=>x.turnId),['fast']);
}));
test('subagent and partial or unknown session headers are excluded',()=>fixture(root=>{
  fs.mkdirSync(path.join(root,'sessions'));const found=[],monitor=new CompletionMonitor({codexHome:root,since:stamp,onNotification:x=>found.push(x)});monitor.scan(true);
  const child=path.join(root,'sessions','child.jsonl');append(child,header({subagent:{other:'guardian'}}));append(child,event('internal'));
  const partial=path.join(root,'sessions','partial.jsonl');fs.writeFileSync(partial,JSON.stringify(header()));monitor.scan();assert.equal(found.length,0);
  fs.appendFileSync(partial,'\n');append(partial,event('user'));monitor.scan();assert.deepEqual(found.map(x=>x.turnId),['user']);
}));
test('archiving a session retains offset and dedupe state',()=>fixture(root=>{
  fs.mkdirSync(path.join(root,'sessions'));fs.mkdirSync(path.join(root,'archived_sessions'));
  const file=path.join(root,'sessions','move.jsonl');append(file,header());const found=[],monitor=new CompletionMonitor({codexHome:root,since:stamp,onNotification:x=>found.push(x)});monitor.scan(true);
  append(file,event('one'));monitor.scan();const moved=path.join(root,'archived_sessions','move.jsonl');fs.renameSync(file,moved);append(moved,event('two'));monitor.scan();
  assert.deepEqual(found.map(x=>x.turnId),['one','two']);
}));
test('truncation and replacement do not replay history or lose a newly written ending',()=>fixture(root=>{
  const file=path.join(root,'rotation.jsonl');append(file,event('old','task_complete',{},stamp-1));const tail=new CompletionRolloutTail(file,{baseline:true,since:stamp});
  fs.writeFileSync(file,'');tail.update();append(file,event('fresh'));assert.equal(tail.update()[0].turnId,'fresh');
  const replacement=path.join(root,'replacement.jsonl');append(replacement,event('old','task_complete',{},stamp-1));append(replacement,event('fresh'));append(replacement,event('newer'));
  fs.unlinkSync(file);fs.renameSync(replacement,file);assert.deepEqual(tail.update().map(x=>x.turnId),['newer']);
}));
test('oversized partial lines and malformed JSON cannot consume the next valid event',()=>fixture(root=>{
  const file=path.join(root,'long.jsonl');fs.writeFileSync(file,'');const tail=new CompletionRolloutTail(file);
  fs.appendFileSync(file,'x'.repeat(1100000));assert.deepEqual(tail.update(),[]);fs.appendFileSync(file,'tail\n{invalid}\n');append(file,event('after'));assert.equal(tail.update()[0].turnId,'after');
}));
test('scan stays within rollout folders and a callback failure does not stop other events',()=>fixture(root=>{
  fs.mkdirSync(path.join(root,'sessions'));fs.mkdirSync(path.join(root,'unrelated'));const file=path.join(root,'sessions','a.jsonl');append(file,header());fs.writeFileSync(path.join(root,'unrelated','secret.jsonl'),'');
  // macOS /var is a symlink to /private/var; listRolloutFiles returns real paths.
  assert.deepEqual(listRolloutFiles(root),[fs.realpathSync(file)]);let callbacks=0;const monitor=new CompletionMonitor({codexHome:root,since:stamp,onNotification:()=>{callbacks++;throw Error('consumer failed');}});
  monitor.scan(true);append(file,event('one'));append(file,event('two'));monitor.scan();assert.equal(callbacks,2);
  assert.equal(defaultCodexHome({CODEX_HOME:root}),path.resolve(root));
}));
