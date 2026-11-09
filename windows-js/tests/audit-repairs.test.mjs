import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {WorkerStarter} from '../src/core/worker-starter.mjs';
import {acquireWorkerLock} from '../runtime/worker-state.mjs';
import {widgetUpdating} from '../runtime/refresh-client.mjs';
import {processIdentity} from '../runtime/process-identity.mjs';
import {CompletionMonitor} from '../runtime/completion-monitor.mjs';
import {installationHealthy,assertPluginRegistration} from '../src/core/installation-health.mjs';
import {verifyStarted} from '../src/install.mjs';
import {Updater} from '../src/core/updater.mjs';
import {runUpdateIO} from '../src/core/update-io.mjs';
import {zipFixture,packageFiles} from './fixtures/zip-fixture.mjs';
import {ClickSequence} from '../ui/click-audio.mjs';
import {ClipPlayer} from '../ui/clip-player.mjs';
const app=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
function temporary(t){const dir=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-js-audit-fix-'));t.after(()=>{assert.ok(path.resolve(dir).startsWith(path.resolve(os.tmpdir())+path.sep));fs.rmSync(dir,{recursive:true,force:true,maxRetries:40,retryDelay:50});});return dir;}
const write=(file,value)=>{fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,JSON.stringify(value));};
const pause=ms=>new Promise(r=>setTimeout(r,ms));
const read=file=>JSON.parse(fs.readFileSync(file,'utf8'));

test('GUI reuses a live headless worker and backs off failed restarts',async t=>{
  const dir=temporary(t),lock=await acquireWorkerLock(dir,0);assert.ok(lock);t.after(()=>lock.release());
  write(path.join(dir,'worker-status.json'),{...lock.owner,at:Date.now()});let launched=0,now=Date.now();
  const guard=new WorkerStarter({dataDir:dir,now:()=>now,updating:()=>false,launch:()=>{launched++;return spawn(process.execPath,['-e','process.exit(0)'],{windowsHide:true,stdio:'ignore'});}});
  for(let n=0;n<5;n++){guard.ensure();now+=100;}assert.equal(launched,0);
  await lock.release();guard.healthy=()=>false;
  let child=guard.ensure();await new Promise(r=>child.once('exit',r));guard.ensure();assert.equal(launched,1);
  now+=5000;child=guard.ensure();await new Promise(r=>child.once('exit',r));assert.equal(launched,2);
});

test('desktop music geometry uses the widget DPI instead of the Codex monitor DPI',()=>{
  const code=fs.readFileSync(path.join(app,'src/main.mjs'),'utf8'),start=code.indexOf('  function geometry()'),end=code.indexOf('  function snapshot(',start);
  assert.ok(start>=0&&end>start);
  const context={effectiveLayout:()=>({}),frame:null,lastNormal:null,host:42,handle:7,preview:false,settings:{followHost:false},native:{rect:()=>({}),dpi:h=>h===42?1.5:1}};
  vm.createContext(context);vm.runInContext(code.slice(start,end),context);
  assert.equal(context.geometry().dpi,1);context.settings.followHost=true;assert.equal(context.geometry().dpi,1.5);
});

test('changing audio settings stops an active preview',()=>{
  const code=fs.readFileSync(path.join(app,'ui/widget.mjs'),'utf8'),slice=(a,b)=>code.slice(code.indexOf(a),code.indexOf(b,code.indexOf(a)));
  let stops=0,starts=0;const element=()=>({style:{},classList:{toggle(){}},getAnimations:()=>[],animate(){},getContext:()=>({clearRect(){}})}),els=new Map();
  const c={ClickSequence,source:null,audioContext:{state:'running',destination:{},createBufferSource:()=>({connect:()=>({connect(){}}),start(){starts++},stop(){stops++}}),createGain:()=>({gain:{value:0}})},soundBuffers:{'preview-press':{duration:5}},state:{settings:{soundOn:true,soundVolume:1},layout:{girl:{},tail:{},tailNear:{},menu:{},bubble:{scale:1},mirror:1},scene:{collapsed:false,preview:false,revision:0,mode:'quote',text:'fixture'},colors:{paused:false},music:false},performance,setTimeout,clearTimeout,box(){},$:id=>{if(!els.has(id))els.set(id,element());return els.get(id);},girlWrap:element(),menu:element(),bubble:element(),stage:element(),scene:element(),quote:element(),bubbleAnimation:element(),window:{innerWidth:378},document:{body:element()},rootTransform(){},applyColors(){},lastCollapsed:false,lastPreview:false,lastRevision:0,lastMusic:false,motion:null,bounds:null};
  c.pointer=null;
  c.window.addEventListener=()=>{};c.clipPlayer=new ClipPlayer({context:()=>c.audioContext});
  vm.createContext(c);vm.runInContext(slice('const clickSounds = new ClickSequence({','function play(')+'\nglobalThis.sequence=clickSounds;\n'+slice('function render(value) {','function girlHit('),c);
  c.sequence.preview('press');const before=stops;c.render({settings:{soundOn:false,soundVolume:0}});assert.equal(starts,1);assert.equal(stops-before,1);c.sequence.preview('press');assert.equal(starts,1);
});

