import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {CompletionMonitor, parseWorkStartRecord, recoverWorkingTurn} from '../runtime/completion-monitor.mjs';
const record = (type, id, extras={}) => JSON.stringify({timestamp:new Date().toISOString(),type:'event_msg',payload:{type,turn_id:id,...extras}})+'\n';
function fixture(run){const home=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-work-monitor-'));try{fs.mkdirSync(path.join(home,'sessions'));return run(home);}finally{fs.rmSync(home,{recursive:true,force:true});}}
function create(home,name,body='',source='cli'){const file=path.join(home,'sessions',name+'.jsonl');fs.writeFileSync(file,JSON.stringify({type:'session_meta',payload:{source}})+'\n'+body);return file;}
test('working is aggregated across conversations and duplicate ends do not stop another turn',()=>fixture(home=>{
 const a=create(home,'a'),b=create(home,'b'),states=[],notifications=[];
 const m=new CompletionMonitor({codexHome:home,onWorkState:s=>states.push(s),onNotification:n=>notifications.push(n)});m.scan(true);
 fs.appendFileSync(a,record('task_started','a1'));m.scan();
 fs.appendFileSync(b,record('turn_started','b1'));m.scan();
 fs.appendFileSync(a,record('task_complete','a1'));m.scan();
 fs.appendFileSync(a,record('turn_complete','a1'));m.scan();
 assert.equal(m.activeTurns.size,1);assert.equal(notifications.length,1);
 fs.appendFileSync(b,record('turn_aborted','b1'));m.scan();
 assert.deepEqual(states.map(s=>s.activeTurns),[0,1,2,1,0]);assert.equal(notifications.at(-1).success,false);
}));
test('restart recovers a recent running turn without replaying completed or stale turns',()=>fixture(home=>{
 create(home,'done',record('task_started','done')+record('task_complete','done'));
 const active=create(home,'active',record('task_started','running'));
 const stale=create(home,'stale',record('task_started','old'));const date=new Date(Date.now()-180000);fs.utimesSync(stale,date,date);
 const notifications=[],states=[],m=new CompletionMonitor({codexHome:home,onNotification:n=>notifications.push(n),onWorkState:s=>states.push(s)});m.scan(true);
 assert.equal(m.activeTurns.size,1);assert.equal(states[0].working,true);assert.equal(notifications.length,0);
 fs.appendFileSync(active,record('task_complete','running',{error:{message:'failed'}}));m.scan();
 assert.equal(states.at(-1).working,false);assert.equal(notifications[0].success,false);
}));
test('subagents, partial records, rotation and removal cannot leave a false busy state',()=>fixture(home=>{
 create(home,'agent',record('task_started','agent'),{subagent:'internal'});
 const file=create(home,'parent'),states=[],m=new CompletionMonitor({codexHome:home,onWorkState:s=>states.push(s)});m.scan(true);
 const start=record('task_started','p');fs.appendFileSync(file,start.slice(0,-1));m.scan();assert.equal(m.activeTurns.size,0);
 fs.appendFileSync(file,'\n');m.scan();assert.equal(m.activeTurns.size,1);
 fs.writeFileSync(file,'');m.scan();assert.equal(m.activeTurns.size,0);
 fs.appendFileSync(file,record('task_started','next'));m.scan();assert.equal(m.activeTurns.size,1);
 fs.unlinkSync(file);m.scan();assert.equal(states.at(-1).working,false);
}));
test('monitor stop resets work and malformed starts are ignored',()=>fixture(home=>{
 assert.equal(parseWorkStartRecord({type:'event_msg',payload:{type:'task_started'}}),null);
 const f=create(home,'parent',record('task_started','running')),states=[];
 assert.equal(recoverWorkingTurn(f).turnId,'running');
 const m=new CompletionMonitor({codexHome:home,onWorkState:s=>states.push(s)});m.scan(true);m.stop();
 assert.equal(states.at(-1).working,false);
}));
test('local completion cannot clear cloud work and cloud completion cannot clear local work',()=>fixture(home=>{
 const file=create(home,'local'),states=[];
 const m=new CompletionMonitor({codexHome:home,onWorkState:s=>states.push(s)});m.scan(true);
 m.setDesktopWorkState({activeCount:2});assert.equal(states.at(-1).working,true);
 fs.appendFileSync(file,record('task_started','local-turn'));m.scan();
 m.setDesktopWorkState({activeCount:0});assert.equal(states.at(-1).working,true);
 m.setDesktopWorkState({activeCount:1});
 fs.appendFileSync(file,record('task_complete','local-turn'));m.scan();
 assert.equal(states.at(-1).working,true);assert.equal(states.at(-1).cloudActiveTasks,1);
 m.setDesktopWorkState({activeCount:0});assert.equal(states.at(-1).working,false);
 m.setDesktopWorkState({activeCount:2});m.stop();assert.equal(states.at(-1).working,false);
}));
