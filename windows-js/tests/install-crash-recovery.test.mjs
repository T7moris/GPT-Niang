import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn,spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {recoverInstall,readInstallRecord,prepareInstallRecovery} from '../src/core/install-recovery.mjs';
import {cleanupFinishedInstall,cleanupFinishedMigration} from '../src/core/update-cleanup.mjs';
import {ownerAlive} from '../src/core/update-transaction.mjs';
import {personalHashes} from './fixtures/personal-state.mjs';
import {fixtureWindows} from './fixtures/install-crash.mjs';
import {install} from '../src/install.mjs';
import {runLegacyMigration} from '../src/legacy-migration-agent.mjs';
const app=fileURLToPath(new URL('../',import.meta.url)),fixture=path.join(app,'tests/fixtures/install-crash.mjs');
const read=file=>JSON.parse(fs.readFileSync(file,'utf8'));
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
function temporary(t){const root=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-install-crash-'));t.after(()=>{assert.equal(path.dirname(root),path.resolve(os.tmpdir()));fs.rmSync(root,{recursive:true,force:true});});return root;}
test('installation recovery ignores a configured directory as its Node executable',t=>{
  const base=temporary(t),root=path.join(base,'program'),transaction=path.join(base,'transaction');fs.mkdirSync(root);fs.mkdirSync(transaction);
  const recovery=prepareInstallRecovery({root,transaction,plan:{nodePath:base}},app);
  assert.equal(recovery.executable,process.execPath);
});
async function interrupt(root,phase,extra=[]){
  const marker=path.join(root,'checkpoint.json');if(fs.existsSync(marker))fs.unlinkSync(marker);
  const child=spawn(process.execPath,[fixture,root,phase,...extra],{windowsHide:true,stdio:'pipe'});let error='';child.stderr.on('data',bytes=>error+=bytes);
  const exited=new Promise((resolve,reject)=>{child.once('exit',resolve);child.once('error',reject);});
  try{
    for(let n=0;n<200&&!fs.existsSync(marker)&&child.exitCode===null;n++)await pause(50);
    assert.equal(fs.existsSync(marker),true,'checkpoint not reached: '+error);
  }finally{if(child.exitCode===null)child.kill();await exited;}
  assert.equal(ownerAlive(child.pid),false);
}
function preserved(root){
  const dataDir=path.join(root,'data'),personal=read(path.join(root,'personal.json'));
  assert.deepEqual(personalHashes(dataDir,personal.files),personal.files);
  assert.equal(fs.readFileSync(path.join(root,'program/old.txt'),'utf8'),'the original program');
  assert.equal(fs.readFileSync(path.join(root,'startup.lnk'),'utf8'),'old shortcut');
  assert.equal(fs.readFileSync(path.join(dataDir,'supervisor-pause.json'),'utf8'),'original pause');
  assert.equal(fs.existsSync(path.join(dataDir,'stop.flag')),false);
  assert.equal(fs.readFileSync(path.join(root,'.agents/plugins/marketplace.json.bak'),'utf8'),'original market backup');
  assert.deepEqual(fs.readdirSync(root).filter(name=>/\.(?:stage|rollback)-/.test(name)),[]);
  assert.deepEqual(fs.readdirSync(dataDir).filter(name=>name.startsWith('install-js-')),[]);
}
for(const phase of ['staging','arming-task','moving-old','moving-new','new-in-place','registering-plugin','waiting-health'])
test('forced installer termination recovers after '+phase,{timeout:20000},async t=>{
  const root=temporary(t);await interrupt(root,phase);const dataDir=path.join(root,'data');
  if(phase==='moving-new')assert.equal(fs.existsSync(path.join(root,'program')),false,'the directory-swap gap must really be exercised');
  const result=await recoverInstall(dataDir,{windows:fixtureWindows(root),stop:async()=>{},resume:false});
  assert.equal(result.recovered,true);assert.equal(readInstallRecord(dataDir).phase,'rolled-back');
  assert.deepEqual(read(path.join(root,'task.json')),read(path.join(root,'old-task.json')));
  preserved(root);assert.equal(cleanupFinishedMigration(dataDir,()=>false),true);
  assert.equal(fs.existsSync(readInstallRecord(dataDir).migration.source),false);
});
test('recovery can itself be interrupted after the original directory is restored',{timeout:20000},async t=>{
  const root=temporary(t);await interrupt(root,'new-in-place');await interrupt(root,'restoring-system',['--recover']);
  assert.equal(fs.existsSync(path.join(root,'program/old.txt')),true);
  await recoverInstall(path.join(root,'data'),{windows:fixtureWindows(root),stop:async()=>{},resume:false});preserved(root);
});
test('a committed installation is retained and its cleanup is reconstructed after a crash',{timeout:20000},async t=>{
  const root=temporary(t);await interrupt(root,'committed');const dataDir=path.join(root,'data'),journal=readInstallRecord(dataDir);
  assert.equal((await recoverInstall(dataDir)).nothingToRecover,true);
  assert.equal(cleanupFinishedInstall(dataDir,()=>false),true);assert.equal(cleanupFinishedMigration(dataDir,()=>false),true);
  assert.equal(read(path.join(root,'program/package.json')).version,'1.3.7');assert.equal(fs.existsSync(journal.backup),false);
  assert.deepEqual(personalHashes(dataDir,read(path.join(root,'personal.json')).files),read(path.join(root,'personal.json')).files);
});
test('invalid recovery paths and a foreign startup task are preserved without destructive cleanup',{timeout:20000},async t=>{
  const root=temporary(t);await interrupt(root,'new-in-place');const dataDir=path.join(root,'data'),journal=readInstallRecord(dataDir),file=path.join(dataDir,'javascript-install-journal.json');
  fs.writeFileSync(file,JSON.stringify({...journal,backup:path.join(root,'unrelated')}));
  await assert.rejects(recoverInstall(dataDir,{windows:fixtureWindows(root)}),/路径不匹配/);
  assert.equal(fs.readFileSync(path.join(journal.backup,'old.txt'),'utf8'),'the original program');
  fs.writeFileSync(file,JSON.stringify(journal));const foreign={exists:true,command:path.join(root,'unrelated.exe'),arguments:'leave-me'};
  fs.writeFileSync(path.join(root,'task.json'),JSON.stringify(foreign));
  await assert.rejects(recoverInstall(dataDir,{windows:fixtureWindows(root)}),/其他操作更改/);
  assert.deepEqual(read(path.join(root,'task.json')),foreign);assert.ok(fs.existsSync(journal.migration.source));
  fs.writeFileSync(path.join(root,'task.json'),JSON.stringify({exists:true,command:journal.plan.launcherPath,arguments:'--supervise'}));
  await recoverInstall(dataDir,{windows:fixtureWindows(root),resume:false});preserved(root);
});
for(const busy of [true,false])test(busy?'legacy migration rechecks editing after the large staging copy':'incomplete system restoration cannot be mislabeled as a completed rollback',{timeout:20000},async t=>{
  const root=temporary(t);await interrupt(root,'staging');const dataDir=path.join(root,'data'),journal=readInstallRecord(dataDir),plan=read(path.join(root,'plan.json')),spec={...journal.migration,mode:'manual',parentPid:2147483647};
  await recoverInstall(dataDir,{windows:fixtureWindows(root),resume:false});
  let checks=0,touched=0;const fixture=fixtureWindows(root);
  const perform=(plan,options)=>install(plan,{...options,capturePlugin:()=>null,fileSource:spec.source,stop:async()=>{},
    windows:(op,...args)=>{touched++;if(!busy&&op==='task-register'&&fs.readFileSync(args[1]).toString('utf16le').includes('old-task'))throw Error('injected task restoration failure');return fixture(op,...args);},
    execute:()=>({status:0,stdout:JSON.stringify({installed:[{pluginId:'gpt-niang-usage@gpt-niang-local',version:plan.version,installed:true,enabled:true}]})}),verify:async()=>{throw Error('injected unhealthy program');}});
  await assert.rejects(runLegacyMigration(spec,{plan,perform,ready:()=>!busy||++checks===1}),busy?/开始交互/:/恢复未完成/);
  if(busy){assert.equal(touched,0);preserved(root);}
  else{
    assert.equal(read(path.join(dataDir,'javascript-legacy-migration.json')).phase,'recovery-failed');
    assert.equal(cleanupFinishedMigration(dataDir,()=>false),false);assert.ok(fs.existsSync(spec.source));
    await recoverInstall(dataDir,{windows:fixture,stop:async()=>{},resume:false});preserved(root);
  }
});
test('native startup reaches the independent recovery helper while the program directory is absent',{skip:process.platform!=='win32',timeout:25000},async t=>{
  const root=temporary(t);await interrupt(root,'moving-new');const dataDir=path.join(root,'data'),journal=readInstallRecord(dataDir);
  // Mock only Windows registration calls; the real GUI launcher, Node process,
  // journal, file swaps and restoration run normally without touching system tasks.
  const code=path.join(root,'FakeSetup.cs'),log=path.join(root,'setup-calls.jsonl'),literal=value=>'"'+value.replaceAll('\\','\\\\').replaceAll('"','\\"')+'"';
  fs.writeFileSync(code,'using System;using System.IO;using System.Web.Script.Serialization;class FakeSetup{static void Main(string[] args){var json=new JavaScriptSerializer();File.AppendAllText('+literal(log)+',json.Serialize(args)+"\\n");Console.WriteLine("{\\"ok\\":true,\\"exists\\":false}");}}');
  const compiler=path.join(process.env.WINDIR,'Microsoft.NET/Framework64/v4.0.30319/csc.exe'),binary=path.join(journal.recovery.agent,'native/GPTNiang.Setup.exe');
  const built=spawnSync(compiler,['/nologo','/target:exe','/reference:System.Web.Extensions.dll','/out:'+binary,code],{windowsHide:true,encoding:'utf8'});assert.equal(built.status,0,built.stdout+built.stderr);
  const launch=spawn(path.join(dataDir,'launcher/GPTNiang.Start.exe'),['--supervise'],{windowsHide:true,stdio:'ignore'});
  assert.equal(await new Promise((resolve,reject)=>{launch.once('exit',resolve);launch.once('error',reject);}),0);
  for(let n=0;n<150;n++){const current=readInstallRecord(dataDir);if(current.phase==='rolled-back'&&!ownerAlive(current.ownerPid,current.ownerStartedTicks))break;await pause(50);}
  assert.equal(readInstallRecord(dataDir).phase,'rolled-back',JSON.stringify(readInstallRecord(dataDir)));assert.ok(fs.readFileSync(log,'utf8').includes('task-register'));
  assert.equal(cleanupFinishedInstall(dataDir,()=>false),true);
  preserved(root);
});
