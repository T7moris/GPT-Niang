import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import vm from 'node:vm';
import {EventEmitter} from 'node:events';
import childProcess from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {Updater} from '../src/core/updater.mjs';

// These checks do not import Electron, create windows or launch child processes.
const app=fileURLToPath(new URL('../',import.meta.url));
const source=name=>fs.readFileSync(path.join(app,name),'utf8');
test('the headless guard refuses external programs before they can start',{
  skip:globalThis[Symbol.for('gpt-niang.headless-guard')]!==true,
},()=>{
  for(const name of ['spawn','spawnSync','exec','execSync','execFile','execFileSync','fork'])
    assert.throws(()=>childProcess[name]('__headless_guard_probe__'),{code:'HEADLESS_PROCESS_BLOCKED'});
});
function temporary(t,prefix='gpt-headless-updater-'){
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),prefix));
  t.after(()=>{assert.equal(path.dirname(directory),path.resolve(os.tmpdir()));fs.rmSync(directory,{recursive:true,force:true});});
  return directory;
}

test('a failed automatic-update preference write retains the saved in-memory choice',t=>{
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-headless-state-'));
  t.after(()=>{
    assert.equal(path.dirname(directory),path.resolve(os.tmpdir()));
    fs.rmSync(directory,{recursive:true,force:true});
  });
  const file=path.join(directory,'update-preferences.json');
  fs.writeFileSync(file,JSON.stringify({automatic:true,custom:'preserve'}));
  const updater=new Updater({root:app,dataDir:directory,version:'1.3.6',candidate:true});
  const before=fs.readFileSync(file),original=fs.writeFileSync;
  fs.writeFileSync=function(target,...args){
    if(String(target).startsWith(file+'.'))throw Object.assign(Error('injected disk full'),{code:'ENOSPC'});
    return original.call(this,target,...args);
  };
  try{assert.throws(()=>updater.automatic(false),/injected disk full/);}
  finally{fs.writeFileSync=original;}
  assert.equal(updater.preferences.automatic,true);
  assert.equal(updater.preferences.custom,'preserve');
  assert.deepEqual(fs.readFileSync(file),before);
});

for(const reply of [undefined,null,{ok:'yes',result:'invalid'}])test('update I/O rejects a malformed reply safely: '+JSON.stringify(reply),async()=>{
  let worker;
  class Worker extends EventEmitter{constructor(){super();worker=this;}}
  const code=source('src/core/update-io.mjs');
  const context={Worker,URL};
  vm.createContext(context);
  vm.runInContext(code.slice(code.indexOf('export function')).replace('export function','function').replace("new URL('../update-io-worker.mjs',import.meta.url)","new URL('file:///headless/update-worker.mjs')"),context);
  const result=context.runUpdateIO({kind:'stage'});
  assert.doesNotThrow(()=>worker.emit('message',reply));
  await assert.rejects(result,/更新文件处理/);
});

for(const operation of ['end','cancel'])test('a stray drag '+operation+' cannot rewrite settings',()=>{
  const code=source('src/main.mjs'),start=code.indexOf('  ipcMain.on("drag",'),end=code.indexOf('  let frameTiming =',start);
  let handler,saves=0;
  const context={ipcMain:{on:(_name,callback)=>{handler=callback;}},widgetEvent:()=>true,temporary:null,drag:null,native:{cursor:()=>({x:0,y:0})},save:()=>{saves++;}};
  vm.createContext(context);vm.runInContext(code.slice(start,end),context);
  handler({}, {op:operation});
  assert.equal(saves,0);
});

test('a failed program lock releases the update lock and reports a retryable error',async t=>{
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-headless-lock-'));
  t.after(()=>{
    assert.equal(path.dirname(directory),path.resolve(os.tmpdir()));
    fs.rmSync(directory,{recursive:true,force:true});
  });
  const updater=new Updater({root:app,dataDir:directory,version:'1.3.6',candidate:false});
  updater.state={status:'ready'};
  const original=fs.mkdirSync;
  fs.mkdirSync=function(target,...args){
    if(path.resolve(String(target))===path.join(directory,'update-agent-lock'))
      throw Object.assign(Error('injected permission failure'),{code:'EACCES'});
    return original.call(this,target,...args);
  };
  try{await assert.doesNotReject(updater.install());}
  finally{fs.mkdirSync=original;}
  assert.equal(updater.busy,false);
  assert.equal(updater.state.status,'error');
  assert.match(updater.state.message,/injected permission failure/);
  assert.equal(fs.existsSync(path.join(directory,'javascript-update.lock')),false);
});

test('a manual update error is returned to its menu instead of escaping as a rejected promise',async()=>{
  const code=source('src/main.mjs'),start=code.indexOf('  ipcMain.handle("command",'),end=code.indexOf('  native.listen(',start);
  let handler;
  const failure=Promise.reject(Error('injected check failure'));failure.catch(()=>{});
  const context={ipcMain:{handle:(_name,callback)=>{handler=callback;}},trusted:()=>true,editor:null,bench:null,updater:{check:()=>failure}};
  vm.createContext(context);vm.runInContext(code.slice(start,end),context);
  const result=await handler({sender:{id:1}},'update-check');
  assert.equal(result.ok,false);assert.match(result.error,/injected check failure/);
});

for(const operation of ['check','install'])test('an unexpected background update '+operation+' failure preserves the running widget',async t=>{
  const dataDir=temporary(t),updater=new Updater({root:app,dataDir,version:'1.3.6',candidate:false});
  updater.state={status:operation==='install'?'ready':'idle',nextCheckAt:0};updater.startedAt=0;
  const failure=Promise.reject(Error('injected background failure'));failure.catch(()=>{});
  updater[operation]=()=>failure;
  updater.tick(true);await Promise.resolve();
  assert.equal(updater.state.status,'error');assert.match(updater.state.message,/injected background failure/);
  assert.equal(updater.busy,false);
});

test('a background error remains visible when update-state persistence is temporarily unavailable',t=>{
  const dataDir=temporary(t);let notifications=0;
  const updater=new Updater({root:app,dataDir,version:'1.3.6',candidate:true,onChange:()=>{notifications++;}});
  updater.reconcile=()=>{throw Error('injected unreadable update state');};
  const original=fs.writeFileSync;
  fs.writeFileSync=function(target,...args){
    if(String(target).startsWith(path.join(dataDir,'javascript-update-state.json')+'.'))throw Error('injected state write failure');
    return original.call(this,target,...args);
  };
  try{assert.doesNotThrow(()=>updater.tick(true));}
  finally{fs.writeFileSync=original;}
  assert.equal(updater.state.status,'error');assert.match(updater.state.message,/injected unreadable update state/);
  assert.equal(notifications,1);
});
