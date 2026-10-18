import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {createHash,randomUUID} from 'node:crypto';
import {EventEmitter} from 'node:events';
import {Readable} from 'node:stream';
import {deflateRawSync} from 'node:zlib';
import {spawn,spawnSync} from 'node:child_process';
import {compareVersions,versionParts,selectRelease,verifyHash,inspectZip,validatePackage,extractPackage,validateExtractedPackage,safeZipName,allowedUrl,download,runUpdate,acquireUpdateLock,updatePreferences,checkDue,installIdle,resolveUpdateAgentDir,DAY,RELEASE_API} from '../runtime/update.mjs';
import {requestRefresh} from '../runtime/refresh-client.mjs';

const required=JSON.parse(fs.readFileSync(new URL('../runtime/install-files.json',import.meta.url),'utf8'));
function crc(bytes){let value=0xffffffff;for(const byte of bytes){value^=byte;for(let bit=0;bit<8;bit++)value=(value>>>1)^((value&1)?0xedb88320:0);}return (value^0xffffffff)>>>0;}
export function zipFixture(files,{mode=0x8000,compressed=false,expandedOverride}={}) {
  let offset=0;const local=[],central=[];
  for(const [name,value] of Object.entries(files)) {
    const raw=Buffer.from(name),data=Buffer.from(value),packed=compressed?deflateRawSync(data):data;
    const head=Buffer.alloc(30);head.writeUInt32LE(0x04034b50);head.writeUInt16LE(20,4);head.writeUInt16LE(0x800,6);head.writeUInt16LE(compressed?8:0,8);
    head.writeUInt32LE(crc(data),14);head.writeUInt32LE(packed.length,18);head.writeUInt32LE(expandedOverride??data.length,22);head.writeUInt16LE(raw.length,26);
    const entry=Buffer.alloc(46);entry.writeUInt32LE(0x02014b50);entry.writeUInt16LE(0x314,4);entry.writeUInt16LE(20,6);entry.writeUInt16LE(0x800,8);entry.writeUInt16LE(compressed?8:0,10);
    entry.writeUInt32LE(crc(data),16);entry.writeUInt32LE(packed.length,20);entry.writeUInt32LE(expandedOverride??data.length,24);entry.writeUInt16LE(raw.length,28);entry.writeUInt32LE((mode<<16)>>>0,38);entry.writeUInt32LE(offset,42);
    local.push(head,raw,packed);central.push(entry,raw);offset+=30+raw.length+packed.length;
  }
  const directory=Buffer.concat(central),end=Buffer.alloc(22);end.writeUInt32LE(0x06054b50);end.writeUInt16LE(Object.keys(files).length,8);end.writeUInt16LE(Object.keys(files).length,10);end.writeUInt32LE(directory.length,12);end.writeUInt32LE(offset,16);
  return Buffer.concat([...local,directory,end]);
}
function packageFiles(version='1.3.3') {
  const files=Object.fromEntries(required.map(name=>['GPT娘额度挂件/gpt-niang-usage/'+name,'fixture']));
  for(const name of ['package.json','.codex-plugin/plugin.json'])files['GPT娘额度挂件/gpt-niang-usage/'+name]=JSON.stringify({version});
  files['GPT娘额度挂件/gpt-niang-usage/runtime/install-files.json']=JSON.stringify(required);
  files['GPT娘额度挂件/.agents/plugins/marketplace.json']='{}';return files;
}
function release(bytes,version='1.3.3') {
  const name=`gpt-niang-usage-widget-v${version}-windows.zip`,base=`https://github.com/T7moris/GPT-Niang/releases/download/v${version}/`;
  return {tag_name:'v'+version,assets:[{name,browser_download_url:base+name,size:bytes.length,digest:'sha256:'+createHash('sha256').update(bytes).digest('hex')},{name:'SHA256SUMS.txt',browser_download_url:base+'SHA256SUMS.txt'}]};
}
function temporary(t) {
  // macOS exposes its temporary directory through /var -> /private/var.
  // Give the Windows updater fixture a canonical path without weakening link checks.
  const dir=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'gpt-niang-update-')));
  t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));return dir;
}
function setup(t,bytes=zipFixture(packageFiles())) {
  const dir=temporary(t),config={appDir:path.join(dir,'app','gpt-niang-usage'),dataDir:path.join(dir,'data'),version:'1.3.2'};
  fs.mkdirSync(config.appDir,{recursive:true});fs.mkdirSync(config.dataDir);
  const source=release(bytes),sums=Buffer.from(createHash('sha256').update(bytes).digest('hex')+'  '+source.assets[0].name+'\n');
  const options={agentDir:path.join(dir,'agent'),waitIdle:async()=>true,fetchBytes:async url=>url===RELEASE_API?Buffer.from(JSON.stringify(source)):url.endsWith('SHA256SUMS.txt')?sums:bytes,launch:async()=>{options.installs++;},installs:0};
  return {dir,config,options,source,sums};
}
test('updater uses the configured stable root and profile fallback outside LocalAppData',t=>{
  const profile=temporary(t),configured=path.join(profile,'persisted','agent');
  assert.equal(resolveUpdateAgentDir({updateAgent:configured},{userProfile:path.join(profile,'other')}),configured);
  assert.equal(resolveUpdateAgentDir({},{userProfile:profile}),path.join(profile,'.gpt-niang','update-agent'));
  for(const invalid of ['',null,42,'relative-agent'])assert.throws(()=>resolveUpdateAgentDir({updateAgent:invalid},{userProfile:profile}));
});
test('an update transaction uses config.updateAgent when no test override is supplied',async t=>{
  const {dir,config,options}=setup(t);
  config.updateAgent=path.join(dir,'persisted-agent');delete options.agentDir;
  await runUpdate(config,options);
  assert.equal(options.installs,1);
  assert.equal(JSON.parse(fs.readFileSync(path.join(config.updateAgent,'update-transaction.json'),'utf8')).phase,'prepared');
  assert.equal(fs.existsSync(path.join(dir,'agent')),false);
});
test('stable versions compare numerically and ignore same versions, prereleases and downgrades',()=>{
  assert.equal(compareVersions('v1.10.0','1.9.99'),1);assert.equal(compareVersions('2.0.0','10.0.0'),-1);
  assert.equal(compareVersions('999999999999999999.0.0','999999999999999998.9.9'),1);
  for(const version of ['1.3.3-rc.1','01.3.3','1.3','1.3.3+repack'])assert.equal(versionParts(version),null);
  const r=release(Buffer.alloc(0));assert.equal(selectRelease(r,'1.3.3'),null);assert.equal(selectRelease(r,'2.0.0'),null);
  assert.equal(selectRelease({...r,prerelease:true},'1.3.2'),null);assert.equal(selectRelease({...r,draft:true},'1.3.2'),null);
});
test('release URLs are fixed and arbitrary hosts or assets are rejected',()=>{
  for(const url of ['http://github.com/test','https://example.com/file','https://user:pass@github.com/T7moris/GPT-Niang/releases/download/x/a','https://github.com/evil/repo/releases/download/x/a','https://api.github.com/repos/evil/repo/releases/latest'])assert.throws(()=>allowedUrl(url));
  allowedUrl(RELEASE_API,{api:true});allowedUrl('https://release-assets.githubusercontent.com/x?signature=value');
  const r=release(Buffer.alloc(0));r.assets[0].browser_download_url=r.assets[0].browser_download_url.replace('/v1.3.3/','/v9.0.0/');assert.throws(()=>selectRelease(r,'1.3.2'));
});
test('SHA256SUMS and optional GitHub digest must both match',()=>{
  const bytes=Buffer.from('payload'),r=release(bytes),asset=r.assets[0],sums=Buffer.from(asset.digest.slice(7)+'  '+asset.name+'\n');
  assert.equal(verifyHash(bytes,sums,asset),asset.digest.slice(7));
  assert.throws(()=>verifyHash(Buffer.from('wrong'),sums,asset));assert.throws(()=>verifyHash(bytes,sums,{...asset,digest:'sha256:'+'0'.repeat(64)}));
  assert.throws(()=>verifyHash(bytes,Buffer.concat([sums,sums]),asset));
});
test('ZIP validation rejects traversal, Windows invalid names, links, executables and duplicates',()=>{
  for(const name of ['../bad','root/../bad','/bad','root\\bad','root/a:stream','root/CON.txt','root/a.','root/b ','root/a.exe','root/b.DLL','root/.git/config'])assert.throws(()=>safeZipName(name));
  assert.throws(()=>inspectZip(zipFixture({'root/link':'x'},{mode:0xa000})));
  assert.throws(()=>inspectZip(zipFixture({'root/A.txt':'a','root/a.txt':'b'})));
  assert.throws(()=>inspectZip(zipFixture({'root/file':'a','root/file/child':'b'})));
  assert.throws(()=>inspectZip(zipFixture({'one/a':'a','two/b':'b'})));
});
test('ZIP entry limits, decompression limits, CRC and local path checks precede extraction',()=>{
  assert.throws(()=>inspectZip(zipFixture(Object.fromEntries(Array.from({length:1001},(_,i)=>['root/'+i,''])))));
  assert.throws(()=>inspectZip(zipFixture({'root/bomb':'x'},{compressed:true,expandedOverride:101*1024*1024})));
  const bytes=zipFixture({'root/a':'abc'});bytes[30+6]^=1;assert.throws(()=>inspectZip(bytes));
  const wrong=zipFixture({'root/a':'abc'});wrong[30]^=1;assert.throws(()=>inspectZip(wrong));
  assert.throws(()=>inspectZip(Buffer.alloc(50*1024*1024+1)));
  const normal=inspectZip(zipFixture(packageFiles(),{compressed:true}));validatePackage(normal,'1.3.3');
});
test('version and required-file validation rejects incomplete packages',()=>{
  assert.throws(()=>validatePackage(inspectZip(zipFixture(packageFiles('9.0.0'))),'1.3.3'));
  const files=packageFiles();delete files['GPT娘额度挂件/gpt-niang-usage/runtime/watch.mjs'];assert.throws(()=>validatePackage(inspectZip(zipFixture(files)),'1.3.3'));
});
test('candidate files are compared to the validated archive again before replacement',t=>{
  const dir=temporary(t),bytes=zipFixture(packageFiles()),archive=path.join(dir,'release.zip');fs.writeFileSync(archive,bytes);
  const hash=createHash('sha256').update(bytes).digest('hex'),candidate=extractPackage(inspectZip(bytes),path.join(dir,'extracted'));
  validateExtractedPackage(archive,candidate,'1.3.3',hash);
  fs.writeFileSync(path.join(candidate,'gpt-niang-usage','Install.ps1'),'changed');
  assert.throws(()=>validateExtractedPackage(archive,candidate,'1.3.3',hash));
});
test('manual checks also respect a persisted Retry-After deadline',async t=>{
  const {config,options}=setup(t);let requests=0;
  options.fetchBytes=async()=>{requests++;throw Object.assign(new Error('Rate limited'),{retryAfterMs:DAY*2});};
  await runUpdate(config,options);await runUpdate(config,options);assert.equal(requests,1);assert.equal(options.installs,0);
});
test('auto preferences default on, persist off, and checks wait 30 seconds or a daily deadline',t=>{
  const dir=temporary(t);assert.equal(updatePreferences(dir).automatic,true);
  fs.writeFileSync(path.join(dir,'update-preferences.json'),'{"automatic":false}');assert.equal(updatePreferences(dir).automatic,false);
  assert.equal(checkDue(null,1000,30999),false);assert.equal(checkDue(null,1000,31000),true);
  assert.equal(checkDue({nextCheckAt:DAY},1000,DAY-1),false);assert.equal(checkDue({nextCheckAt:DAY},1000,DAY),true);
});
test('manual update bypasses schedule and repeated requests reuse one download/install',async t=>{
  const {config,options}=setup(t);fs.writeFileSync(path.join(config.dataDir,'update-status.json'),JSON.stringify({nextCheckAt:Date.now()+DAY}));
  let reads=0;const fetch=options.fetchBytes;options.fetchBytes=async(...args)=>{reads++;await new Promise(resolve=>setTimeout(resolve,5));return fetch(...args);};
  const first=runUpdate(config,options),second=runUpdate(config,options);assert.equal(first,second);await first;
  assert.equal(reads,3);assert.equal(options.installs,1);
});
test('automatic disabled makes no request; enabling checks immediately; source checkout is protected',async t=>{
  const {config,options}=setup(t);let requests=0;options.fetchBytes=async()=>{requests++;return Buffer.from(JSON.stringify(release(Buffer.alloc(0),'1.3.2')));};
  fs.writeFileSync(path.join(config.dataDir,'update-preferences.json'),'{"automatic":false}');await runUpdate(config,{...options,mode:'automatic'});assert.equal(requests,0);
  fs.writeFileSync(path.join(config.dataDir,'update-preferences.json'),'{"automatic":true}');fs.writeFileSync(path.join(config.dataDir,'update-status.json'),JSON.stringify({nextCheckAt:Date.now()+DAY}));
  await runUpdate(config,{...options,mode:'automatic-enabled'});assert.equal(requests,1);
  fs.mkdirSync(path.join(path.dirname(config.appDir),'.git'));await runUpdate(config,options);assert.equal(requests,1);
});
test('a disabled toggle before installation cancels automatic work',async t=>{
  const {config,options}=setup(t);options.waitIdle=async()=>{fs.writeFileSync(path.join(config.dataDir,'update-preferences.json'),'{"automatic":false}');return true;};
  await runUpdate(config,{...options,mode:'automatic'});assert.equal(options.installs,0);
  assert.equal(JSON.parse(fs.readFileSync(path.join(config.dataDir,'update-status.json'))).cleanupError,undefined);
  assert.deepEqual(fs.readdirSync(path.join(config.dataDir,'updates')),[]);
});
test('cancelled idle wait removes its download without touching user preferences',async t=>{
  const {config,options}=setup(t);options.waitIdle=async()=>false;
  const preferences=path.join(config.dataDir,'settings.json');fs.writeFileSync(preferences,'{"scale":1.4}');
  await runUpdate(config,{...options,mode:'automatic'});
  assert.equal(JSON.parse(fs.readFileSync(path.join(config.dataDir,'update-status.json'))).cleanupError,undefined);
  assert.equal(options.installs,0);assert.deepEqual(fs.readdirSync(path.join(config.dataDir,'updates')),[]);
  assert.equal(fs.readFileSync(preferences,'utf8'),'{"scale":1.4}');
});
test('pending cleanup failure blocks a new download and preserves its transaction',async t=>{
  const {config,options}=setup(t);fs.mkdirSync(options.agentDir,{recursive:true});
  const journal=path.join(options.agentDir,'update-transaction.json'),record=JSON.stringify({phase:'committed',cleanupPending:true,token:'old'});
  fs.writeFileSync(journal,record);let attempts=0;
  options.cleanup=async()=>{attempts++;throw new Error('Backup is occupied');};
  options.fetchBytes=async()=>assert.fail('Do not accumulate another version before cleanup');
  await runUpdate(config,options);
  assert.equal(attempts,1);assert.equal(fs.readFileSync(journal,'utf8'),record);
  assert.equal(JSON.parse(fs.readFileSync(path.join(config.dataDir,'update-status.json'))).phase,'failed');
});
test('real cleanup helper reclaims an interrupted cache and releases its claim before installation',{skip:process.platform!=='win32'},async t=>{
  const {config,options}=setup(t),token=randomUUID(),job=path.join(config.dataDir,'updates',token);
  fs.mkdirSync(job,{recursive:true});fs.mkdirSync(options.agentDir,{recursive:true});
  fs.writeFileSync(path.join(job,'update-job.json'),JSON.stringify({schema:1,token,appDir:config.appDir,dataDir:config.dataDir}));
  fs.writeFileSync(path.join(job,'release.zip'),'interrupted');
  for(const name of ['update-helper.ps1','update-common.ps1','supervisor-task.ps1','install-preflight.ps1']){
    fs.copyFileSync(new URL('../runtime/'+name,import.meta.url),path.join(options.agentDir,name));
  }
  const executable=path.join(process.env.WINDIR,'System32','WindowsPowerShell','v1.0','powershell.exe');
  const identity=spawnSync(executable,['-NoProfile','-Command','[Security.Principal.WindowsIdentity]::GetCurrent().User.Value'],{windowsHide:true,encoding:'utf8',timeout:15000});
  assert.equal(identity.status,0,identity.stderr);
  fs.writeFileSync(path.join(options.agentDir,'binding.json'),JSON.stringify({sid:identity.stdout.trim(),appDir:config.appDir,dataDir:config.dataDir}));
  options.launch=async()=>{
    assert.equal(fs.existsSync(job),false);
    assert.equal(JSON.parse(fs.readFileSync(path.join(options.agentDir,'update.lock','owner.json'))).helperPid,undefined);
    options.installs++;
  };
  await runUpdate(config,options);assert.equal(options.installs,1);
});
test('idle installation rejects drag, menus, editors, busy workers and expired signals',t=>{
  const {config}=setup(t),now=Date.now(),file=path.join(config.dataDir,'update-idle.json');
  for(const value of [{drag:true},{menu:true},{editor:true},{at:now-5001}]){fs.writeFileSync(file,JSON.stringify({at:now,pid:process.pid,...value}));assert.equal(installIdle(config,'automatic',now),false);}
  fs.writeFileSync(file,JSON.stringify({at:now,pid:process.pid}));assert.equal(installIdle(config,'automatic',now),true);
  fs.writeFileSync(path.join(config.dataDir,'worker-status.json'),'{"busy":true}');assert.equal(installIdle(config,'automatic',now),false);
});
test('invalid hash, malicious ZIP, wrong version, missing files and interrupted downloads never launch installation',async t=>{
  for(const kind of ['hash','zip','version','missing','interrupt','rate-limit']) {
    const files=packageFiles(kind==='version'?'9.0.0':'1.3.3');if(kind==='missing')delete files['GPT娘额度挂件/gpt-niang-usage/widget.xaml'];
    const bytes=zipFixture(kind==='zip'?{'root/../evil':'evil'}:files),{config,options,sums}=setup(t,bytes),fetch=options.fetchBytes;
    options.fetchBytes=async (url,args)=>{
      if(kind==='interrupt')throw new Error('Download interrupted');
      if(kind==='rate-limit')throw Object.assign(new Error('Rate limited'),{retryAfterMs:DAY*2});
      if(kind==='hash' && url.endsWith('SHA256SUMS.txt'))return Buffer.from(sums.toString().replace(/^[a-f\d]/,'X'));
      return fetch(url,args);
    };
    await runUpdate(config,options);assert.equal(options.installs,0,kind);
    const state=JSON.parse(fs.readFileSync(path.join(config.dataDir,'update-status.json')));assert.equal(state.phase,'failed',kind);
    if(kind==='rate-limit')assert.ok(state.nextCheckAt>=Date.now()+DAY*2-1000);
  }
});
test('cross-process lock is exclusive and a foreign token cannot release it',t=>{
  const dir=temporary(t),lock=acquireUpdateLock(dir);assert.equal(acquireUpdateLock(dir),null);
  const ownerFile=path.join(dir,'update.lock','owner.json');fs.writeFileSync(ownerFile,JSON.stringify({pid:process.pid,token:'foreign'}));lock.release();assert.ok(fs.existsSync(ownerFile));
});
test('a damaged transaction is retained and cannot be replaced by another update',async t=>{
  const {config,options}=setup(t);fs.mkdirSync(options.agentDir,{recursive:true});
  const file=path.join(options.agentDir,'update-transaction.json');fs.writeFileSync(file,'{broken');
  options.fetchBytes=async()=>assert.fail('Damaged transaction must block release requests');
  await runUpdate(config,options);assert.equal(fs.readFileSync(file,'utf8'),'{broken');assert.equal(options.installs,0);
});
test('concurrent stale Windows lock recovery grants ownership to one live process',{skip:process.platform!=='win32'},async t=>{
  const dir=temporary(t),lockDir=path.join(dir,'update.lock');fs.mkdirSync(lockDir);fs.writeFileSync(path.join(lockDir,'owner.json'),'{"pid":0,"token":"stale"}');
  const module=new URL('../runtime/update.mjs',import.meta.url).href;
  const code=`import {acquireUpdateLock} from ${JSON.stringify(module)};const lock=acquireUpdateLock(process.argv[1]);console.log(JSON.stringify({token:lock?.owner.token??null}));process.stdin.resume();process.stdin.once('data',()=>{lock?.release();process.exit(0);});`;
  const children=Array.from({length:2},()=>spawn(process.execPath,['--input-type=module','-e',code,dir],{windowsHide:true,stdio:['pipe','pipe','pipe']}));
  t.after(()=>{for(const child of children)if(child.exitCode===null)child.kill();});
  const owners=await Promise.all(children.map(child=>new Promise((resolve,reject)=>{
    const timeout=setTimeout(()=>reject(new Error('Lock bridge timed out')),20000);let out='',err='';
    child.stdout.on('data',chunk=>{out+=chunk;if(out.includes('\n')){clearTimeout(timeout);resolve(JSON.parse(out.split('\n')[0]));}});
    child.stderr.on('data',chunk=>{err+=chunk;});child.on('error',reject);
    child.on('exit',code=>{clearTimeout(timeout);if(code!==0)reject(new Error('Lock bridge failed: '+err));});
  })));
  assert.equal(owners.filter(owner=>owner.token).length,1);
  await Promise.all(children.map(child=>new Promise(resolve=>{child.once('exit',resolve);child.stdin.end('release\n');})));
});
function fakeRequest(status,headers={},chunks=['payload']) {
  return (url,options,callback)=>{
    assert.equal(options.headers.Authorization,undefined);assert.equal(options.headers.Cookie,undefined);
    const request=new EventEmitter();request.setTimeout=()=>request;request.destroy=error=>request.emit('error',error);
    queueMicrotask(()=>{const response=Readable.from(chunks.map(value=>Buffer.from(value)));response.statusCode=status;response.headers=headers;callback(response);});return request;
  };
}
test('HTTP limits, rate limits and unsafe redirects are enforced without credentials',async()=>{
  const url='https://github.com/T7moris/GPT-Niang/releases/download/v1.3.3/file.zip';
  await assert.rejects(download(url,{request:fakeRequest(429,{'retry-after':'172800'})}),error=>error.retryAfterMs>=DAY*2);
  await assert.rejects(download(url,{request:fakeRequest(429,{'retry-after':'60'})}),error=>error.retryAfterMs===60000);
  await assert.rejects(download(url,{limit:3,request:fakeRequest(200,{},['too big'])}));
  await assert.rejects(download(url,{request:fakeRequest(302,{location:'https://evil.example/a'})}));
  await assert.rejects(download(url,{request:fakeRequest(302,{location:'http://['})}));
  assert.equal((await download(url,{request:fakeRequest(200)})).toString(),'payload');
});
test('quota requests return retryable UPDATING without starting a worker',async t=>{
  const {config}=setup(t);fs.writeFileSync(path.join(config.dataDir,'update-installing.json'),JSON.stringify({pid:process.pid}));
  const snapshot=await requestRefresh(config,'unused',{startWorker:()=>assert.fail('Worker must not start')});assert.equal(snapshot.retryable,true);assert.equal(snapshot.errorCode,'UPDATING');
});
