import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {monitor,runningScene,endScene,reloadTaskDialogue} from '../runtime/live-tasks.mjs';

test('monitor reads active user sessions without a database and handles fast or interrupted turns',t=>{
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'niang-live-'));
  t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
  const now=Date.now();
  const read=monitor(root);
  const record=(type,payload)=>JSON.stringify({type,timestamp:new Date().toISOString(),payload})+'\n';
  function session(id,folder='sessions',source='vscode'){
    const dir=path.join(root,folder,'2026','02','04');
    fs.mkdirSync(dir,{recursive:true});
    const file=path.join(dir,id+'.jsonl');
    fs.writeFileSync(file,record('session_meta',{id,source})+
      record('event_msg',{type:'task_started',turn_id:id})+
      record('response_item',{type:'message',role:'user',content:[{type:'input_text',text:'任务 '+id}]}));
    return file;
  }
  const a=session('first');
  const b=session('short');
  fs.appendFileSync(b,record('event_msg',{type:'task_complete',turn_id:'short',duration_ms:300}));
  session('hidden','archived_sessions');
  session('agent','sessions',{subagent:{thread_spawn:{}}});
  const snapshot=read();
  assert.deepEqual(snapshot.active.map(t=>t.title),['任务 first']);
  assert.equal(snapshot.completed.length,1);
  assert.equal(snapshot.completed[0].title,'任务 short');
  assert.equal(endScene(snapshot.completed[0]).kind,'fast');
  assert.equal(runningScene(snapshot.active[0],now+25000).kind,'think');
  assert.equal(runningScene(snapshot.active[0],now+95000).kind,'long');
  const abort=record('event_msg',{type:'turn_aborted',turn_id:'first'});
  fs.appendFileSync(a,abort.slice(0,-1));
  assert.equal(read().active.length,1);
  fs.appendFileSync(a,'\n');
  const finished=read();
  assert.equal(finished.active.length,0);
  assert.equal(endScene(finished.completed.find(e=>e.id==='first')).kind,'stopped');
});

test('a state cycles through eight distinct phrases and is stable between display polls',()=>{
  let previous;
  for(let cycle=0;cycle<2;cycle++){
    const phrases=new Set();
    for(let i=0;i<8;i++){
      const task={id:'shuffle-'+cycle+'-'+i,started:0,phaseSince:0,phase:'等你回复',title:'任务'};
      const line=runningScene(task,2000).line;
      assert.equal(runningScene(task,3000).line,line);
      assert.notEqual(line,previous);
      previous=line;phrases.add(line);
    }
    assert.equal(phrases.size,8);
  }
});

test('a long task holds its line for twenty seconds and uses all 32 long-task defaults',async()=>{
  const {runningScene}=await import('../runtime/live-tasks.mjs?fresh-long-deck');
  const task={id:'long-rotation',started:0,phaseSince:0,phase:'正在使用工具',title:'测试'};
  const start=113771;
  assert.equal(runningScene(task,start).line,runningScene(task,start+19999).line);
  const lines=Array.from({length:32},(_,i)=>runningScene(task,start+i*20000).line);
  assert.equal(new Set(lines).size,32);
});

test('saving a one-line custom group updates a running task and restoring the group reuses defaults',t=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'niang-custom-'));
  t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
  const file=path.join(dir,'custom.json');
  const task={id:'custom-rotation',started:0,phaseSince:0,phase:'正在使用工具',title:'测试'};
  const line='换一句自己的！\n我还在～';
  fs.writeFileSync(file,JSON.stringify({version:1,groups:{long:[line]}}));
  reloadTaskDialogue(file);
  assert.equal(runningScene(task,125000).line,line);
  fs.writeFileSync(file,JSON.stringify({version:1,groups:{}}));
  reloadTaskDialogue(file);
  assert.notEqual(runningScene(task,125001).line,line);
});
