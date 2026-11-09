import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {requestRestart,runRestart,validateRestart,waitForRestart} from '../src/core/restart.mjs';
import {claimProgramChange} from '../src/core/update-transaction.mjs';
const write=(file,value)=>fs.writeFileSync(file,JSON.stringify(value));
function fixture(t){
 const base=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-restart-test-'));t.after(()=>{assert.equal(path.dirname(base),path.resolve(os.tmpdir()));fs.rmSync(base,{recursive:true,force:true});});
 const root=path.join(base,'app'),dataDir=path.join(base,'data'),sid='S-1-5-21-123-1001';fs.mkdirSync(root);fs.mkdirSync(path.join(dataDir,'launcher'),{recursive:true});
 const config={appDir:root,dataDir,sid,version:'1.4.0-beta.3',architecture:'javascript-electron',taskName:'GPT Niang Usage - '+sid,launcherPath:path.join(dataDir,'launcher/GPTNiang.Start.exe')};
 write(path.join(root,'package.json'),{name:'gpt-niang-usage',architecture:config.architecture,version:config.version});write(path.join(root,'installation.json'),config);
 write(path.join(dataDir,'launcher/launcher.json'),{appDir:root,dataDir,sid});fs.writeFileSync(config.launcherPath,'fixture');fs.writeFileSync(path.join(dataDir,'settings.json'),'PERSONAL SETTINGS');
 const task=(args,state=3)=>({exists:true,command:config.launcherPath,arguments:args,directory:path.dirname(config.launcherPath),actions:1,level:0,logon:3,sid,state});
 const tasks=new Map([[config.taskName,task('--supervise',4)]]),events=[];
 const windows=(op,...args)=>{
   if(op==='task-info')return {...(tasks.get(args[0])??{exists:false})};events.push([op,...args]);
   if(op==='task-register'){const raw=fs.readFileSync(args[1]).subarray(2).toString('utf16le');assert.equal(raw.includes('<Triggers>'),false);assert.match(raw,/<DisallowStartIfOnBatteries>false<\/DisallowStartIfOnBatteries>/);assert.match(raw,/<StopIfGoingOnBatteries>false<\/StopIfGoingOnBatteries>/);const arguments_=raw.match(/<Arguments>(.*?)<\/Arguments>/)[1];tasks.set(args[0],task(arguments_));}
   if(op==='task-start')tasks.get(args[0]).state=4;
   if(op==='task-stop')tasks.get(args[0]).state=3;
   if(op==='task-delete')tasks.delete(args[0]);
   return {ok:true};
 };
 const options={sid,windows,approve:async()=>null};
 const stop=async({token,stopTask})=>{await stopTask();for(const name of ['stop.flag','supervisor-stop.flag'])fs.writeFileSync(path.join(dataDir,name),token);events.push(['old-processes-closed']);};
 return {root,dataDir,config,tasks,events,windows,options,stop,task};
}
test('restart requests coalesce and a separate one-shot helper restarts only the bound task',async t=>{
 const f=fixture(t),[a,b]=await Promise.all([requestRestart(f.root,f.options),requestRestart(f.root,f.options)]);assert.equal(a.token,b.token);
 assert.equal(f.events.filter(e=>e[0]==='task-register').length,1);
 assert.equal((await requestRestart(f.root,f.options)).token,a.token);
 await runRestart(f.root,a.token,{...f.options,stop:f.stop,verify:async()=>{assert.equal(fs.existsSync(path.join(f.dataDir,'stop.flag')),false);}});
 const stop=f.events.findIndex(e=>e[0]==='old-processes-closed'),start=f.events.findIndex(e=>e[0]==='task-start'&&e[1]===f.config.taskName);
 assert.ok(start>stop);assert.equal(f.tasks.has(a.taskName),false);
 assert.equal((await waitForRestart(f.dataDir,a.token)).ok,true);assert.equal(fs.readFileSync(path.join(f.dataDir,'settings.json'),'utf8'),'PERSONAL SETTINGS');
 assert.equal(fs.existsSync(path.join(f.dataDir,'restart-task.xml')),false);
});
test('foreign task, binding, user and candidate configurations have no stop side effects',async t=>{
 const f=fixture(t);
 for(const change of [{candidate:true},{sid:'other'},{launcherPath:path.join(f.root,'foreign.exe')}]){
   write(path.join(f.root,'installation.json'),{...f.config,...change});await assert.rejects(requestRestart(f.root,f.options));assert.equal(f.events.length,0);
 }
 write(path.join(f.root,'installation.json'),f.config);f.tasks.get(f.config.taskName).actions=2;
 assert.throws(()=>validateRestart(f.root,f.options));assert.equal(f.events.length,0);
});
test('a foreign existing helper cannot be overwritten or deleted',async t=>{
 const f=fixture(t);f.tasks.set('GPT Niang Restart - '+f.config.sid,{...f.task('--restart-helper foreign'),command:'foreign.exe'});
 await assert.rejects(requestRestart(f.root,f.options),/不属于本安装/);assert.equal(f.events.length,0);
});
test('pending updates and an editor rejection preserve the current installation',async t=>{
 const f=fixture(t);write(path.join(f.dataDir,'javascript-update-journal.json'),{phase:'moving-old'});
 await assert.rejects(requestRestart(f.root,f.options),/更新尚未完成/);assert.equal(f.events.length,0);fs.unlinkSync(path.join(f.dataDir,'javascript-update-journal.json'));
 await assert.rejects(requestRestart(f.root,{...f.options,approve:async()=>{throw Error('save editor first');}}),/save editor first/);assert.equal(f.events.length,0);
});
test('failure restores prior pause flags and reports an error without changing personal files',async t=>{
 const f=fixture(t),pause=path.join(f.dataDir,'supervisor-pause.json');fs.writeFileSync(pause,'original pause');
 const request=await requestRestart(f.root,f.options);
 await assert.rejects(runRestart(f.root,request.token,{...f.options,stop:f.stop,verify:async()=>{throw Error('health fixture failure');}}),/health fixture failure/);
 assert.equal(fs.readFileSync(pause,'utf8'),'original pause');assert.equal(fs.existsSync(path.join(f.dataDir,'stop.flag')),false);
 assert.equal((await waitForRestart(f.dataDir,request.token)).ok,false);assert.equal(f.tasks.has(request.taskName),false);
 assert.equal(fs.readFileSync(path.join(f.dataDir,'settings.json'),'utf8'),'PERSONAL SETTINGS');
});
test('external stop changes are preserved rather than overwritten by restart',async t=>{
 const f=fixture(t),request=await requestRestart(f.root,f.options);
 await assert.rejects(runRestart(f.root,request.token,{...f.options,stop:async args=>{await f.stop(args);fs.writeFileSync(path.join(f.dataDir,'stop.flag'),'external-stop');},verify:async()=>{throw Error('must not reach health');}}),/状态发生变化/);
 assert.equal(fs.readFileSync(path.join(f.dataDir,'stop.flag'),'utf8'),'external-stop');assert.equal(f.tasks.has(request.taskName),false);
});
test('an update arriving after preparation rejects the helper before stopping the app',async t=>{
 const f=fixture(t),request=await requestRestart(f.root,f.options);write(path.join(f.dataDir,'javascript-install-journal.json'),{phase:'staging'});
 await assert.rejects(runRestart(f.root,request.token,{...f.options,stop:async()=>{throw Error('must not stop');}}),/安装或更新尚未完成/);
 assert.equal(f.events.some(e=>e[0]==='task-stop'),false);assert.equal(f.tasks.has(request.taskName),false);assert.equal((await waitForRestart(f.dataDir,request.token)).ok,false);
});
test('a pause removed externally before restart clears flags is not recreated on failure',async t=>{
 const f=fixture(t),pause=path.join(f.dataDir,'supervisor-pause.json');fs.writeFileSync(pause,'original');const request=await requestRestart(f.root,f.options);
 await assert.rejects(runRestart(f.root,request.token,{...f.options,stop:async args=>{await f.stop(args);fs.unlinkSync(pause);},verify:async()=>{throw Error('must not reach health');}}),/状态发生变化/);
 assert.equal(fs.existsSync(pause),false);assert.equal(f.tasks.has(request.taskName),false);
});
test('an active program change lock blocks restart and removes its one-shot helper',async t=>{
 const f=fixture(t),request=await requestRestart(f.root,f.options),release=claimProgramChange(f.dataDir);
 try{await runRestart(f.root,request.token,{...f.options,stop:async()=>{throw Error('must not stop');}});}finally{release();}
 assert.equal(f.events.some(e=>e[0]==='task-stop'),false);assert.equal(f.tasks.has(request.taskName),false);assert.equal((await waitForRestart(f.dataDir,request.token)).ok,false);
});
for(const name of ['stop.flag','supervisor-stop.flag','supervisor-disabled.flag','supervisor-pause.json'])test('a later user stop cancels the pending restart before helper handoff: '+name,async t=>{
 const f=fixture(t),request=await requestRestart(f.root,f.options),file=path.join(f.dataDir,name);
 fs.writeFileSync(file,'later-user-stop');
 await assert.rejects(runRestart(f.root,request.token,{...f.options,stop:f.stop,verify:async()=>{}}),/状态发生变化/);
 assert.equal(fs.readFileSync(file,'utf8'),'later-user-stop');
 assert.equal(f.events.some(e=>e[0]==='task-stop'||e[0]==='task-start'&&e[1]===f.config.taskName),false);
 assert.equal(f.tasks.has(request.taskName),false);assert.equal((await waitForRestart(f.dataDir,request.token)).ok,false);
});
test('removing a pause during helper handoff also cancels restart without restoring it',async t=>{
 const f=fixture(t),file=path.join(f.dataDir,'supervisor-pause.json');fs.writeFileSync(file,'old-pause');
 const request=await requestRestart(f.root,f.options);fs.unlinkSync(file);
 await assert.rejects(runRestart(f.root,request.token,{...f.options,stop:f.stop,verify:async()=>{}}),/状态发生变化/);
 assert.equal(fs.existsSync(file),false);assert.equal(f.events.some(e=>e[0]==='task-stop'),false);
});
test('a stop arriving while GUI approval is pending is not adopted as the restart baseline',async t=>{
 const f=fixture(t),file=path.join(f.dataDir,'supervisor-pause.json');
 const request=await requestRestart(f.root,{...f.options,approve:async()=>{fs.writeFileSync(file,'exit-during-approval');return null;}});
 await assert.rejects(runRestart(f.root,request.token,{...f.options,stop:f.stop,verify:async()=>{}}),/状态发生变化/);
 assert.equal(fs.readFileSync(file,'utf8'),'exit-during-approval');assert.equal(f.events.some(e=>e[0]==='task-stop'),false);
});
test('an unreadable flag during helper preflight releases the program-change lock',async t=>{
 const f=fixture(t),request=await requestRestart(f.root,f.options);fs.mkdirSync(path.join(f.dataDir,'stop.flag'));
 await assert.rejects(runRestart(f.root,request.token,{...f.options,stop:f.stop,verify:async()=>{}}));
 assert.equal(f.events.some(e=>e[0]==='task-stop'),false);assert.equal(f.tasks.has(request.taskName),false);
 const release=claimProgramChange(f.dataDir);assert.ok(release,'a failed preflight must not retain the update/restart lock');release();
});
