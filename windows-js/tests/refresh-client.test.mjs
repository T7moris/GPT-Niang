import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {fileURLToPath} from 'node:url';
import {atomicJson} from '../runtime/usage.mjs';
import {requestRefresh,readPendingRequests,completeRequests} from '../runtime/refresh-client.mjs';
import {acquireWorkerLock,readJson,healthyWorker} from '../runtime/worker-state.mjs';

const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const worker=fileURLToPath(new URL('../runtime/watch.mjs',import.meta.url));
// Missing-CLI fixtures must not discover the developer's installed Codex.
function isolatedWorkerEnv(dir){
  const env={...process.env};
  for(const key of Object.keys(env))if(['localappdata','path'].includes(key.toLowerCase()))delete env[key];
  return {...env,LOCALAPPDATA:dir,PATH:dir,GPT_NIANG_CODEX_APP:path.join(dir,'absent.app')};
}
const mockCli=[
  "const fs=require('node:fs'),readline=require('node:readline');",
  "let account;const send=(id,result)=>process.stdout.write(JSON.stringify({id,result})+'\\n');",
  "readline.createInterface({input:process.stdin}).on('line',line=>{",
  "const request=JSON.parse(line);if(request.id===1)send(1,{});",
  "if(request.id===2){account=JSON.parse(fs.readFileSync('account.json','utf8'));send(2,{account});}",
  "if(request.id===3){fs.appendFileSync('queries.txt',account.email+'\\n');fs.writeFileSync('query-started.json',JSON.stringify(account));setTimeout(()=>send(3,{rateLimits:{primary:{windowDurationMins:300,usedPercent:account.email[0]==='a'?12:61,resetsAt:null}}}),account.email[0]==='a'?1700:20);}",
  "});"
].join('\n');

test('exclusive worker ownership survives stale metadata and cannot be released by an old owner',async()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-niang-lock-'));
  let first,second;
  try {
    atomicJson(path.join(dir,'worker.lock'),{pid:99999999,token:'stale'});
    first=await acquireWorkerLock(dir);
    assert.ok(first);assert.notEqual(first.owner.token,'stale');
    assert.equal(await acquireWorkerLock(dir),null);
    atomicJson(path.join(dir,'worker-status.json'),{...first.owner,at:Date.now()});
    assert.equal(healthyWorker(dir).pid,process.pid);
    atomicJson(path.join(dir,'worker-status.json'),{...first.owner,token:'different',at:Date.now()});
    assert.equal(healthyWorker(dir),null);
    await first.release();first=null;
    second=await acquireWorkerLock(dir);assert.ok(second);
    assert.equal(readJson(path.join(dir,'worker.lock')).token,second.owner.token);
  } finally {
    if(first)await first.release();if(second)await second.release();
    fs.rmSync(dir,{recursive:true,force:true});
  }
});

test('concurrent clients receive correlated results without writing the quota status themselves',async()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-niang-client-'));
  const snapshot={ok:true,queryOk:true,windows:[{minutes:10080,remaining:75,resetsAt:null}],observedAt:123};
  let timer;
  try {
    const startWorker=()=>{
      if(!timer)timer=setTimeout(()=>completeRequests(dir,readPendingRequests(dir),snapshot),30);
    };
    const options={startWorker,pollMs:5,timeoutMs:1000};
    const results=await Promise.all([requestRefresh({dataDir:dir},'unused',options),requestRefresh({dataDir:dir},'unused',options)]);
    assert.deepEqual(results,[snapshot,snapshot]);
    assert.equal(fs.existsSync(path.join(dir,'status.json')),false);
    assert.equal(readPendingRequests(dir).length,0);
    assert.deepEqual(fs.readdirSync(path.join(dir,'refresh-results')),[]);
  } finally {clearTimeout(timer);fs.rmSync(dir,{recursive:true,force:true});}
});

test('refresh timeout cleans its request and does not return an unrelated cached account',async()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-niang-timeout-'));
  try {
    atomicJson(path.join(dir,'status.json'),{ok:true,accountKey:'old-account',windows:[{remaining:99}]});
    const result=await requestRefresh({dataDir:dir},'unused',{startWorker:()=>{},timeoutMs:30,pollMs:5});
    assert.equal(result.ok,false);assert.equal(result.queryOk,false);assert.deepEqual(result.windows,[]);
    assert.equal(readPendingRequests(dir).length,0);
    assert.equal(readJson(path.join(dir,'status.json')).accountKey,'old-account');
  } finally {fs.rmSync(dir,{recursive:true,force:true});}
});

