import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import path from 'node:path';import os from 'node:os';import {spawn} from 'node:child_process';import {fileURLToPath} from 'node:url';import {randomUUID} from 'node:crypto';
import {stopOwned} from '../src/install.mjs';import {processIdentity} from '../runtime/process-identity.mjs';
import {stopRecoveringProgram} from '../src/core/install-recovery.mjs';
const app=fileURLToPath(new URL('../',import.meta.url)),pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
function temporary(t){const base=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-owner-'));t.after(()=>{assert.equal(path.dirname(base),path.resolve(os.tmpdir()));fs.rmSync(base,{recursive:true,force:true});});return base;}
test('installer stop waits for both the GUI and detached supervisor',{skip:process.platform!=='win32',timeout:10000},async t=>{
 const base=temporary(t),dataDir=path.join(base,'data'),target=path.join(base,'program');fs.mkdirSync(dataDir);fs.mkdirSync(target);const children=[];
 try{
  for(const [file,delay]of [['stop.flag',0],['supervisor-stop.flag',1300]]){
   const child=spawn(process.execPath,['-e',`const fs=require('node:fs');const timer=setInterval(()=>{if(fs.existsSync(process.argv[1])){clearInterval(timer);setTimeout(()=>process.exit(0),${delay});}},15);`,path.join(dataDir,file)],{windowsHide:true,stdio:'ignore'});children.push(child);
   fs.writeFileSync(path.join(dataDir,file==='stop.flag'?'runtime.json':'supervisor-status.json'),JSON.stringify({pid:child.pid,processStartedTicks:processIdentity(child.pid)?.startedTicks,appDir:target}));
  }
  await stopOwned({dataDir,target,task:{exists:false}});await pause(30);assert.equal(children.every(child=>child.exitCode===0),true,'directory swap must wait for the slow supervisor as well as the GUI');
 }finally{for(const child of children)if(child.exitCode===null){const exited=new Promise(resolve=>child.once('exit',resolve));child.kill();await exited;}}
});
test('installer also waits for a GUI published after its first owner snapshot',{timeout:10000},async t=>{
 const base=temporary(t),dataDir=path.join(base,'data'),target=path.join(base,'program');fs.mkdirSync(dataDir);fs.mkdirSync(target);const children=[];
 try{
  for(const [kind,delay]of [['supervisor',300],['gui',1000]]){
   const file=path.join(dataDir,kind==='gui'?'runtime.json':'supervisor-status.json'),ready=path.join(dataDir,kind+'.ready');
   const source=`const fs=require('node:fs');const file=${JSON.stringify(file)},root=${JSON.stringify(target)};const write=()=>fs.writeFileSync(file,JSON.stringify({pid:process.pid,appDir:root}));if(${JSON.stringify(kind)}==='supervisor')write();fs.writeFileSync(${JSON.stringify(ready)},'ready');const timer=setInterval(()=>{if(fs.existsSync(${JSON.stringify(path.join(dataDir,'stop.flag'))})){clearInterval(timer);if(${JSON.stringify(kind)}==='gui')setTimeout(write,100);setTimeout(()=>process.exit(0),${delay});}},10);`;
   const child=spawn(process.execPath,['-e',source],{windowsHide:true,stdio:'ignore'});children.push(child);
   for(let n=0;n<100&&!fs.existsSync(ready)&&child.exitCode===null;n++)await pause(10);assert.equal(fs.existsSync(ready),true);
  }
  await stopOwned({dataDir,target,task:{exists:false}});await pause(30);assert.ok(children.every(child=>child.exitCode===0),'a late GUI must finish before directory exchange');
 }finally{for(const child of children)if(child.exitCode===null){const exited=new Promise(resolve=>child.once('exit',resolve));child.kill();await exited;}}
});
for(const [phase,currentToken,allowed]of [['staging',false,false],['waiting-health',false,false],['waiting-health',true,true]])test('supervisor install gate: '+phase+' / '+(currentToken?'new owner':'old owner'),{timeout:10000},async t=>{
 const base=temporary(t),root=path.join(base,'program'),dataDir=path.join(base,'data'),token=randomUUID(),marker=path.join(dataDir,'gui-started.txt');fs.mkdirSync(dataDir);fs.mkdirSync(root);
 fs.cpSync(path.join(app,'src'),path.join(root,'src'),{recursive:true});fs.cpSync(path.join(app,'runtime'),path.join(root,'runtime'),{recursive:true});fs.cpSync(path.join(app,'.codex-plugin'),path.join(root,'.codex-plugin'),{recursive:true});
 fs.writeFileSync(path.join(root,'src/windows/native.mjs'),'export class NativeWindows {hosts(){return [];}valid(){return false;}close(){}}');
 fs.writeFileSync(path.join(root,'package.json'),JSON.stringify({type:'module',main:'main.cjs'}));fs.writeFileSync(path.join(root,'main.cjs'),`require('node:fs').appendFileSync(${JSON.stringify(marker)},'gui\\n');`);
 fs.writeFileSync(path.join(root,'installation.json'),JSON.stringify({appDir:root,dataDir,version:'1.3.6',electronPath:process.execPath,installTransaction:currentToken?token:'previous-install'}));fs.writeFileSync(path.join(dataDir,'settings.json'),JSON.stringify({followHost:false}));
 const launcher=path.join(dataDir,'launcher/GPTNiang.Start.exe');
 fs.writeFileSync(path.join(dataDir,'javascript-install-journal.json'),JSON.stringify({schema:1,token,root,dataDir,transaction:path.join(dataDir,'install-js-'+token),stage:root+'.stage-'+token,backup:root+'.rollback-'+token,phase,ownerPid:process.pid,ownerStartedTicks:processIdentity(process.pid)?.startedTicks,plan:{target:root,dataDir,launcherPath:launcher,taskName:'isolated',sid:'isolated',shortcut:path.join(base,'start.lnk'),marketplaceRoot:base},snapshots:{bootstrap:[[launcher,null],[path.join(path.dirname(launcher),'launcher.json'),null],[path.join(path.dirname(launcher),'launcher.json.bak'),null]],flags:{},identity:{}}}));
 const child=spawn(process.execPath,[path.join(root,'src/supervisor.mjs')],{windowsHide:true,stdio:'pipe'});let error='';child.stderr.on('data',bytes=>error+=bytes);const exited=new Promise((resolve,reject)=>{child.once('exit',resolve);child.once('error',reject);});
 try{
  await pause(1800);assert.equal(child.exitCode,null,error);assert.equal(fs.existsSync(marker),allowed,'only the newly installed supervisor may start the health-check GUI');
 }finally{
  fs.writeFileSync(path.join(dataDir,'supervisor-stop.flag'),'test complete');for(let n=0;n<40&&child.exitCode===null;n++)await pause(100);
  const stopped=child.exitCode===0;if(child.exitCode===null)child.kill();await exited;assert.equal(stopped,true,'stop flags must still be honored during an active installation: '+error);
 }
});
for(const name of ['runtime.json','supervisor-status.json'])test('stop refuses foreign '+name+' before writing control flags',async t=>{
 const base=temporary(t),dataDir=path.join(base,'data');fs.mkdirSync(dataDir);fs.writeFileSync(path.join(dataDir,name),JSON.stringify({pid:process.pid,appDir:path.join(base,'someone-else')}));
 await assert.rejects(stopOwned({target:path.join(base,'ours'),dataDir,task:{exists:false}}),/另一个挂件/);
 assert.equal(fs.existsSync(path.join(dataDir,'stop.flag')),false);assert.equal(fs.existsSync(path.join(dataDir,'supervisor-stop.flag')),false);
});
for(const name of ['runtime.json','supervisor-status.json'])test('recovery refuses foreign '+name+' before writing control flags',async t=>{
 const base=temporary(t),dataDir=path.join(base,'data');fs.mkdirSync(dataDir);fs.writeFileSync(path.join(dataDir,name),JSON.stringify({pid:process.pid,appDir:path.join(base,'someone-else')}));
 let stopped=false;
 await assert.rejects(stopRecoveringProgram({root:path.join(base,'ours'),dataDir,token:randomUUID(),plan:{taskName:'isolated',launcherPath:path.join(base,'launcher.exe'),task:{exists:false}}},op=>{if(op==='task-info')return {exists:false};stopped=true;}),/归属|另一个挂件/);
 assert.equal(stopped,false);assert.equal(fs.existsSync(path.join(dataDir,'stop.flag')),false);assert.equal(fs.existsSync(path.join(dataDir,'supervisor-stop.flag')),false);
});
test('supervisor stop cancels a GUI that has not published its runtime yet',{timeout:10000},async t=>{
 const base=temporary(t),root=path.join(base,'program'),dataDir=path.join(base,'data');fs.mkdirSync(dataDir);fs.mkdirSync(root);
 for(const name of ['src','runtime','.codex-plugin'])fs.cpSync(path.join(app,name),path.join(root,name),{recursive:true});
 fs.writeFileSync(path.join(root,'src/windows/native.mjs'),'export class NativeWindows {hosts(){return [];}valid(){return false;}close(){}}');
 fs.writeFileSync(path.join(root,'package.json'),JSON.stringify({type:'module',main:'main.cjs'}));
 const pidFile=path.join(dataDir,'pending-pid.json'),marker=path.join(dataDir,'late-gui.txt');
 fs.writeFileSync(path.join(root,'main.cjs'),`const fs=require('node:fs');fs.writeFileSync(${JSON.stringify(pidFile)},JSON.stringify({pid:process.pid}));setTimeout(()=>fs.writeFileSync(${JSON.stringify(marker)},'late GUI'),4000);setInterval(()=>{},1000);`);
 fs.writeFileSync(path.join(root,'installation.json'),JSON.stringify({appDir:root,dataDir,version:'1.3.6',electronPath:process.execPath}));fs.writeFileSync(path.join(dataDir,'settings.json'),JSON.stringify({followHost:false}));
 const child=spawn(process.execPath,[path.join(root,'src/supervisor.mjs')],{windowsHide:true,stdio:'ignore'}),exited=new Promise(resolve=>child.once('exit',resolve));let pending;
 try{
  for(let n=0;n<60&&!fs.existsSync(pidFile)&&child.exitCode===null;n++)await pause(50);
  assert.equal(fs.existsSync(pidFile),true,'real pending child must start');pending=JSON.parse(fs.readFileSync(pidFile));pending.startedTicks=processIdentity(pending.pid)?.startedTicks;
  fs.writeFileSync(path.join(dataDir,'supervisor-stop.flag'),'stop during GUI startup');
  for(let n=0;n<40&&child.exitCode===null;n++)await pause(50);assert.equal(child.exitCode,0,'supervisor must exit');
  for(let n=0;n<20&&processIdentity(pending.pid)?.startedTicks===pending.startedTicks;n++)await pause(50);
  assert.notEqual(processIdentity(pending.pid)?.startedTicks,pending.startedTicks,'pending GUI must not outlive the stopped supervisor');
  assert.equal(fs.existsSync(marker),false);
 }finally{
  if(child.exitCode===null)child.kill();await exited;
  if(pending?.startedTicks&&processIdentity(pending.pid)?.startedTicks===pending.startedTicks)process.kill(pending.pid);
 }
});
