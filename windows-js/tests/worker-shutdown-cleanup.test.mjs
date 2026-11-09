import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import os from 'node:os';import path from 'node:path';import {spawn} from 'node:child_process';import {fileURLToPath} from 'node:url';import {once} from 'node:events';
const app=fileURLToPath(new URL('../',import.meta.url)),pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
test('closing the GUI-owned pipe gracefully reaps an active quota service before the worker exits',{timeout:10000},async t=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-worker-cleanup-'));let worker,closed;
 t.after(async()=>{
  fs.writeFileSync(path.join(root,'emergency-stop'),'stop');
  if(worker?.exitCode===null&&worker?.signalCode===null){worker.kill('SIGKILL');await closed;}
  await pause(100);assert.equal(path.dirname(root),path.resolve(os.tmpdir()));fs.rmSync(root,{recursive:true,force:true,maxRetries:10,retryDelay:50});
 });
 fs.cpSync(path.join(app,'runtime'),path.join(root,'runtime'),{recursive:true});fs.cpSync(path.join(app,'.codex-plugin'),path.join(root,'.codex-plugin'),{recursive:true});
 const dataDir=path.join(root,'state'),started=path.join(root,'service-started'),finished=path.join(root,'service-clean-exit');fs.mkdirSync(dataDir);
 const fake=`const fs=require('node:fs');process.stdin.resume();fs.writeFileSync(${JSON.stringify(started)},'started');const timer=setInterval(()=>{if(fs.existsSync(${JSON.stringify(path.join(root,'emergency-stop'))}))process.exit(0);},20);process.stdin.on('end',()=>{clearInterval(timer);setTimeout(()=>{fs.writeFileSync(${JSON.stringify(finished)},'clean');process.exit(0);},20);});`;
 fs.renameSync(path.join(root,'runtime/usage.mjs'),path.join(root,'runtime/usage-real.mjs'));
 fs.writeFileSync(path.join(root,'runtime/usage.mjs'),`import {spawn} from 'node:child_process';import {readUsage as query} from './usage-real.mjs';export {atomicJson,resolveCodexExecutable,stopUsageQueries} from './usage-real.mjs';export function readUsage(cli,options){return query(cli,{...options,spawnProcess:()=>spawn(process.execPath,['-e',${JSON.stringify(fake)}],{windowsHide:true,stdio:'pipe'})});}`);
 const config=path.join(root,'config.json');fs.writeFileSync(config,JSON.stringify({dataDir,codexPath:process.execPath}));
 worker=spawn(process.execPath,[path.join(root,'runtime/watch.mjs'),config,String(process.pid),'--inherit-stop','--owned-stdin'],{windowsHide:true,stdio:'pipe'});let errors='';worker.stderr.on('data',chunk=>errors+=chunk);worker.stdout.resume();closed=once(worker,'close');
 for(let n=0;n<100&&!fs.existsSync(started)&&worker.exitCode===null;n++)await pause(30);
 assert.equal(fs.existsSync(started),true,errors);worker.stdin.end();const [code]=await closed;assert.equal(code,0,errors);assert.equal(fs.readFileSync(finished,'utf8'),'clean');
 assert.equal(fs.existsSync(path.join(dataDir,'worker-status.json')),false);
});
