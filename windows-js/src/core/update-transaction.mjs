import fs from 'node:fs';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {createHash,randomUUID} from 'node:crypto';
import {readJson,writeJson,inside,guiEnvironment,samePath,resolveNodeHost} from './storage.mjs';
import {processIdentity,sameProcess} from '../../runtime/process-identity.mjs';
import {installationHealthy} from './installation-health.mjs';
import {removeTransactionDirectory} from './update-cleanup.mjs';
import {compareVersions} from './update-network.mjs';
export const terminalPhases=new Set(['committed','rolled-back']);
const pause=ms=>new Promise(r=>setTimeout(r,ms));
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
export async function renameWithRetry(from,to,{rename=fs.renameSync,attempts=50,delayMs=100}={}){
  for(let n=0;;n++){
    try{rename(from,to);return;}
    catch(error){
      if(!['EBUSY','EPERM','EACCES'].includes(error?.code)||n+1>=attempts)throw error;
      await pause(delayMs);
    }
  }
}
export function ownerAlive(pid,ticks){
  if(!Number.isSafeInteger(pid)||pid<=0)return false;
  try{process.kill(pid,0);}catch(error){return error.code==='EPERM';}
  const identity=processIdentity(pid);
  return !ticks||!identity||sameProcess({pid,startedTicks:ticks},identity);
}
function observedSameProcess(pid,ticks){const identity=processIdentity(pid);return !!(ticks&&identity&&sameProcess({pid,startedTicks:ticks},identity));}
export function claimProgramChange(dataDir){
  const directory=inside(dataDir,'update-agent-lock'),owner=path.join(directory,'owner.json');fs.mkdirSync(dataDir,{recursive:true});
  for(let n=0;n<3;n++){
    try{fs.mkdirSync(directory);const token=randomUUID();writeJson(owner,{pid:process.pid,startedTicks:processIdentity(process.pid)?.startedTicks,token},{backup:false});return()=>{if(readJson(owner)?.token===token){fs.unlinkSync(owner);fs.rmdirSync(directory);}};}
    catch(error){if(error.code!=='EEXIST')throw error;const old=readJson(owner);if(old?ownerAlive(old.pid,old.startedTicks):Date.now()-fs.statSync(directory).mtimeMs<10000)return null;const stale='update-agent-lock.stale-'+randomUUID();try{fs.renameSync(directory,inside(dataDir,stale));removeTransactionDirectory(dataDir,stale);}catch{return null;}}
  }
  return null;
}
function validate(job){
  if(!job||!path.isAbsolute(job.root)||!path.isAbsolute(job.dataDir)||!path.isAbsolute(job.source)||!Number.isSafeInteger(job.parentPid)||!Array.isArray(job.expected)||!job.expected.length||!/^[a-z0-9-]{1,100}$/i.test(job.token??''))throw Error('无效更新任务');
  const root=path.resolve(job.root),dataDir=path.resolve(job.dataDir),source=path.resolve(job.source),parent=path.dirname(root);
  const within=(base,file)=>{const relative=path.relative(base,file);return !!relative&&!path.isAbsolute(relative)&&relative!=='..'&&!relative.startsWith('..'+path.sep);};
  if(samePath(root,parent)||!within(path.join(dataDir,'updates'),source)||samePath(dataDir,root)||within(root,dataDir)||within(dataDir,root))throw Error('更新目录无效');
  return {root,dataDir,source,backup:path.join(parent,path.basename(root)+'.rollback-'+job.token),staging:path.join(parent,path.basename(root)+'.staging-'+job.token)};
}
function clearMarker(dataDir,token){const file=path.join(dataDir,'update-installing.json');if(readJson(file)?.token===token)try{fs.unlinkSync(file);}catch{}}
async function launch(executable,args,cwd,node=false){
  const child=spawn(executable,args,{cwd,detached:true,windowsHide:true,stdio:'ignore',env:{...guiEnvironment(),...(node?{ELECTRON_RUN_AS_NODE:'1'}:{})}});
  await new Promise((resolve,reject)=>{child.once('spawn',resolve);child.once('error',reject);});child.unref();return child;
}
export async function runUpdate(jobFile,{recover=false,launcherResume=null,phaseHook=()=>{},healthTimeoutMs=20000}={}){
  const job=readJson(jobFile),paths=validate(job),{root,dataDir,source,backup,staging}=paths,journalFile=path.join(dataDir,'javascript-update-journal.json');
  let journal=readJson(journalFile);
  if(recover){
    if(!journal||journal.token!==job.token||!samePath(journal.root,root)||!samePath(journal.dataDir,dataDir)||terminalPhases.has(journal.phase))return;
    if(ownerAlive(journal.ownerPid,journal.ownerStartedTicks))return;
  }
  if(journal?.token!==job.token)journal=null;
  const release=claimProgramChange(dataDir);if(!release)return;
  const pendingInstallation=readJson(path.join(dataDir,'javascript-install-journal.json'));
  if(pendingInstallation&&!terminalPhases.has(pendingInstallation.phase)){release();return;}
  let child=null,supervisorChild=null,config=null;
  const phase=async(value,extra={})=>{
    journal={...journal,...job,...paths,...extra,phase:value,ownerPid:value==='recovery-failed'?0:process.pid,ownerStartedTicks:value==='recovery-failed'?undefined:processIdentity(process.pid)?.startedTicks,at:Date.now()};
    writeJson(journalFile,journal,{backup:false});await phaseHook(value,journal);
  };
  const result=(ok,error)=>writeJson(path.join(dataDir,'javascript-update-result.json'),{ok,recovered:ok||journal?.phase==='rolled-back',token:job.token,root,version:ok?job.version:readJson(path.join(root,'package.json'))?.version,error,backup:fs.existsSync(backup)?backup:null,at:Date.now()});
  const clearOwnStopFlag=()=>{
    const flag=path.join(dataDir,'supervisor-stop.flag');
    if(fs.existsSync(flag)&&fs.readFileSync(flag,'utf8')===job.token)fs.unlinkSync(flag);
  };
  const stopPriorSupervisor=async(record,checkpoint)=>{
    if(!record?.pid||!record.processStartedTicks||!ownerAlive(record.pid,record.processStartedTicks))return;
    if(!observedSameProcess(record.pid,record.processStartedTicks))throw Error('无法确认原守护进程的身份');
    if(checkpoint)await phase('stopping-supervisor',{oldSupervisorPid:record.pid,oldSupervisorStartedTicks:record.processStartedTicks});
    const flag=path.join(dataDir,'supervisor-stop.flag');
    if(!fs.existsSync(flag)||fs.readFileSync(flag,'utf8')===job.token)fs.writeFileSync(flag,job.token);
    for(let n=0;n<100&&ownerAlive(record.pid,record.processStartedTicks);n++)await pause(100);
    if(ownerAlive(record.pid,record.processStartedTicks))throw Error('守护进程尚未退出');
  };
  const restartSupervisor=async()=>{
    clearOwnStopFlag();
    const start=path.join(root,'src','start.mjs'),bound=readJson(path.join(root,'installation.json'));
    if(!fs.existsSync(start))return null;
    const executable=resolveNodeHost(root,bound?.nodePath);
    if(!executable)throw Error('找不到守护进程运行环境');
    const startedAt=Date.now();supervisorChild=await launch(executable,[start,'--supervise'],root,true);
    return {startedAt,executable,pid:supervisorChild.pid,startedTicks:processIdentity(supervisorChild.pid)?.startedTicks};
  };
  const resume=async()=>{
    config=readJson(path.join(root,'installation.json'));
    clearOwnStopFlag();
    if(launcherResume&&job.launcherPath&&fs.existsSync(job.launcherPath))return launch(job.launcherPath,launcherResume,path.dirname(job.launcherPath));
    const supervisor=await restartSupervisor();
    if(supervisor)return; // The supervisor owns GUI creation and pause intent.
    const executable=config?.electronPath??path.join(root,'node_modules','electron','dist','electron.exe');
    if(fs.existsSync(executable))return launch(executable,[root,'--installed'],root);
  };
  const rollback=async(reason)=>{
    if(recover&&journal.oldSupervisorPid)await stopPriorSupervisor({pid:journal.oldSupervisorPid,processStartedTicks:journal.oldSupervisorStartedTicks},false);
    if(child&&ownerAlive(child.pid,journal?.childStartedTicks)){child.kill();for(let n=0;n<50&&ownerAlive(child.pid,journal?.childStartedTicks);n++)await pause(100);}
    else if(recover&&journal.childPid&&ownerAlive(journal.childPid,journal.childStartedTicks)){
      if(!observedSameProcess(journal.childPid,journal.childStartedTicks))throw Error('无法确认新挂件进程的身份');
      process.kill(journal.childPid);for(let n=0;n<50&&ownerAlive(journal.childPid,journal.childStartedTicks);n++)await pause(100);
    }
    if(supervisorChild&&supervisorChild.exitCode===null){supervisorChild.kill();for(let n=0;n<50&&ownerAlive(supervisorChild.pid,journal?.supervisorStartedTicks);n++)await pause(100);}
    else if(recover&&journal.supervisorPid&&ownerAlive(journal.supervisorPid,journal.supervisorStartedTicks)){
      if(!observedSameProcess(journal.supervisorPid,journal.supervisorStartedTicks))throw Error('无法确认新守护进程的身份');
      process.kill(journal.supervisorPid);for(let n=0;n<50&&ownerAlive(journal.supervisorPid,journal.supervisorStartedTicks);n++)await pause(100);
    }
    if(recover&&journal.phase==='starting'&&!journal.childPid){
      await pause(1500);
      const runtime=readJson(path.join(dataDir,'runtime.json'));
      if(samePath(runtime?.appDir,root)&&runtime.version===job.version&&runtime.at>=journal.startRequestedAt&&observedSameProcess(runtime.pid,runtime.processStartedTicks)){
        process.kill(runtime.pid);for(let n=0;n<50&&ownerAlive(runtime.pid,runtime.processStartedTicks);n++)await pause(100);
      }
    }
    await phase('restoring');
    if(fs.existsSync(backup)){
      if(fs.existsSync(root))await renameWithRetry(root,staging+'.failed');
      await renameWithRetry(backup,root);
    }
    const pkg=readJson(path.join(root,'package.json')),binding=readJson(path.join(root,'installation.json'));
    if(pkg?.name!=='gpt-niang-usage'||!samePath(binding?.appDir,root))throw Error('原安装无法恢复');
    await phase('rolled-back',{error:reason});result(false,reason);clearMarker(dataDir,job.token);
    try{await resume();}catch(error){writeJson(path.join(dataDir,'javascript-update-resume-error.json'),{token:job.token,error:error.message,at:Date.now()});}
  };
  try{
    if(recover){await rollback('更新中断，已恢复原版本');return;}
    const current=readJson(path.join(root,'package.json'));config=readJson(path.join(root,'installation.json'));
    if(current?.name!=='gpt-niang-usage'||current.architecture!=='javascript-electron'||!samePath(config?.appDir,root)||!samePath(fs.realpathSync(root),root))throw Error('安装目录标识不匹配');
    if(compareVersions(job.version,current.version)<=0)throw Error('更新目标版本必须高于现用版本');
    if(job.fromVersion&&job.fromVersion!==current.version)throw Error('现用安装版本已经改变，请重新检查更新');
    for(const entry of job.expected)if(hash(fs.readFileSync(inside(source,entry.name)))!==entry.hash)throw Error('更新候选校验失败');
    if(hash(fs.readFileSync(path.join(source,'verified-package.zip')))!==job.hash)throw Error('更新压缩包校验失败');
    await phase('staging',{oldVersion:current.version});fs.mkdirSync(staging);
    for(const entry of job.expected){const target=inside(staging,entry.name);fs.mkdirSync(path.dirname(target),{recursive:true});fs.copyFileSync(inside(source,entry.name),target);}
    writeJson(path.join(staging,'installation.json'),{...config,version:job.version});
    await phase('waiting-parent');for(let n=0;n<300&&ownerAlive(job.parentPid,job.parentStartedTicks);n++)await pause(100);
    if(ownerAlive(job.parentPid,job.parentStartedTicks))throw Error('原程序尚未退出');
    const supervisor=readJson(path.join(dataDir,'supervisor-status.json'));
    if(samePath(supervisor?.appDir,root))await stopPriorSupervisor(supervisor,true);
    await phase('moving-old');await renameWithRetry(root,backup);await phase('moving-new');await renameWithRetry(staging,root);
    await phase('starting',{startRequestedAt:Date.now()});
    child=await launch(config.electronPath??path.join(root,'node_modules','electron','dist','electron.exe'),[root,'--installed'],root);
    await phase('waiting-health',{childPid:child.pid,childStartedTicks:processIdentity(child.pid)?.startedTicks});
    const deadline=Date.now()+healthTimeoutMs;let healthy=false;
    do{
      const runtime=readJson(path.join(dataDir,'runtime.json'));
      if(runtime?.pid===child.pid&&installationHealthy({root,version:job.version,runtime,electronPath:config.electronPath,startedAt:journal.startRequestedAt})){healthy=true;break;}
      if(!ownerAlive(child.pid,journal.childStartedTicks))break;await pause(100);
    }while(Date.now()<deadline);
    if(!healthy)throw Error('新版本启动未通过检查');
    const restarted=await restartSupervisor();
    if(restarted){
      await phase('waiting-supervisor',{supervisorPid:restarted.pid,supervisorStartedTicks:restarted.startedTicks});
      let supervisorReady=false;const limit=Date.now()+15000;
      do{
        const runtime=readJson(path.join(dataDir,'runtime.json')),supervisor=readJson(path.join(dataDir,'supervisor-status.json'));
        if(installationHealthy({root,version:job.version,runtime,supervisor,settings:readJson(path.join(dataDir,'settings.json')),startedAt:journal.startRequestedAt,electronPath:config.electronPath,nodePath:restarted.executable,requireSupervisor:true})){supervisorReady=true;break;}
        if(!ownerAlive(restarted.pid,restarted.startedTicks)||!ownerAlive(child.pid,journal.childStartedTicks))break;
        await pause(100);
      }while(Date.now()<limit);
      if(!supervisorReady)throw Error('新版本守护进程未通过检查');
    }
    await phase('committed');
    // The old copy is useful only until the new GUI and supervisor are healthy.
    // Cleanup errors must never roll a committed installation back.
    try{removeTransactionDirectory(path.dirname(root),path.basename(backup),[root,dataDir]);}
    catch(error){writeJson(journalFile,{...journal,cleanupError:error.message},{backup:false});}
    result(true);clearMarker(dataDir,job.token);
  }catch(error){
    if(journal?.phase==='committed'){clearMarker(dataDir,job.token);throw error;}
    try{await rollback(error.message);}catch(failure){await phase('recovery-failed',{error:error.message+'；恢复失败：'+failure.message});result(false,journal.error);throw failure;}
    if(!recover)throw error;
  }finally{release();}
}
export function pendingRecovery(dataDir){
  const journal=readJson(path.join(dataDir,'javascript-update-journal.json'));
  if(!journal||terminalPhases.has(journal.phase)||ownerAlive(journal.ownerPid,journal.ownerStartedTicks))return null;
  const agent=path.resolve(journal.agent??'.'),base=path.resolve(dataDir,'update-agent-js');
  if(!agent.startsWith(base+path.sep)||path.resolve(journal.job??'.')!==path.join(agent,'job.json')||!fs.existsSync(journal.executable??'')||!fs.existsSync(path.join(agent,'src','update-agent.mjs')))return null;
  return journal;
}
