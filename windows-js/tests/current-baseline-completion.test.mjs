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
function fixture(run){const root=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-niang-completion-node-'));try{return run(root);}finally{const resolved=fs.realpathSync(root);assert.equal(path.dirname(resolved),fs.realpathSync(os.tmpdir()));assert.ok(path.basename(resolved).startsWith('gpt-niang-completion-node-'));fs.rmSync(resolved,{recursive:true,force:true});}}

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

test('deleted normal and subagent sessions expire, with bounded archive grace',()=>fixture(root=>{
  const dir=path.join(root,'sessions');fs.mkdirSync(dir);
  const monitor=new CompletionMonitor({codexHome:root,since:stamp});
  for(let i=0;i<400;i++){const file=path.join(dir,i+'.jsonl');append(file,header(i%2?'subagent':'vscode'));}
  const now=Date.now();monitor.scan(false,now);
  assert.equal(monitor.tails.size,200);assert.equal(monitor.subagentSessions.size,200);
  for(const name of fs.readdirSync(dir))fs.unlinkSync(path.join(dir,name));
  monitor.scan(false,now+1000);assert.ok(monitor.tails.size+monitor.subagentSessions.size<=256);
  monitor.scan(false,now+31000);assert.equal(monitor.tails.size,0);assert.equal(monitor.subagentSessions.size,0);
}));

test('a temporarily missing archived session preserves offset and incomplete UTF-8',()=>fixture(root=>{
  const dir=path.join(root,'sessions'),archive=path.join(root,'archived_sessions');fs.mkdirSync(dir);fs.mkdirSync(archive);
  const file=path.join(dir,'move.jsonl'),held=path.join(root,'in-transit.jsonl');append(file,header());
  const found=[],monitor=new CompletionMonitor({codexHome:root,since:stamp,onNotification:e=>found.push(e)}),now=Date.now();
  monitor.scan(true,now);append(file,event('one'));monitor.scan(false,now+1000);
  const bytes=Buffer.from(JSON.stringify(event('中文轮次'))+'\n'),split=bytes.indexOf(Buffer.from('中'))+1;
  fs.appendFileSync(file,bytes.subarray(0,split));monitor.scan(false,now+2000);
  fs.renameSync(file,held);monitor.scan(false,now+3000);
  const moved=path.join(archive,'move.jsonl');fs.renameSync(held,moved);fs.appendFileSync(moved,bytes.subarray(split));
  monitor.scan(false,now+4000);assert.deepEqual(found.map(e=>e.turnId),['one','中文轮次']);
}));

test('a long-lived session receives appended completions even with an unchanged file timestamp',()=>fixture(root=>{
  const dir=path.join(root,'sessions');fs.mkdirSync(dir);
  const file=path.join(dir,'idle.jsonl'),child=path.join(dir,'child.jsonl');append(file,header());append(child,header('subagent'));
  const found=[],monitor=new CompletionMonitor({codexHome:root,since:stamp,onNotification:e=>found.push(e)}),now=Date.now();
  append(file,event('one'));monitor.scan(false,now);
  const modified=fs.statSync(file).mtimeMs;
  monitor.scan(false,now+301000);
  append(file,event('two'));fs.utimesSync(file,modified/1000,modified/1000);
  monitor.scan(false,now+303000);monitor.scan(false,now+304000);
  assert.deepEqual(found.map(e=>e.turnId),['one','two']);
  monitor.stop();assert.equal(monitor.tails.size+monitor.subagentSessions.size+monitor.seenTurns.size,0);
}));

test('reappearing sessions after missing-cache eviction do not replay recent endings',()=>fixture(root=>{
  const dir=path.join(root,'sessions');fs.mkdirSync(dir);
  const file=path.join(dir,'return.jsonl'),held=path.join(root,'held.jsonl');append(file,header());append(file,event('one'));
  const found=[],monitor=new CompletionMonitor({codexHome:root,since:stamp,onNotification:e=>found.push(e)}),now=Date.now();
  monitor.scan(false,now);fs.renameSync(file,held);monitor.scan(false,now+31000);assert.equal(monitor.tails.size,0);
  fs.renameSync(held,file);append(file,event('two'));monitor.scan(false,now+32000);
  assert.deepEqual(found.map(e=>e.turnId),['one','two']);
}));

test('many recovered sessions continue from their own offsets without replaying 5000 old completions',()=>fixture(root=>{
  const dir=path.join(root,'sessions'),held=path.join(root,'held');fs.mkdirSync(dir);
  const found=[],monitor=new CompletionMonitor({codexHome:root,since:stamp,onNotification:e=>found.push(e)}),now=Date.now();
  for(let i=0;i<200;i++)append(path.join(dir,i+'.jsonl'),header());
  monitor.scan(true,now);
  for(let i=0;i<200;i++){
    const lines=Array.from({length:25},(_,j)=>JSON.stringify(event('turn-'+j))+'\n').join('');
    fs.appendFileSync(path.join(dir,i+'.jsonl'),lines);
  }
  monitor.scan(false,now+1000);assert.equal(found.length,5000);
  fs.renameSync(dir,held);monitor.scan(false,now+32000);
  assert.equal(monitor.tails.size,0);assert.equal(monitor.checkpoints.size,200);
  append(path.join(held,'0.jsonl'),event('fresh'));fs.renameSync(held,dir);monitor.scan(false,now+33000);
  assert.equal(found.length,5001);assert.equal(found.at(-1).turnId,'fresh');
}));

test('an expired missing session resumes an incomplete UTF-8 line after archival',()=>fixture(root=>{
  const dir=path.join(root,'sessions'),archive=path.join(root,'archived_sessions');fs.mkdirSync(dir);fs.mkdirSync(archive);
  const file=path.join(dir,'split.jsonl'),held=path.join(root,'held.jsonl'),moved=path.join(archive,'split.jsonl');append(file,header());
  const found=[],monitor=new CompletionMonitor({codexHome:root,since:stamp,onNotification:e=>found.push(e)}),now=Date.now();
  monitor.scan(true,now);const bytes=Buffer.from(JSON.stringify(event('中文轮次'))+'\n'),split=bytes.indexOf(Buffer.from('中'))+1;
  fs.appendFileSync(file,bytes.subarray(0,split));monitor.scan(false,now+1000);
  fs.renameSync(file,held);monitor.scan(false,now+32000);assert.equal(monitor.tails.size,0);
  fs.renameSync(held,moved);fs.appendFileSync(moved,bytes.subarray(split));monitor.scan(false,now+33000);
  assert.deepEqual(found.map(e=>e.turnId),['中文轮次']);
}));

test('an incomplete line containing invalid UTF-8 resumes at its raw byte boundary',()=>fixture(root=>{
  const dir=path.join(root,'sessions');fs.mkdirSync(dir);const file=path.join(dir,'invalid.jsonl'),held=path.join(root,'held.jsonl');append(file,header());
  const found=[],monitor=new CompletionMonitor({codexHome:root,since:stamp,onNotification:e=>found.push(e)}),now=Date.now();monitor.scan(true,now);
  const first=Buffer.concat([Buffer.from(`{"type":"event_msg","timestamp":"${new Date(stamp+1000).toISOString()}","payload":{"type":"task_complete","turn_id":"a`),Buffer.from([0xff])]);
  fs.appendFileSync(file,first);monitor.scan(false,now+1000);fs.renameSync(file,held);monitor.scan(false,now+32000);
  fs.renameSync(held,file);fs.appendFileSync(file,'b"}}\n');monitor.scan(false,now+33000);
  assert.deepEqual(found.map(e=>e.turnId),['a\uFFFDb']);
}));

test('an evicted oversized line stays discarded and does not retain its contents',()=>fixture(root=>{
  const dir=path.join(root,'sessions');fs.mkdirSync(dir);const file=path.join(dir,'large.jsonl'),held=path.join(root,'held.jsonl');append(file,header());
  const found=[],monitor=new CompletionMonitor({codexHome:root,since:stamp,onNotification:e=>found.push(e)}),now=Date.now();monitor.scan(true,now);
  fs.appendFileSync(file,'x'.repeat(1100000));monitor.scan(false,now+1000);fs.renameSync(file,held);monitor.scan(false,now+32000);
  assert.ok(JSON.stringify([...monitor.checkpoints.values()]).length<700,'Checkpoint must not retain the oversized line');
  fs.renameSync(held,file);fs.appendFileSync(file,'suffix\n');append(file,event('after'));monitor.scan(false,now+33000);
  assert.deepEqual(found.map(e=>e.turnId),['after']);
}));

test('a copied archive continues at the verified byte boundary despite a new file identity',()=>fixture(root=>{
  const dir=path.join(root,'sessions'),archive=path.join(root,'archived_sessions');fs.mkdirSync(dir);fs.mkdirSync(archive);
  const file=path.join(dir,'copy.jsonl'),held=path.join(root,'held.jsonl'),moved=path.join(archive,'copy.jsonl');append(file,header());
  const found=[],monitor=new CompletionMonitor({codexHome:root,since:stamp,onNotification:e=>found.push(e)}),now=Date.now();
  monitor.scan(true,now);append(file,event('one'));monitor.scan(false,now+1000);
  fs.renameSync(file,held);monitor.scan(false,now+32000);fs.copyFileSync(held,moved);append(moved,event('two'));monitor.scan(false,now+33000);
  assert.deepEqual(found.map(e=>e.turnId),['one','two']);
}));

test('a truncated file rewritten past its old offset reads fresh endings without replaying history',()=>fixture(root=>{
  const dir=path.join(root,'sessions');fs.mkdirSync(dir);const file=path.join(dir,'rotate.jsonl'),held=path.join(root,'held.jsonl');append(file,header());
  const found=[],monitor=new CompletionMonitor({codexHome:root,since:stamp,onNotification:e=>found.push(e)}),now=Date.now();
  monitor.scan(true,now);append(file,event('old'));monitor.scan(false,now+1000);fs.renameSync(file,held);monitor.scan(false,now+32000);
  fs.writeFileSync(held,JSON.stringify(header())+'\n'+JSON.stringify(event('stale'))+'\n'+JSON.stringify(event('new','task_complete',{},now+33000))+'\n');
  fs.renameSync(held,file);monitor.scan(false,now+33000);assert.deepEqual(found.map(e=>e.turnId),['old','new']);
}));

test('a replaced file with unread backlog preserves older, previously unprocessed completions',()=>fixture(root=>{
  const dir=path.join(root,'sessions'),archive=path.join(root,'archived_sessions');fs.mkdirSync(dir);fs.mkdirSync(archive);
  const file=path.join(dir,'backlog.jsonl'),held=path.join(root,'held.jsonl'),moved=path.join(archive,'backlog.jsonl');append(file,header());
  const found=[],monitor=new CompletionMonitor({codexHome:root,since:stamp,onNotification:e=>found.push(e)}),now=Date.now();monitor.scan(true,now);
  fs.appendFileSync(file,' '.repeat(4*1024*1024)+'\n');append(file,event('unread'));monitor.scan(false,now+1000);
  fs.renameSync(file,held);monitor.scan(false,now+32000);
  fs.writeFileSync(moved,JSON.stringify(header())+'\n'+'x'.repeat(4*1024*1024)+'\n'+JSON.stringify(event('unread'))+'\n');
  monitor.scan(false,now+33000);monitor.scan(false,now+34000);assert.deepEqual(found.map(e=>e.turnId),['unread']);
}));

test('a replaced file preserves a completion whose partial line predates the outage',()=>fixture(root=>{
  const dir=path.join(root,'sessions'),archive=path.join(root,'archived_sessions');fs.mkdirSync(dir);fs.mkdirSync(archive);
  const file=path.join(dir,'partial.jsonl'),held=path.join(root,'held.jsonl'),moved=path.join(archive,'partial.jsonl');append(file,header());
  const found=[],monitor=new CompletionMonitor({codexHome:root,since:stamp,onNotification:e=>found.push(e)}),now=Date.now();monitor.scan(true,now);
  const record=JSON.stringify(event('pre-missing'));fs.appendFileSync(file,record.slice(0,-8));monitor.scan(false,now+1000);
  fs.renameSync(file,held);monitor.scan(false,now+32000);fs.writeFileSync(moved,JSON.stringify(header('cli'))+'\n'+record+'\n');
  monitor.scan(false,now+33000);assert.deepEqual(found.map(e=>e.turnId),['pre-missing']);
}));

test('checkpoint does not contain the contents of a partially read private message',()=>fixture(root=>{
  const dir=path.join(root,'sessions');fs.mkdirSync(dir);const file=path.join(dir,'private.jsonl'),held=path.join(root,'held.jsonl');append(file,header());
  const found=[],monitor=new CompletionMonitor({codexHome:root,since:stamp,onNotification:e=>found.push(e)}),now=Date.now();monitor.scan(true,now);
  const secret='synthetic-private-message-should-not-be-retained';const record=JSON.stringify(event('one','task_complete',{last_agent_message:secret}));
  fs.appendFileSync(file,record.slice(0,-4));monitor.scan(false,now+1000);fs.renameSync(file,held);monitor.scan(false,now+32000);
  const snapshot=JSON.stringify([...monitor.checkpoints.values()]);assert.equal(snapshot.includes(secret),false);assert.ok(snapshot.length<700);
  fs.renameSync(held,file);fs.appendFileSync(file,record.slice(-4)+'\n');monitor.scan(false,now+33000);
  assert.deepEqual(found.map(e=>e.turnId),['one']);
}));

test('temporary boundary read failure retains the checkpoint and retries without replay',()=>fixture(root=>{
  const dir=path.join(root,'sessions');fs.mkdirSync(dir);const file=path.join(dir,'blocked.jsonl'),held=path.join(root,'held.jsonl');append(file,header());
  const found=[],monitor=new CompletionMonitor({codexHome:root,since:stamp,onNotification:e=>found.push(e)}),now=Date.now();monitor.scan(true,now);
  append(file,event('one'));monitor.scan(false,now+1000);fs.renameSync(file,held);monitor.scan(false,now+32000);
  const checkpoint=monitor.checkpoints.get('blocked.jsonl');assert.ok(checkpoint.proof);
  fs.renameSync(held,file);append(file,event('two'));
  const originalRead=fs.readSync;let injected=0;
  fs.readSync=(fd,buffer,offset,length,position)=>{
    if(length===checkpoint.proof.length && position===checkpoint.offset-checkpoint.proof.length){injected++;const error=new Error('simulated access failure');error.code='EACCES';throw error;}
    return originalRead(fd,buffer,offset,length,position);
  };
  try{monitor.scan(false,now+33000);}finally{fs.readSync=originalRead;}
  assert.equal(injected,1);assert.equal(monitor.tails.has('blocked.jsonl'),false);assert.equal(monitor.checkpoints.has('blocked.jsonl'),true);
  assert.deepEqual(found.map(e=>e.turnId),['one']);monitor.scan(false,now+34000);
  assert.deepEqual(found.map(e=>e.turnId),['one','two']);
}));

test('baseline checkpoint detects truncate and rewrite even if the new file is larger',()=>fixture(root=>{
  const dir=path.join(root,'sessions');fs.mkdirSync(dir);const file=path.join(dir,'baseline.jsonl'),held=path.join(root,'held.jsonl');append(file,header());
  append(file,event('preexisting','task_complete',{},stamp-1000));
  const found=[],monitor=new CompletionMonitor({codexHome:root,since:stamp,onNotification:e=>found.push(e)}),now=Date.now();monitor.scan(true,now);
  fs.renameSync(file,held);monitor.scan(false,now+31000);assert.ok(monitor.checkpoints.get('baseline.jsonl').proof);
  fs.writeFileSync(held,JSON.stringify(header())+'\n'+JSON.stringify(event('fresh','task_complete',{},now+32000))+'\n'+' '.repeat(100));
  fs.renameSync(held,file);monitor.scan(false,now+32000);assert.deepEqual(found.map(e=>e.turnId),['fresh']);
}));

function tinyAppendAcrossEvictions(root,twice){
  const dir=path.join(root,'sessions');fs.mkdirSync(dir);const file=path.join(dir,'baseline-large.jsonl'),held=path.join(root,'held.jsonl');
  const old=Array.from({length:5000},(_,i)=>JSON.stringify(event('historical-'+i))+'\n').join('');
  fs.writeFileSync(file,JSON.stringify(header())+'\n'+old);
  const found=[],monitor=new CompletionMonitor({codexHome:root,since:stamp,onNotification:e=>found.push(e)}),now=Date.now();
  monitor.scan(true,now);fs.appendFileSync(file,'x');monitor.scan(false,now+1000);
  fs.renameSync(file,held);monitor.scan(false,now+32000);
  if(twice){
    fs.renameSync(held,file);monitor.scan(false,now+33000);fs.appendFileSync(file,'y');monitor.scan(false,now+34000);
    fs.renameSync(file,held);monitor.scan(false,now+65000);
  }
  fs.appendFileSync(held,'\n');append(held,event('fresh'));fs.renameSync(held,file);monitor.scan(false,now+66000);
  assert.equal(found.length,1,'Historical completions must not replay');assert.equal(found[0].turnId,'fresh');
}
test('baseline small append preserves the boundary without replaying old completions',()=>fixture(root=>tinyAppendAcrossEvictions(root,false)));
test('checkpoint small append preserves the boundary after a second outage',()=>fixture(root=>tinyAppendAcrossEvictions(root,true)));

test('small baseline boundary owns its bytes without retaining the 64 KiB header buffer',()=>fixture(root=>{
  const dir=path.join(root,'sessions');fs.mkdirSync(dir);const file=path.join(dir,'small.jsonl');append(file,header());
  const monitor=new CompletionMonitor({codexHome:root,since:stamp});monitor.scan(true);
  const bytes=monitor.tails.get('small.jsonl').boundaryBytes;
  assert.ok(bytes.length>0 && bytes.length<=64);assert.equal(bytes.buffer.byteLength,bytes.length);
}));

test('checkpoint capacity stays at 4096 and an evicted session can still deliver a new completion',t=>fixture(root=>{
  const dir=path.join(root,'sessions'),held=path.join(root,'held');fs.mkdirSync(dir);
  const found=[],monitor=new CompletionMonitor({codexHome:root,since:stamp,onNotification:e=>found.push(e)}),now=Date.now(),count=4097;
  const names=Array.from({length:count},(_,i)=>'s'+String(i).padStart(4,'0')+'.jsonl');
  for(const name of names)append(path.join(dir,name),header());monitor.scan(true,now);
  for(const name of names)append(path.join(dir,name),event('old'));monitor.scan(false,now+1000);assert.equal(found.length,count);
  fs.renameSync(dir,held);monitor.scan(false,now+32000);assert.equal(monitor.checkpoints.size,4096);
  const evicted=names.find(name=>!monitor.checkpoints.has(name));assert.ok(evicted);
  append(path.join(held,evicted),event('new'));fs.renameSync(held,dir);monitor.scan(false,now+33000);
  const after=found.slice(count),replayed=after.filter(e=>e.turnId==='old').length;
  assert.equal(after.filter(e=>e.turnId==='new').length,1);assert.ok(replayed<=1);
  t.diagnostic(`A checkpoint evicted by the 4096-session limit replayed ${replayed} historical completion(s) in this fixture.`);
}));