test('a headless client retries an unavailable worker and recovers within its deadline',async()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-niang-restart-'));
  let starts=0;
  const snapshot={ok:true,queryOk:true,windows:[],observedAt:123};
  try {
    const result=await requestRefresh({dataDir:dir},'unused',{timeoutMs:500,pollMs:5,restartIntervalMs:20,startWorker:()=>{
      if(++starts===2)completeRequests(dir,readPendingRequests(dir),snapshot);
    }});
    assert.equal(starts,2);assert.deepEqual(result,snapshot);
  } finally {fs.rmSync(dir,{recursive:true,force:true});}
});

test('two actual worker startups share one writer and recover an absent GUI for headless callers',async()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-niang-workers-'));
  const config={dataDir:dir,nodePath:process.execPath,codexPath:path.join(dir,'missing-codex.exe')};
  const configPath=path.join(dir,'installation.json');
  const children=[];let errors='';
  try {
    atomicJson(configPath,config);
    atomicJson(path.join(dir,'status.json'),{ok:true,accountKey:'old-account',windows:[{remaining:99}]});
    const startWorker=()=>{
      const child=spawn(process.execPath,[worker,configPath,'0'],{env:isolatedWorkerEnv(dir),windowsHide:true,stdio:['ignore','ignore','pipe']});
      child.stderr.on('data',data=>{errors+=data;});children.push(child);
    };
    // Launch both contenders explicitly. A sufficiently fast first worker can
    // become healthy before the second client checks, legitimately avoiding a
    // second automatic startup; that is not an ownership failure.
    startWorker();startWorker();
    const options={startWorker:()=>{},timeoutMs:6000,pollMs:20};
    const results=await Promise.all([requestRefresh(config,configPath,options),requestRefresh(config,configPath,options)]);
    assert.equal(children.length,2);
    assert.ok(results.every(result=>result.queryOk===false && result.windows.length===0),errors);
    const health=healthyWorker(dir);assert.ok(health,errors);
    assert.ok(children.some(child=>child.pid===health.pid));
    assert.equal(results[0].checkedAt,results[1].checkedAt);
    assert.equal(readJson(path.join(dir,'status.json')).ok,false);
    const active=children.find(child=>child.pid===health.pid);
    const exited=once(active,'exit');
    fs.writeFileSync(path.join(dir,'stop.flag'),'test-stop');
    await Promise.race([exited,pause(4000).then(()=>{throw new Error('Worker did not honor stop request');})]);
    assert.equal(fs.existsSync(path.join(dir,'worker.lock')),false);
    assert.equal(fs.existsSync(path.join(dir,'worker-status.json')),false);
  } finally {
    for(const child of children)if(child.exitCode===null && child.signalCode===null){const exited=once(child,'exit');child.kill();await exited;}
    fs.rmSync(dir,{recursive:true,force:true});
  }
});

test('worker exits when its GUI parent exits and releases ownership',async()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-niang-parent-'));
  const parent=spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{windowsHide:true,stdio:'ignore'});
  let child;
  try {
    const configPath=path.join(dir,'installation.json');
    atomicJson(configPath,{dataDir:dir,codexPath:path.join(dir,'missing-codex.exe')});
    child=spawn(process.execPath,[worker,configPath,String(parent.pid)],{env:isolatedWorkerEnv(dir),windowsHide:true,stdio:'ignore'});
    const deadline=Date.now()+4000;
    while(!healthyWorker(dir) && Date.now()<deadline)await pause(20);
    assert.ok(healthyWorker(dir));
    // Observe the worker before stopping its GUI: a correct fast exit can
    // otherwise arrive while awaiting the parent's exit and be missed.
    const childExited=once(child,'exit');
    const parentExited=once(parent,'exit');parent.kill();await parentExited;
    await Promise.race([childExited,pause(4000).then(()=>{throw new Error('Worker outlived its GUI parent');})]);
    assert.equal(fs.existsSync(path.join(dir,'worker.lock')),false);
    assert.equal(fs.existsSync(path.join(dir,'worker-status.json')),false);
  } finally {
    for(const proc of [child,parent])if(proc && proc.exitCode===null && proc.signalCode===null){const exited=once(proc,'exit');proc.kill();await exited;}
    fs.rmSync(dir,{recursive:true,force:true});
  }
});

