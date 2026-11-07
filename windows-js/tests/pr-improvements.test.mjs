import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {readSessionMetadata,MAX_SESSION_HEADER_BYTES} from '../runtime/session-header.mjs';
import {CompletionMonitor} from '../runtime/completion-monitor.mjs';
import {UsageLedger} from '../src/core/usage-ledger.mjs';
import {Scene} from '../src/core/scene.mjs';
import {normalizeSettings} from '../src/core/settings.mjs';
import {AutoQuoteSchedule} from '../src/core/quotes.mjs';
import {parseAutoQuoteInterval} from '../src/core/auto-quote-interval.mjs';
import {stableInstallPaths} from '../src/core/install-paths.mjs';
import {resolveLauncherBinding,resolveLegacyLauncherBinding} from '../src/core/launcher-binding.mjs';
import {DesktopLayerRecovery,activateCodexWindow} from '../src/windows/window-policy.mjs';
import {install} from '../src/install.mjs';
import {createHash} from 'node:crypto';

function temporary(t){const root=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-pr-fixes-'));t.after(()=>{assert.equal(path.dirname(root),path.resolve(os.tmpdir()));fs.rmSync(root,{recursive:true,force:true});});return root;}
const write=(file,record)=>fs.appendFileSync(file,JSON.stringify(record)+'\n');
test('a long UTF-8 session header feeds completion and cost accounting without storing instructions',t=>{
 const root=temporary(t),home=path.join(root,'任意目录'),sessions=path.join(home,'sessions');fs.mkdirSync(sessions,{recursive:true});
 const file=path.join(sessions,'long.jsonl'),marker='PRIVATE_HEADER_DO_NOT_PERSIST';
 write(file,{type:'session_meta',payload:{id:'main',source:'cli',model_provider:'relay',instructions:marker+'龙'.repeat(600000)}});
 const notifications=[],monitor=new CompletionMonitor({codexHome:home,since:1,onNotification:event=>notifications.push(event)});monitor.scan(true);
 write(file,{type:'turn_context',payload:{model:'example',turn_id:'one'}});
 write(file,{type:'event_msg',timestamp:new Date().toISOString(),payload:{type:'token_count',info:{total_token_usage:{input_tokens:100,output_tokens:10},last_token_usage:{input_tokens:100,output_tokens:10}}}});
 write(file,{type:'event_msg',timestamp:new Date().toISOString(),payload:{type:'task_complete',turn_id:'one'}});
 monitor.scan();monitor.scan();assert.equal(notifications.length,1);monitor.stop();
 const dataDir=path.join(root,'data'),ledger=new UsageLedger({dataDir,codexHome:home});
 ledger.scan();ledger.scan();assert.equal(ledger.snapshot().all.input,100);assert.equal(ledger.snapshot().all.output,10);ledger.close();
 const bytes=fs.readFileSync(path.join(dataDir,'usage-ledger.sqlite'));assert.equal(bytes.includes(marker),false);assert.ok(bytes.length<100000);
});
test('partial, oversized and subagent headers cannot emit false completion events',t=>{
 const root=temporary(t),sessions=path.join(root,'sessions');fs.mkdirSync(sessions);
 const file=path.join(sessions,'partial.jsonl'),raw=JSON.stringify({type:'session_meta',payload:{source:{subagent:{}},instructions:'x'.repeat(70000)}});
 fs.writeFileSync(file,raw);assert.equal(readSessionMetadata(file).status,'pending');
 const events=[],monitor=new CompletionMonitor({codexHome:root,since:1,onNotification:event=>events.push(event)});monitor.scan();
 fs.appendFileSync(file,'\n');write(file,{type:'event_msg',timestamp:new Date().toISOString(),payload:{type:'task_complete',turn_id:'agent'}});monitor.scan();assert.equal(events.length,0);monitor.stop();
 fs.writeFileSync(file,'x'.repeat(MAX_SESSION_HEADER_BYTES+1));assert.equal(readSessionMetadata(file).status,'too-large');
});
test('independent continuous quotes preserve the old cycle and still close by bubble click',()=>{
 let now=10000,next=0;const settings=normalizeSettings({bubbleTapAdvance:true}),scene=new Scene({settings,quote:()=>String(++next),now:()=>now});
 scene.characterClick();assert.equal(scene.mode,'quota');scene.characterClick();assert.equal(scene.text,'1');scene.characterClick();assert.equal(scene.collapsed,true);
 settings.characterQuoteRepeat=true;scene.characterClick();assert.equal(scene.mode,'quota');
 now+=100;scene.characterClick();assert.equal(scene.text,'2');scene.characterClick();assert.equal(scene.text,'3');assert.equal(scene.collapsed,false);scene.bubbleClick();assert.equal(scene.collapsed,true);
 assert.equal(normalizeSettings({}).characterQuoteRepeat,false);
});
test('custom quote intervals validate units, persist old and new values, and never catch up after hiding',()=>{
 assert.equal(parseAutoQuoteInterval('1.5','minutes'),90);assert.equal(parseAutoQuoteInterval('0.5','hours'),1800);assert.equal(parseAutoQuoteInterval('10.25','seconds'),10.25);
 for(const [raw,unit]of [['9','seconds'],['25','hours'],['NaN','seconds'],['1e2','seconds'],['1','days'],['','minutes']])assert.throws(()=>parseAutoQuoteInterval(raw,unit));
 assert.equal(normalizeSettings({autoQuoteIntervalSeconds:90}).autoQuoteIntervalSeconds,90);assert.equal(normalizeSettings({autoQuoteIntervalSeconds:86401}).autoQuoteIntervalSeconds,300);
 const schedule=new AutoQuoteSchedule({autoQuoteEnabled:true,autoQuoteIntervalSeconds:90},1000);schedule.configure(true,10.25,1000);
 schedule.due(1000,true,false);for(let now=2000;now<11000;now+=1000)assert.equal(schedule.due(now,true,false),false);
 assert.equal(schedule.due(11250,true,false),true);assert.equal(schedule.due(11250,true,false),false);
 schedule.due(12000,false,false);assert.equal(schedule.due(20000,true,false),false);assert.equal(schedule.count,1);
});
test('fresh installation paths stay physical across redirected LOCALAPPDATA environments',()=>{
 const profile=path.resolve('用户 资料'),a=stableInstallPaths({USERPROFILE:profile,LOCALAPPDATA:path.resolve('physical')}),b=stableInstallPaths({USERPROFILE:profile,LOCALAPPDATA:path.resolve('MSIX/private')});
 assert.deepEqual(a,b);assert.equal(a.dataDir,path.join(profile,'.gpt-niang','state'));assert.notEqual(a.target,a.dataDir);
 assert.throws(()=>stableInstallPaths({LOCALAPPDATA:path.resolve('private')}));assert.throws(()=>stableInstallPaths({USERPROFILE:'relative'}));
});
test('a missing launcher binding recovers only from matching installation and startup identity',()=>{
 const target=path.resolve('app'),dataDir=path.resolve('state'),sid='owner',launcherPath=path.join(dataDir,'launcher','GPTNiang.Start.exe');
 const previous={appDir:target,dataDir,sid,launcherPath},task={exists:true,command:launcherPath,arguments:'--supervise',actions:1,level:0,logon:3,sid,directory:path.dirname(launcherPath)};
 const options={exists:false,previous,target,dataDir,sid,launcherPath,task,link:{exists:false}};
 assert.equal(resolveLauncherBinding(options).recovered,true);
 for(const change of [{exists:true,binding:null},{exists:true,binding:{...previous,sid:'other'}},{previous:{...previous,dataDir:path.resolve('other')}},{previous:{...previous,candidate:true}},{task:{...task,sid:'other'}},{task:{...task,directory:path.resolve('other')}},{previous:null}])assert.throws(()=>resolveLauncherBinding({...options,...change}));
 assert.equal(resolveLauncherBinding({...options,exists:true,binding:previous}).recovered,false);
 const agent=path.resolve('legacy-agent'),legacy={exists:false,previous:{appDir:target,dataDir,updateAgent:agent},target,dataDir,sid,agent,task};
 assert.equal(resolveLegacyLauncherBinding(legacy).recovered,true);assert.throws(()=>resolveLegacyLauncherBinding({...legacy,exists:true,binding:null}));assert.throws(()=>resolveLegacyLauncherBinding({...legacy,previous:{...legacy.previous,updateAgent:target}}));
});
test('desktop recovery checks actual covering order, respects unrelated topmost windows and throttles repairs',()=>{
 let now=1000,front=2,above=2,topmostFront=false;const calls=[],recovery=new DesktopLayerRecovery({now:()=>now});
 const native={topmost:h=>h===1||topmostFront,foreground:()=>front,visible:()=>true,pid:h=>h,rect:()=>({left:0,top:0,right:100,bottom:100}),previous:h=>h===1?above:0,band:(h,value)=>calls.push(['band',h,value]),reassertTopmost:h=>calls.push(['repair',h])};
 recovery.synchronize(native,1,true);assert.deepEqual(calls,[['repair',1]]);recovery.synchronize(native,1,true);assert.equal(calls.length,1);
 now+=1000;above=0;recovery.synchronize(native,1,true);assert.equal(calls.length,1);
 now+=1000;above=2;topmostFront=true;recovery.synchronize(native,1,true);assert.equal(calls.length,1);
 front=1;recovery.synchronize(native,1,true);assert.equal(calls.length,1);recovery.synchronize(native,1,false);assert.deepEqual(calls.at(-1),['band',1,false]);assert.equal(recovery.checked.size,0);
});
test('completion click activation restores a validated minimized host and never activates an unrelated preferred window',()=>{
 const calls=[],native={isCodex:h=>[2,3].includes(h),findCodex:()=>3,hosts:()=>[],minimized:h=>h===2,restoreWindow:h=>calls.push(['restore',h]),foregroundWindow:h=>{calls.push(['activate',h]);return true;}};
 assert.equal(activateCodexWindow(native,2),true);assert.deepEqual(calls,[['restore',2],['activate',2]]);calls.length=0;
 activateCodexWindow(native,999);assert.deepEqual(calls,[['activate',3]]);
 assert.equal(activateCodexWindow({...native,isCodex:()=>false,findCodex:()=>0}),false);
});
for(const legacy of [false,true])test(`a failed ${legacy?'legacy':'JS'} upgrade restores its missing binding and old program`,async t=>{
 const root=temporary(t),target=path.join(root,'program'),source=path.join(root,'source'),dataDir=path.join(root,'data');
 fs.mkdirSync(target);fs.mkdirSync(dataDir);fs.mkdirSync(path.join(source,'native'),{recursive:true});
 fs.writeFileSync(path.join(target,'old.txt'),'original');fs.writeFileSync(path.join(source,'native/GPTNiang.Start.exe'),'fixture');
 const hash=createHash('sha256').update('fixture').digest('hex');
 const integrity={files:{'native/GPTNiang.Start.exe':hash}};fs.writeFileSync(path.join(source,'integrity.json'),JSON.stringify(integrity));
 const previous={appDir:target,dataDir,...(legacy?{updateAgent:path.join(dataDir,'old-agent')}:{architecture:'javascript-electron'})};
 fs.writeFileSync(path.join(target,'installation.json'),JSON.stringify(previous));
 const plan={target,dataDir,shortcut:path.join(root,'startup.lnk'),marketplaceRoot:root,integrity,previous,version:'1.4.0-beta.3',sid:'owner',taskName:'isolated',task:{exists:false},repairLauncherBinding:!legacy,repairLegacyBinding:legacy};
 const phases=[];
 await assert.rejects(install(plan,{phaseHook:phase=>phases.push(phase),capturePlugin:()=>null,fileSource:source,stop:async()=>{},windows:()=>({exists:false}),execute:()=>({status:0,stdout:JSON.stringify({installed:[{pluginId:'gpt-niang-usage@gpt-niang-local',version:plan.version,installed:true,enabled:true}]})}),verify:async()=>{throw Error('injected health failure');}}),/injected health failure/);
 assert.equal(fs.readFileSync(path.join(target,'old.txt'),'utf8'),'original');
 assert.deepEqual(JSON.parse(fs.readFileSync(legacy?path.join(previous.updateAgent,'binding.json'):path.join(dataDir,'launcher/launcher.json'))),{appDir:target,dataDir,sid:'owner'});
 if(!legacy)assert.ok(phases.indexOf('stopping')<phases.indexOf('arming-launcher'),'release the waiting host before replacing its executable');
});