test('importing or removing the active character exits music mode',async()=>{
  const code=fs.readFileSync(path.join(app,'src/main.mjs'),'utf8'),start=code.indexOf('} else if (name === "character-import") {'),end=code.indexOf('} else if (name === "character-restore") {',start);
  assert.ok(start>=0&&end>start);let musicStops=0;
  const c={editor:null,win:{},dialog:{showOpenDialog:async()=>({canceled:false,filePaths:['fixture.png']})},runIo:async()=>({id:'custom'}),characters:{display:async id=>({id}),remove(){}},activeImage:{id:'gpt-dragon'},lastImage:'',settings:{characterId:'gpt-dragon'},setMusic(value){if(!value)musicStops++;},save(patch){Object.assign(c.settings,patch);},dialogState:()=>({})};
  c.galleryImages=new Map();
  vm.createContext(c);vm.runInContext('async function command(name,value){if(false){'+code.slice(start,end)+'}}',c);
  await c.command('character-import');assert.equal(c.activeImage.id,'custom');assert.equal(musicStops,1);
  await c.command('character-remove','custom');assert.equal(c.activeImage.id,'gpt-dragon');assert.equal(musicStops,2);
  await c.command('character-remove','unrelated');assert.equal(musicStops,2);
});

test('installer requires the correct supervisor and a GUI for visible or desktop mode',async t=>{
  const dir=temporary(t),root=path.join(dir,'app'),now=Date.now(),start=now-1000,electron=path.join(root,'electron.exe'),node=process.execPath;
  const identity=pid=>pid===11?{pid,path:node,startedAt:start,startedTicks:'11'}:pid===12?{pid,path:electron,startedAt:start,startedTicks:'12'}:null;
  const supervisor={pid:11,processStartedTicks:'11',appDir:root,version:'1.3.5',at:new Date(now).toISOString(),paused:false,widgetRunning:false,visibleWindows:1};
  const runtime={pid:12,processStartedTicks:'12',appDir:root,architecture:'javascript-electron',version:'1.3.5',widget:123,at:now,rendererReady:true};
  const p={root,version:'1.3.5',supervisor,settings:{followHost:true},startedAt:start,now,inspect:identity,electronPath:electron,nodePath:node,requireSupervisor:true};
  assert.equal(installationHealthy(p),false);assert.equal(installationHealthy({...p,supervisor:{...supervisor,visibleWindows:0}}),true);
  assert.equal(installationHealthy({...p,settings:{followHost:false},supervisor:{...supervisor,visibleWindows:0}}),false);
  assert.equal(installationHealthy({...p,runtime,supervisor:{...supervisor,widgetRunning:true}}),true);
  assert.equal(installationHealthy({...p,runtime,supervisor:null}),false);
  assert.equal(installationHealthy({...p,runtime,supervisor:{...supervisor,widgetRunning:true,processStartedTicks:'wrong'}}),false);
  write(path.join(dir,'supervisor-status.json'),supervisor);
  await assert.rejects(verifyStarted({target:root,dataDir:dir,version:'1.3.5',startRequestedAt:start,nodePath:node,electronPath:electron},{timeoutMs:0,inspect:identity,now:()=>now}),/启动检查/);
});

