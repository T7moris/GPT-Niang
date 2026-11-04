import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {createHash} from 'node:crypto';
import {runUpdate} from '../src/core/update-transaction.mjs';
import {claimInstall} from '../src/core/install-recovery.mjs';
import {Updater} from '../src/core/updater.mjs';
const json=(file,value)=>{fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,JSON.stringify(value));};
function fixture(t,version='1.3.5'){
  const temp=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-concurrent-update-'));
  t.after(()=>{assert.equal(path.dirname(temp),path.resolve(os.tmpdir()));fs.rmSync(temp,{recursive:true,force:true});});
  const root=path.join(temp,'program'),dataDir=path.join(temp,'data'),source=path.join(dataDir,'updates/verified');
  json(path.join(root,'package.json'),{name:'gpt-niang-usage',version,architecture:'javascript-electron'});
  json(path.join(root,'installation.json'),{appDir:root,dataDir,electronPath:process.execPath});
  fs.writeFileSync(path.join(root,'old.txt'),'original');fs.mkdirSync(source,{recursive:true});
  const token='concurrency-fixture',job={root,dataDir,source,parentPid:2147483647,version:'1.3.6',token,launcherPath:process.execPath,expected:[{name:'new.txt',hash:createHash('sha256').update('new').digest('hex')}]},jobFile=path.join(temp,'job.json');
  json(jobFile,job);return {temp,root,dataDir,source,job,jobFile};
}
const resume={launcherResume:['-e','process.exit(0)']};
test('a running installer excludes the real update agent from changing the same program',async t=>{
  const {root,dataDir,jobFile}=fixture(t),release=claimInstall(dataDir);assert.ok(release);
  try{await runUpdate(jobFile);assert.equal(fs.readFileSync(path.join(root,'old.txt'),'utf8'),'original');assert.equal(fs.existsSync(path.join(dataDir,'javascript-update-journal.json')),false);}
  finally{release();}
});
for(const [version,fromVersion,message]of [['2.0.0',undefined,/必须高于/],['1.3.5','1.3.4',/已经改变/]])
test('a stale updater cannot overwrite installed version '+version,async t=>{
  const {root,jobFile,job}=fixture(t,version);json(jobFile,{...job,fromVersion});
  await assert.rejects(runUpdate(jobFile,resume),message);
  assert.equal(JSON.parse(fs.readFileSync(path.join(root,'package.json'))).version,version);
  assert.equal(fs.readFileSync(path.join(root,'old.txt'),'utf8'),'original');
});
test('a failed update recovery is retryable after its external obstruction is gone',async t=>{
  const {root,dataDir,jobFile,job}=fixture(t),backup=root+'.rollback-'+job.token,staging=root+'.staging-'+job.token;
  fs.renameSync(root,backup);json(path.join(dataDir,'javascript-update-journal.json'),{...job,backup,staging,phase:'recovery-failed',ownerPid:2147483647});
  await runUpdate(jobFile,{...resume,recover:true});
  assert.equal(fs.readFileSync(path.join(root,'old.txt'),'utf8'),'original');
  const result=JSON.parse(fs.readFileSync(path.join(dataDir,'javascript-update-result.json')));
  assert.equal(result.ok,false);assert.equal(result.recovered,true);assert.equal(fs.existsSync(backup),false);
});
test('pending recovery blocks new downloads and status follows its eventual restoration',async t=>{
  const {root,dataDir,job}=fixture(t);let fetched=0;
  const updater=new Updater({root,dataDir,version:'1.3.5',candidate:true,fetchBytes:async()=>{fetched++;throw Error('must not fetch');}});
  updater.state={status:'installing',transactionId:job.token};const at=Date.now();
  json(path.join(dataDir,'javascript-update-journal.json'),{...job,phase:'recovery-failed'});
  json(path.join(dataDir,'javascript-update-result.json'),{ok:false,recovered:false,token:job.token,root,at,error:'locked'});
  updater.reconcile();assert.match(updater.state.message,/恢复尚未完成/);await updater.check('manual');assert.equal(fetched,0);
  json(path.join(dataDir,'javascript-update-journal.json'),{...job,phase:'rolled-back'});
  json(path.join(dataDir,'javascript-update-result.json'),{ok:false,recovered:true,token:job.token,root,at:at+1,error:'restored'});
  updater.reconcile();assert.equal(updater.state.recoveryPending,false);assert.match(updater.state.message,/已恢复原版本/);
});
test('a durable rollback finishes the UI state even when its separate result cannot be written',t=>{
  const {root,dataDir,job}=fixture(t),updater=new Updater({root,dataDir,version:'1.3.5',candidate:true});
  updater.state={status:'installing',transactionId:job.token};
  json(path.join(dataDir,'javascript-update-journal.json'),{...job,phase:'rolled-back',error:'restored from journal',at:Date.now()});
  fs.mkdirSync(path.join(dataDir,'javascript-update-result.json'));
  updater.reconcile();assert.equal(updater.state.status,'error');assert.equal(updater.state.recoveryPending,false);assert.match(updater.state.message,/已恢复原版本：restored from journal/);
});
