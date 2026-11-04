import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {createHash,randomUUID} from 'node:crypto';
import {pathToFileURL,fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {legacyBridgeFiles,legacyBridgeZip} from '../scripts/build-legacy-bridge.mjs';
import {runLegacyBridge,migrationRelease,reconcileMigrationHandoff} from '../migration/legacy-bridge.mjs';
import {runLegacyMigration,legacyMigrationReady} from '../src/legacy-migration-agent.mjs';
import {cleanupFinishedMigration} from '../src/core/update-cleanup.mjs';
import {install} from '../src/install.mjs';
import {selectRelease} from '../src/core/update-network.mjs';
import {personalState,personalHashes} from './fixtures/personal-state.mjs';
import {zipFixture,packageFiles} from './fixtures/zip-fixture.mjs';
const app=fileURLToPath(new URL('../',import.meta.url)),baseline=path.resolve(app,process.env.GPT_NIANG_LEGACY_ROOT??'../gpt-niang-usage');
const original=await import(pathToFileURL(path.join(baseline,'runtime/update.mjs')));
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
function temporary(t){const dir=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-legacy-bridge-'));t.after(()=>{assert.equal(path.dirname(dir),path.resolve(os.tmpdir()));fs.rmSync(dir,{recursive:true,force:true});});return dir;}
const json=(file,value)=>{fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,JSON.stringify(value));};
for(const live of [false,true])test('handoff '+(live?'retains a live helper cache':'cleans a helper that died before the installer journal'),t=>{
  const root=temporary(t),appDir=path.join(root,'program'),dataDir=path.join(root,'data'),token=randomUUID(),source=path.join(dataDir,'updates',token),job=path.join(dataDir,'migration-jobs',token+'.json'),config={appDir,dataDir};
  json(path.join(appDir,'installation.json'),config);json(path.join(source,'marker.json'),{keep:true});
  json(job,{schema:1,token,root:appDir,dataDir,source});json(path.join(dataDir,'javascript-migration-handoff.json'),{pid:2147483647,startedTicks:'123',token,source});
  fs.writeFileSync(path.join(dataDir,'quotes.json'),'personal content');
  assert.equal(reconcileMigrationHandoff(config,{alive:(_pid,ticks)=>{assert.equal(ticks,'123');return live;}}),!live);
  assert.equal(fs.existsSync(source),live);assert.equal(fs.existsSync(job),live);assert.equal(fs.readFileSync(path.join(dataDir,'quotes.json'),'utf8'),'personal content');
});
test('invalid handoff binding cannot delete a directory outside the exact migration job',t=>{
  const root=temporary(t),appDir=path.join(root,'program'),dataDir=path.join(root,'data'),token=randomUUID(),source=path.join(root,'unrelated');
  json(path.join(source,'marker.json'),{keep:true});json(path.join(dataDir,'javascript-migration-handoff.json'),{pid:2147483647,token,source});
  assert.throws(()=>reconcileMigrationHandoff({appDir,dataDir},{alive:()=>false}),/绑定不匹配/);assert.ok(fs.existsSync(source));
});
function payload(version='1.3.7') {
  const files=packageFiles(version);delete files['integrity.json'];
  files['src/legacy-migration-agent.mjs']=Buffer.from('migration agent fixture');
  files['node_modules/electron/dist/electron.exe']=Buffer.from('runtime fixture');
  files['integrity.json']=Buffer.from(JSON.stringify({version:1,files:Object.fromEntries(Object.entries(files).map(([name,bytes])=>[name,hash(bytes)]))}));
  const bytes=zipFixture(files),base='https://github.com/T7moris/GPT-Niang/releases/download/v'+version+'/',name='gpt-niang-usage-widget-v'+version+'-windows-js.zip';
  const release={tag_name:'v'+version,assets:[{name,browser_download_url:base+name,size:bytes.length,digest:'sha256:'+hash(bytes)},{name:'SHA256SUMS.txt',browser_download_url:base+'SHA256SUMS.txt'}]};
  return {bytes,release,sums:Buffer.from(hash(bytes)+'  '+name+'\n')};
}
test('unmodified old updater accepts the small bridge and revalidates its extracted wrapper',t=>{
  const files=legacyBridgeFiles(baseline,'1.3.7'),bytes=legacyBridgeZip(files,'1.3.7'),zip=original.inspectZip(bytes),dir=temporary(t);
  original.validatePackage(zip,'1.3.7');assert.ok(bytes.length<50*1024*1024);
  assert.ok(!Object.keys(files).some(name=>/\.(exe|dll)$/i.test(name)));
  const archive=path.join(dir,'bridge.zip');fs.writeFileSync(archive,bytes);
  const candidate=original.extractPackage(zip,path.join(dir,'extracted'));
  const checked=spawnSync(process.execPath,[path.join(candidate,'gpt-niang-usage/runtime/update.mjs'),'--validate-package',archive,candidate,'1.3.7',hash(bytes)],{windowsHide:true,encoding:'utf8'});
  assert.equal(checked.status,0,checked.stdout+checked.stderr);
});
test('old and new architectures select separate assets while the installed bridge can migrate at the same version',()=>{
  const {release}=payload(),legacyName='gpt-niang-usage-widget-v1.3.7-windows.zip';
  release.assets.unshift({name:legacyName,size:1,browser_download_url:'https://github.com/T7moris/GPT-Niang/releases/download/v1.3.7/'+legacyName});
  assert.equal(original.selectRelease(release,'1.3.6').zip.name,legacyName);
  assert.ok(selectRelease(release,'1.3.6').zip.name.endsWith('-windows-js.zip'));
  assert.ok(migrationRelease(release,'1.3.7').zip.name.endsWith('-windows-js.zip'));
  assert.equal(selectRelease(release,'1.3.7'),null);assert.equal(migrationRelease(release,'1.3.8'),null);
});
for(const cancel of [false,true])test(`legacy bridge ${cancel?'cancels when automatic updates are disabled during download':'waits for editing to finish before handing off a verified runtime'}`,async t=>{
  const dir=temporary(t),dataDir=path.join(dir,'data'),root=path.join(dir,'legacy'),personal=personalState(dataDir),{bytes,release,sums}=payload();
  fs.mkdirSync(root);json(path.join(dataDir,'update-preferences.json'),{automatic:true});
  const before=personalHashes(dataDir,personal.files),config={appDir:root,dataDir,version:'1.3.7',updateAgent:path.join(dir,'old-agent')};
  let idle=false,waits=0,launches=0,releases=0;
  const legacy={isGitCheckout:()=>false,runUpdate:async()=>{},acquireUpdateLock:()=>({release:()=>releases++}),installIdle:()=>idle};
  const result=await runLegacyBridge(config,{legacy,mode:'automatic',wait:async()=>{waits++;idle=true;},fetchBytes:async url=>{if(url.endsWith('latest'))return Buffer.from(JSON.stringify(release));if(url.endsWith('SHA256SUMS.txt'))return sums;if(cancel)json(path.join(dataDir,'update-preferences.json'),{automatic:false});return bytes;},launch:async({source,executable,job})=>{launches++;assert.ok(waits>0);assert.ok(fs.existsSync(executable));assert.equal(JSON.parse(fs.readFileSync(job)).source,source);return 123;}});
  assert.equal(launches,cancel?0:1);assert.equal(releases,1);
  if(!cancel){assert.equal(result.handedOff,true);assert.deepEqual(personalHashes(dataDir,personal.files),before);}
  else assert.deepEqual(fs.readdirSync(path.join(dataDir,'updates')),[]);
});
test('disabled automatic updates prevent bridge downloads and idle checks include every editor/drag/menu flag',async t=>{
  const dir=temporary(t),dataDir=path.join(dir,'data');personalState(dataDir);
  let fetched=0;await runLegacyBridge({appDir:path.join(dir,'app'),dataDir,version:'1.3.7'},{legacy:{isGitCheckout:()=>false},mode:'automatic',fetchBytes:async()=>{fetched++;}});assert.equal(fetched,0);
  const spec={dataDir,mode:'manual'};
  for(const field of ['editor','menu','drag']){json(path.join(dataDir,'update-idle.json'),{at:Date.now(),pid:process.pid,[field]:true});assert.equal(legacyMigrationReady(spec),false);}
  json(path.join(dataDir,'update-idle.json'),{at:Date.now(),pid:process.pid});assert.equal(legacyMigrationReady(spec),true);
  assert.throws(()=>legacyMigrationReady({...spec,mode:'automatic'}),/自动更新已关闭/);
});
for(const success of [true,false])test(`bridge migration ${success?'commits':'restores the legacy program'} without changing personal content or retaining whole versions`,async t=>{
  const temp=temporary(t),root=path.join(temp,'program'),dataDir=path.join(temp,'data'),token=randomUUID(),source=path.join(dataDir,'updates',token),personal=personalState(dataDir);
  fs.mkdirSync(root);json(path.join(root,'installation.json'),{appDir:root,dataDir,version:'1.3.7'});fs.writeFileSync(path.join(root,'legacy.ps1'),'old');
  const files={'native/GPTNiang.Start.exe':'fixture launcher','new.txt':'new'};
  for(const [name,bytes]of Object.entries(files)){const file=path.join(source,name);fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,bytes);}
  json(path.join(source,'integrity.json'),{});
  const plan={target:root,dataDir,version:'1.3.7',previous:{appDir:root,dataDir,version:'1.3.7'},integrity:{files:Object.fromEntries(Object.entries(files).map(([name,bytes])=>[name,hash(bytes)]))},shortcut:path.join(temp,'startup.lnk'),marketplaceRoot:temp,task:{exists:false},sid:'fixture',taskName:'fixture'};
  const spec={schema:1,token,root,dataDir,source,version:'1.3.7',mode:'manual',parentPid:2147483647};
  const perform=plan=>install(plan,{capturePlugin:()=>null,fileSource:source,stop:async()=>{},windows(){},execute:()=>({status:0,stdout:JSON.stringify({installed:[{pluginId:'gpt-niang-usage@gpt-niang-local',version:'1.3.7',installed:true,enabled:true}]})}),verify:async()=>{if(!success)throw Error('injected unhealthy new program');}});
  if(success)assert.equal((await runLegacyMigration(spec,{plan,perform,ready:()=>true})).ok,true);
  else await assert.rejects(runLegacyMigration(spec,{plan,perform,ready:()=>true}),/injected unhealthy/);
  assert.deepEqual(personalHashes(dataDir,personal.files),personal.files);
  assert.equal(fs.existsSync(path.join(root,'legacy.ps1')),!success);assert.equal(fs.existsSync(path.join(dataDir,'update-installing.json')),false);
  assert.equal(cleanupFinishedMigration(dataDir,()=>false),true);assert.equal(fs.existsSync(source),false);
  assert.deepEqual(fs.readdirSync(temp).filter(name=>/\.(rollback|stage)-/.test(name)),[]);
});