test('worker ownership recovers after a force-killed worker leaves stale files',{skip:!['win32','darwin'].includes(process.platform)},async()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-niang-crash-'));
  const children=[];
  try {
    const configPath=path.join(dir,'installation.json');
    atomicJson(configPath,{dataDir:dir,codexPath:path.join(dir,'missing-codex.exe')});
    const start=()=>{
      const child=spawn(process.execPath,[worker,configPath,String(process.pid)],{env:isolatedWorkerEnv(dir),windowsHide:true,stdio:'ignore'});
      children.push(child);return child;
    };
    const waitForOwner=async child=>{
      const deadline=Date.now()+4000;
      while(healthyWorker(dir)?.pid!==child.pid && Date.now()<deadline)await pause(20);
      assert.equal(healthyWorker(dir)?.pid,child.pid);
      return readJson(path.join(dir,'worker.lock')).token;
    };
    const first=start(),firstToken=await waitForOwner(first);
    const crashed=once(first,'exit');first.kill(process.platform==='darwin'?'SIGKILL':'SIGTERM');await crashed;
    assert.equal(healthyWorker(dir),null);
    const second=start(),secondToken=await waitForOwner(second);
    assert.notEqual(firstToken,secondToken);
    const stopped=once(second,'exit');fs.writeFileSync(path.join(dir,'stop.flag'),'test-stop');await stopped;
  } finally {
    for(const child of children)if(child.exitCode===null && child.signalCode===null){const exited=once(child,'exit');child.kill();await exited;}
    fs.rmSync(dir,{recursive:true,force:true});
  }
});

for(const mode of ['request-file','refresh-flag'])test('an account switch during a query is followed up for '+mode,async()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-niang-late-'));
  const accountA={type:'chatgpt',email:'a@example.test',planType:'plus'};
  const accountB={type:'chatgpt',email:'b@example.test',planType:'plus'};
  const configPath=path.join(dir,'installation.json');
  const config={dataDir:dir,codexPath:process.execPath};
  let child;
  const waitUntil=async predicate=>{
    const deadline=Date.now()+7000;
    while(!predicate() && Date.now()<deadline)await pause(20);
    assert.ok(predicate());
  };
  try {
    fs.writeFileSync(path.join(dir,'app-server'),mockCli,'utf8');
    atomicJson(configPath,config);atomicJson(path.join(dir,'account.json'),accountA);
    const startWorker=()=>{if(!child)child=spawn(process.execPath,[worker,configPath,'0'],{cwd:dir,windowsHide:true,stdio:'ignore'});};
    const options={startWorker,timeoutMs:8000,pollMs:20};
    const first=requestRefresh(config,configPath,options);
    await waitUntil(()=>readJson(path.join(dir,'query-started.json'))?.email===accountA.email);
    atomicJson(path.join(dir,'account.json'),accountB);
    const second=mode==='request-file'?requestRefresh(config,configPath,options):null;
    if(mode==='refresh-flag')fs.writeFileSync(path.join(dir,'refresh.flag'),'switched-account');
    const previous=await first;assert.equal(previous.windows[0].remaining,88);
    if(second){const next=await second;assert.equal(next.windows[0].remaining,39);assert.notEqual(previous.accountKey,next.accountKey);}
    else await waitUntil(()=>readJson(path.join(dir,'status.json'))?.windows?.[0]?.remaining===39);
    const queries=fs.readFileSync(path.join(dir,'queries.txt'),'utf8').trim().split('\n');
    assert.deepEqual(queries,[accountA.email,accountB.email]);
    const exited=once(child,'exit');fs.writeFileSync(path.join(dir,'stop.flag'),'test-stop');await exited;
  } finally {
    if(child && child.exitCode===null && child.signalCode===null){const exited=once(child,'exit');child.kill();await exited;}
    fs.rmSync(dir,{recursive:true,force:true});
  }
});