test('plugin registration requires one enabled matching version',()=>{
  const row={pluginId:'gpt-niang-usage@gpt-niang-local',version:'1.3.5',installed:true,enabled:true},wrap=installed=>({status:0,stdout:JSON.stringify({installed})});
  assert.doesNotThrow(()=>assertPluginRegistration(wrap([row]),'1.3.5'));
  assert.throws(()=>assertPluginRegistration(wrap([{...row,enabled:false}]),'1.3.5'));
  assert.throws(()=>assertPluginRegistration(wrap([row,row]),'1.3.5'));
  assert.throws(()=>assertPluginRegistration(wrap([row]),'1.3.6'));
});

test('completed sessions are pruned without losing the current deduplication history',t=>{
  const dir=temporary(t),sessions=path.join(dir,'sessions','2026','10','28');fs.mkdirSync(sessions,{recursive:true});
  const file=path.join(sessions,'rollout-audit.jsonl');fs.writeFileSync(file,JSON.stringify({type:'session_meta',payload:{source:'cli'}})+'\n');
  const monitor=new CompletionMonitor({codexHome:dir,since:0});const now=Date.now();monitor.scan(true,now);assert.equal(monitor.tails.size,1);
  fs.unlinkSync(file);monitor.scan(false,now+31000);assert.equal(monitor.tails.size,0);monitor.stop();assert.equal(monitor.tails.size,0);
});

test('a reused update PID no longer blocks quota reads',t=>{
  if(process.platform!=='win32')return;
  const dir=temporary(t),file=path.join(dir,'update-installing.json'),id=processIdentity(process.pid);assert.ok(id);
  write(file,{pid:process.pid,token:'stale',startedAt:'2000-01-01T00:00:00.000Z'});assert.equal(widgetUpdating(dir),false);
  write(file,{pid:process.pid,token:'live',startedTicks:id.startedTicks});assert.equal(widgetUpdating(dir),true);
  write(file,{pid:process.pid,token:'legacy'});assert.equal(widgetUpdating(dir),true);
});

test('completed update result replaces installing status and ignores other transaction results',t=>{
  const dir=temporary(t),root=path.join(dir,'app'),now=Date.now();write(path.join(dir,'javascript-update-state.json'),{status:'installing',transactionId:'wanted',installStartedAt:now-1000});
  write(path.join(dir,'javascript-update-result.json'),{ok:false,token:'other',error:'other',at:now});
  const updater=new Updater({root,dataDir:dir,version:'1.3.5',candidate:false});assert.equal(updater.state.status,'installing');
  write(path.join(dir,'javascript-update-result.json'),{ok:false,token:'wanted',root,error:'fixture failure',at:now+1});updater.tick(false);assert.equal(updater.state.status,'error');assert.match(updater.state.message,/fixture failure/);
});

test('a committed journal completes the update status even when result writing was interrupted',t=>{
  const dir=temporary(t),root=path.join(dir,'app'),now=Date.now();
  write(path.join(dir,'javascript-update-state.json'),{status:'installing',transactionId:'current',installStartedAt:now-1000});
  write(path.join(dir,'javascript-update-journal.json'),{phase:'committed',token:'current',root,version:'1.3.6',at:now});
  const updater=new Updater({root,dataDir:dir,version:'1.3.6',candidate:false});assert.equal(updater.state.status,'current');assert.match(updater.state.message,/1\.3\.6/);
});

test('an interrupted preparation with no journal does not leave update permanently busy',t=>{
  const dir=temporary(t),root=path.join(dir,'app');write(path.join(dir,'javascript-update-state.json'),{status:'preparing',transactionId:'missing',installStartedAt:Date.now()-1000});
  const updater=new Updater({root,dataDir:dir,version:'1.3.5',candidate:false});assert.equal(updater.state.status,'error');assert.match(updater.state.message,/中断/);
});

test('prepared external updater includes the native process identity dependency', {skip:process.platform!=='win32',timeout:15000},async t=>{
  const dir=temporary(t),bytes=zipFixture(packageFiles()),sum=createHash('sha256').update(bytes).digest('hex'),asset={name:'fixture.zip'},sums=Buffer.from(sum+'  fixture.zip\n');
  const staged=await runUpdateIO({kind:'stage',bytes,sums,asset,version:'1.3.6',dataDir:dir});
  const prepared=await runUpdateIO({kind:'prepare',root:app,dataDir:dir,directory:staged.directory,version:'1.3.6',hash:staged.hash,token:'native-dependency-fixture',nodePath:process.execPath,hostPath:process.execPath,parentPid:process.pid});
  const identityUrl=new URL('file:///'+path.join(prepared.agent,'runtime','process-identity.mjs').replaceAll('\\','/')).href;
  const code=`import(${JSON.stringify(identityUrl)}).then(({processIdentity})=>{const result=processIdentity(process.pid);if(!result)process.exit(4);process.stdout.write(result.startedTicks);});`;
  const child=spawn(process.execPath,['-e',code],{cwd:prepared.agent,windowsHide:true,stdio:['ignore','pipe','pipe']});let output='',error='';child.stdout.on('data',b=>output+=b);child.stderr.on('data',b=>error+=b);
  assert.equal(await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',resolve);}),0,error);assert.match(output,/^\d+$/);
});

test('update preparation reuses the verified staged runtime without creating a second host copy',async t=>{
  const dir=temporary(t),files=packageFiles(),runtime='node_modules/electron/dist/electron.exe';
  delete files['integrity.json'];files[runtime]=Buffer.from('verified runtime fixture');
  const digest=b=>createHash('sha256').update(b).digest('hex');
  files['integrity.json']=Buffer.from(JSON.stringify({version:1,files:Object.fromEntries(Object.entries(files).map(([name,bytes])=>[name,digest(bytes)]))}));
  const bytes=zipFixture(files),sums=Buffer.from(digest(bytes)+'  fixture.zip\n');
  const staged=await runUpdateIO({kind:'stage',bytes,sums,asset:{name:'fixture.zip'},version:'1.3.6',dataDir:dir});
  const prepared=await runUpdateIO({kind:'prepare',root:app,dataDir:dir,directory:staged.directory,version:'1.3.6',hash:staged.hash,token:'lean-runtime-fixture',nodePath:path.join(app,'missing-node.exe'),hostPath:process.execPath,parentPid:process.pid});
  assert.equal(prepared.executable,path.join(staged.directory,...runtime.split('/')));
  assert.deepEqual(fs.readFileSync(prepared.executable),files[runtime]);
  assert.equal(fs.existsSync(path.join(prepared.agent,'host')),false);
});

for(const interruptedPhase of ['moving-new','starting','stopping-supervisor'])test(`stable launcher restores the old directory after ${interruptedPhase} interruption`, {skip:process.platform!=='win32',timeout:30000}, async t=>{
  let oldSupervisor;let oldExited;
  t.after(async()=>{if(oldSupervisor?.exitCode===null){oldSupervisor.kill();await oldExited;}});
  const temp=temporary(t),root=path.join(temp,'program'),dataDir=path.join(temp,'data'),token='test-transaction',agent=path.join(dataDir,'update-agent-js',token),source=path.join(dataDir,'updates','fixture'),launcher=path.join(dataDir,'launcher','GPTNiang.Start.exe'),marker=path.join(dataDir,'restarted.json');
  for(const dir of [root,source,path.dirname(launcher),agent])fs.mkdirSync(dir,{recursive:true});
  for(const f of ['src/update-agent.mjs','src/core/update-transaction.mjs','src/core/update-network.mjs','src/core/update-cleanup.mjs','src/core/storage.mjs','src/core/installation-health.mjs','runtime/process-identity.mjs']){const to=path.join(agent,f);fs.mkdirSync(path.dirname(to),{recursive:true});fs.copyFileSync(path.join(app,f),to);}
  fs.cpSync(path.join(app,'node_modules','koffi'),path.join(agent,'node_modules','koffi'),{recursive:true});
  fs.cpSync(path.join(app,'node_modules','@koromix',`koffi-${process.platform}-${process.arch}`),path.join(agent,'node_modules','@koromix',`koffi-${process.platform}-${process.arch}`),{recursive:true});
  const fakeExe=path.join(root,'node_modules','electron','dist','electron.exe');fs.mkdirSync(path.dirname(fakeExe),{recursive:true});fs.copyFileSync(process.execPath,fakeExe);
  fs.mkdirSync(path.join(root,'src'));fs.writeFileSync(path.join(root,'src','start.mjs'),`import fs from 'node:fs';fs.writeFileSync(${JSON.stringify(marker)},JSON.stringify(process.argv));`);
  write(path.join(root,'package.json'),{name:'gpt-niang-usage',version:'1.3.5',architecture:'javascript-electron'});
  write(path.join(root,'installation.json'),{appDir:root,dataDir,electronPath:fakeExe,nodePath:process.execPath,launcherPath:launcher});
  fs.copyFileSync(path.join(app,'native','GPTNiang.Start.exe'),launcher);write(path.join(path.dirname(launcher),'launcher.json'),{appDir:root,dataDir,sid:'fixture'});
  const bytes=Buffer.from(JSON.stringify({name:'gpt-niang-usage',version:'1.3.6',architecture:'javascript-electron'})),digest=b=>createHash('sha256').update(b).digest('hex');
  fs.writeFileSync(path.join(source,'package.json'),bytes);fs.writeFileSync(path.join(source,'verified-package.zip'),'archive');
  const jobFile=path.join(agent,'job.json');write(jobFile,{root,dataDir,source,version:'1.3.6',token,parentPid:2147483647,expected:[{name:'package.json',hash:digest(bytes)}],hash:digest('archive'),agent,executable:process.execPath,job:jobFile,launcherPath:launcher});
  if(interruptedPhase==='stopping-supervisor'){
    const oldScript=path.join(temp,'old-supervisor.mjs'),status=path.join(dataDir,'supervisor-status.json'),flag=path.join(dataDir,'supervisor-stop.flag'),identityUrl=new URL('../runtime/process-identity.mjs',import.meta.url).href;
    fs.writeFileSync(oldScript,`import fs from 'node:fs';import {processIdentity} from ${JSON.stringify(identityUrl)};const id=processIdentity(process.pid);fs.writeFileSync(${JSON.stringify(status)},JSON.stringify({pid:process.pid,appDir:${JSON.stringify(root)},processStartedTicks:id.startedTicks}));setInterval(()=>{if(fs.existsSync(${JSON.stringify(flag)}))process.exit(0);},25);`);
    oldSupervisor=spawn(process.execPath,[oldScript],{windowsHide:true,stdio:'ignore'});oldExited=new Promise(r=>oldSupervisor.once('exit',r));
    for(let i=0;i<100&&!fs.existsSync(status);i++)await pause(30);assert.ok(fs.existsSync(status));
  }
  const driver=path.join(temp,'crash.mjs');fs.writeFileSync(driver,`import {runUpdate} from ${JSON.stringify(new URL('../src/core/update-transaction.mjs',import.meta.url).href)};await runUpdate(${JSON.stringify(jobFile)},{phaseHook:p=>{if(p===${JSON.stringify(interruptedPhase)})process.exit(77)}});`);
  const crash=spawn(process.execPath,[driver],{windowsHide:true,stdio:'ignore'});assert.equal(await new Promise(r=>crash.once('exit',r)),77);assert.equal(fs.existsSync(root),interruptedPhase!=='moving-new');
  if(interruptedPhase!=='stopping-supervisor')fs.writeFileSync(path.join(dataDir,'supervisor-stop.flag'),token);
  const start=spawn(launcher,['--supervise'],{windowsHide:true,stdio:'ignore'});assert.equal(await new Promise(r=>start.once('exit',r)),0);
  for(let i=0;i<150&&!fs.existsSync(marker);i++)await pause(100);
  const diagnostics=Object.fromEntries(['javascript-update-journal.json','javascript-update-result.json','javascript-update-resume-error.json','launcher/launcher-error.txt','supervisor-stop.flag'].map(f=>{try{return [f,fs.readFileSync(path.join(dataDir,f),'utf8')];}catch{return [f,null];}}));
  assert.ok(fs.existsSync(marker),'restored supervisor entry was not restarted: '+JSON.stringify(diagnostics));assert.equal(read(path.join(root,'package.json')).version,'1.3.5');
  assert.equal(read(path.join(dataDir,'javascript-update-journal.json')).phase,'rolled-back');assert.equal(read(path.join(dataDir,'javascript-update-result.json')).ok,false);
  assert.equal(fs.existsSync(path.join(dataDir,'supervisor-stop.flag')),false);
});
