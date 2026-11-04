import fs from 'node:fs';
import path from 'node:path';
import {randomUUID,createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {inside,readJson,writeJson} from './storage.mjs';
import {ownerAlive,renameWithRetry,claimProgramChange} from './update-transaction.mjs';
import {processIdentity} from '../../runtime/process-identity.mjs';
import {cleanupFinishedInstall,removeTransactionDirectory} from './update-cleanup.mjs';
import {restorePluginRegistration} from './plugin-registration.mjs';

export const installFinished=new Set(['committed','rolled-back']);
const key=file=>path.resolve(file).toLowerCase();
const same=(a,b)=>typeof a==='string'&&typeof b==='string'&&key(a)===key(b);
const digest=bytes=>createHash('sha256').update(bytes).digest('hex');
export const snapshotFile=file=>fs.existsSync(file)?fs.readFileSync(file).toString('base64'):null;
const bytes=value=>value===null?null:Buffer.from(value,'base64');
const journalFile=dataDir=>inside(dataDir,'javascript-install-journal.json');

function directory(file){
  if(!path.isAbsolute(file)||path.resolve(file)===path.dirname(path.resolve(file)))throw Error('安装恢复目录无效');
  for(let current=path.resolve(file);current!==path.dirname(current);current=path.dirname(current))
    if(fs.existsSync(current)&&fs.lstatSync(current).isSymbolicLink())throw Error('安装恢复路径不能包含文件链接');
  return path.resolve(file);
}
export function validateInstallRecord(record,dataDir){
  if(record?.schema!==1||!/^[a-f0-9-]{36}$/i.test(record.token??'')||!same(record.dataDir,dataDir))throw Error('安装恢复记录无效');
  const root=directory(record.root),data=directory(dataDir);
  if(same(root,data)||key(root).startsWith(key(data)+path.sep)||key(data).startsWith(key(root)+path.sep))throw Error('恢复目录与个人目录重叠');
  const transaction=inside(data,'install-js-'+record.token),stage=root+'.stage-'+record.token,backup=root+'.rollback-'+record.token;
  if(!same(record.transaction,transaction)||!same(record.stage,stage)||!same(record.backup,backup))throw Error('安装恢复事务路径不匹配');
  const plan=record.plan;
  if(!same(plan?.target,root)||!same(plan?.dataDir,data)||!same(plan?.launcherPath,inside(data,'launcher/GPTNiang.Start.exe'))||typeof plan.taskName!=='string'||typeof plan.sid!=='string'||!path.isAbsolute(plan.shortcut??'')||!path.isAbsolute(plan.marketplaceRoot??''))throw Error('安装恢复绑定无效');
  if(record.pluginSnapshot&&(record.pluginSnapshot.schema!==1||!same(record.pluginSnapshot.target,root)||!same(record.pluginSnapshot.codexPath,plan.codexPath)||!same(record.pluginSnapshot.marketplaceRoot,plan.marketplaceRoot)||!path.isAbsolute(record.pluginSnapshot.home??'')))throw Error('插件恢复绑定无效');
  if(record.pluginTouched&&!record.pluginSnapshot)throw Error('插件恢复记录缺失');
  const bootstrap=[plan.launcherPath,path.join(path.dirname(plan.launcherPath),'launcher.json'),path.join(path.dirname(plan.launcherPath),'launcher.json.bak')];
  if(!Array.isArray(record.snapshots?.bootstrap)||record.snapshots.bootstrap.length!==bootstrap.length||record.snapshots.bootstrap.some(([file])=>!bootstrap.some(expected=>same(expected,file))))throw Error('启动器恢复记录无效');
  for(const name of Object.keys(record.snapshots.flags))if(!['stop.flag','supervisor-stop.flag','supervisor-disabled.flag','supervisor-pause.json'].includes(name))throw Error('停止标记恢复记录无效');
  if(record.recovery&&(!same(record.recovery.agent,path.join(transaction,'recovery'))||!same(record.recovery.script,path.join(transaction,'recovery/src/install-recovery.mjs'))||!path.isAbsolute(record.recovery.executable??'')))throw Error('恢复助手绑定无效');
  if(record.migration&&(!/^[a-f0-9-]{36}$/i.test(record.migration.token??'')||!same(record.migration.root,root)||!same(record.migration.dataDir,data)||!same(record.migration.source,inside(data,'updates/'+record.migration.token))))throw Error('跨架构迁移恢复绑定无效');
  return record;
}
export function readInstallRecord(dataDir){
  const file=journalFile(dataDir);if(!fs.existsSync(file))return null;
  const record=readJson(file);return validateInstallRecord(record,dataDir);
}
// Flush the small record before a destructive operation. Keep only one journal.
export function writeInstallRecord(record){
  validateInstallRecord(record,record.dataDir);
  const file=journalFile(record.dataDir),temporary=file+'.'+process.pid+'.'+randomUUID()+'.tmp';
  fs.mkdirSync(record.dataDir,{recursive:true});let fd;
  try{
    fd=fs.openSync(temporary,'wx');fs.writeFileSync(fd,JSON.stringify(record,null,2)+'\n');fs.fsyncSync(fd);fs.closeSync(fd);fd=undefined;
    fs.renameSync(temporary,file);
  }finally{if(fd!==undefined)fs.closeSync(fd);try{fs.unlinkSync(temporary);}catch{}}
}
export function claimInstall(dataDir){
  return claimProgramChange(dataDir);
}
export function prepareInstallRecovery(record,codeRoot){
  const agent=inside(record.transaction,'recovery');fs.mkdirSync(agent);
  for(const name of ['src/install-recovery.mjs','src/core/install-recovery.mjs','src/core/plugin-registration.mjs','src/core/storage.mjs','src/core/update-transaction.mjs','src/core/update-network.mjs','src/core/update-cleanup.mjs','src/core/installation-health.mjs','runtime/process-identity.mjs','native/GPTNiang.Setup.exe']){
    const destination=inside(agent,name);fs.mkdirSync(path.dirname(destination),{recursive:true});fs.copyFileSync(inside(codeRoot,name),destination);
  }
  for(const name of ['node_modules/koffi','node_modules/@koromix/koffi-'+process.platform+'-'+process.arch]){
    const source=inside(codeRoot,name);if(fs.existsSync(source))fs.cpSync(source,inside(agent,name),{recursive:true});
  }
  const executable=[record.plan.nodePath,process.execPath].find(file=>{
    if(!file||same(file,record.root)||key(file).startsWith(key(record.root)+path.sep))return false;
    try{return fs.statSync(file).isFile();}catch{return false;}
  });
  if(!executable)throw Error('找不到程序目录之外的恢复运行环境');
  return {agent,executable,script:path.join(agent,'src/install-recovery.mjs')};
}
export function recoveryWindows(record){
  return (op,...args)=>{
    const result=spawnSync(path.join(record.recovery.agent,'native/GPTNiang.Setup.exe'),[op,...args],{windowsHide:true,encoding:'utf8',timeout:30000});
    if(result.error)throw result.error;
    let value;try{value=JSON.parse(result.stdout.replace(/^\uFEFF/,''));}catch{throw Error('启动设置恢复未返回有效结果');}
    if(result.status!==0||value?.ok!==true)throw Error(value?.error??'启动设置恢复失败');return value;
  };
}
async function restoreFile(file,value){
  for(let attempt=0;;attempt++){
    try{
      if(value===null){if(fs.existsSync(file))fs.unlinkSync(file);return;}
      fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,bytes(value));return;
    }catch(error){
      if(!['EBUSY','EPERM','EACCES'].includes(error.code)||attempt>=49)throw error;
      await new Promise(resolve=>setTimeout(resolve,100));
    }
  }
}
function originalAt(record,root){
  return Object.entries(record.snapshots.identity).every(([name,value])=>{
    const file=inside(root,name);return value===null?!fs.existsSync(file):fs.existsSync(file)&&digest(fs.readFileSync(file))===digest(bytes(value));
  });
}
export async function stopProgramOwners({root,dataDir,token=String(Date.now()),stopTask=()=>{}}){
  fs.mkdirSync(dataDir,{recursive:true});
  const readOwners=()=>['runtime.json','supervisor-status.json'].map(name=>readJson(inside(dataDir,name))).filter(record=>record?.pid);
  const validate=records=>{
    for(const record of records)if(record.appDir&&!same(record.appDir,root))throw Error('另一个挂件正在使用该数据目录，无法确认待停止的程序归属');
  };
  const alive=record=>{
    const ticks=record.processStartedTicks??record.startedTicks;
    if(ticks)return ownerAlive(record.pid,ticks);
    const identity=processIdentity(record.pid),started=Date.parse(record.processStartedAt);
    if(identity&&Number.isFinite(started))return identity.startedAt===started;
    return ownerAlive(record.pid);
  };
  const owners=new Map(),remember=records=>{
    validate(records);
    for(const record of records)owners.set([record.pid,record.processStartedTicks??record.startedTicks??record.processStartedAt??''].join('|'),record);
  };
  remember(readOwners());
  for(const name of ['supervisor-stop.flag','stop.flag'])fs.writeFileSync(inside(dataDir,name),token);
  await stopTask();
  for(let n=0;n<100;n++){
    // A GUI launched just before the stop may publish its identity after the
    // initial snapshot. Keep waiting for it as well as the detached supervisor.
    remember(readOwners());
    if(![...owners.values()].some(alive))return;
    await new Promise(resolve=>setTimeout(resolve,100));
  }
  throw Error('现用挂件或守护进程尚未退出，安装尚未改动程序文件');
}
export async function stopRecoveringProgram(record,windows){
  const current=windows('task-info',record.plan.taskName);
  if(current?.exists&&(!same(current.command,record.plan.launcherPath)||current.arguments!=='--supervise')){
    const original=record.plan.task;
    if(!original?.exists||!same(current.command,original.command)||current.arguments!==original.arguments)throw Error('启动任务已被其他操作更改，保留恢复文件');
  }
  await stopProgramOwners({root:record.root,dataDir:record.dataDir,token:record.token,stopTask:()=>{if(current?.exists)windows('task-stop',record.plan.taskName);}});
}
export async function recoverInstall(dataDir,{token,windows,stop=stopRecoveringProgram,phaseHook=()=>{},currentOwner=false,resume=true,restorePlugin=restorePluginRegistration}={}){
  let record=readInstallRecord(dataDir);
  if(!record||installFinished.has(record.phase))return {ok:true,nothingToRecover:true};
  if(token&&record.token!==token)throw Error('安装恢复编号不匹配');
  if(ownerAlive(record.ownerPid,record.ownerStartedTicks)&&!(currentOwner&&record.ownerPid===process.pid))return {ok:false,busy:true};
  const release=currentOwner?()=>{}:claimInstall(dataDir);if(!release)return {ok:false,busy:true};
  windows??=record.recovery?recoveryWindows(record):()=>{throw Error('安装恢复助手尚未准备好');};
  const phase=async(value,extra={})=>{
    const next={...record,...extra,phase:value,ownerPid:value==='recovery-failed'?0:process.pid,ownerStartedTicks:value==='recovery-failed'?undefined:processIdentity(process.pid)?.startedTicks,at:Date.now()};writeInstallRecord(next);record=next;await phaseHook(value,record);
  };
  try{
    record=readInstallRecord(dataDir);
    if(installFinished.has(record.phase))return {ok:true,nothingToRecover:true};
    await phase('restoring');
    if(record.systemTouched)await stop(record,windows);
    const {root,backup,stage,plan,snapshots}=record;
    if(fs.existsSync(backup)){
      if(!originalAt(record,backup))throw Error('原程序恢复副本已改变');
      if(fs.existsSync(root)){
        const binding=readJson(path.join(root,'installation.json'));
        if(binding?.installTransaction!==record.token||!same(binding.appDir,root))throw Error('目标程序已发生外部变化，保留恢复副本');
        await renameWithRetry(root,stage+'.failed');
      }
      await renameWithRetry(backup,root);
    }else if(record.hadTarget){
      if(!fs.existsSync(root)||!originalAt(record,root))throw Error('无法找到完整的原程序，保留恢复记录');
    }else if(fs.existsSync(root)){
      if(readJson(path.join(root,'installation.json'))?.installTransaction!==record.token)throw Error('目标目录不属于本次安装');
      await renameWithRetry(root,stage+'.failed');
    }
    await phase('restoring-system');
    if(record.taskTouched){
      const current=windows('task-info',plan.taskName);
      const own=current&&same(current.command,plan.launcherPath)&&current.arguments==='--supervise';
      const original=current&&plan.task.exists&&same(current.command,plan.task.command)&&current.arguments===plan.task.arguments;
      if(current?.exists&&(!(own||original)||(current.sid&&current.sid!==plan.sid)))throw Error('启动任务已发生外部变化，保留恢复记录');
      if(plan.task.exists){
        const file=inside(record.transaction,'old-task.xml');fs.writeFileSync(file,Buffer.concat([Buffer.from([255,254]),Buffer.from(plan.task.xml,'utf16le')]));
        windows('task-register',plan.taskName,file,plan.sid);
      }else if(windows('task-info',plan.taskName)?.exists!==false)windows('task-delete',plan.taskName);
    }
    if(record.shortcutTouched)await restoreFile(plan.shortcut,snapshots.shortcut);
    if(record.marketWritten){
      const market=path.join(plan.marketplaceRoot,'.agents/plugins/marketplace.json');
      const current=fs.existsSync(market)?digest(fs.readFileSync(market)):null,original=snapshots.market===null?null:digest(bytes(snapshots.market));
      const backup=fs.existsSync(market+'.bak')?digest(fs.readFileSync(market+'.bak')):null;
      if(current===record.marketWritten||(current===original&&original!==null&&backup===original)){await restoreFile(market,snapshots.market);await restoreFile(market+'.bak',snapshots.marketBackup);}
    }
    if(record.bootstrapTouched)for(const [file,value]of snapshots.bootstrap)await restoreFile(file,value);
    if(record.pluginTouched)await restorePlugin(record.pluginSnapshot);
    if(record.systemTouched)for(const [name,value]of Object.entries(snapshots.flags))await restoreFile(inside(dataDir,name),value);
    await phase('rolled-back',{error:'安装中断或失败，已恢复原版本'});
    let reportError=null;
    try{writeJson(inside(dataDir,'javascript-install-cleanup.json'),{root,dataDir,token:record.token,phase:'rolled-back',ownerPid:process.pid,ownerStartedTicks:record.ownerStartedTicks},{backup:false});}catch(error){reportError=error.message;}
    if(record.migration){
      try{writeJson(inside(dataDir,'javascript-legacy-migration.json'),{...record.migration,phase:'rolled-back',ownerPid:process.pid,ownerStartedTicks:record.ownerStartedTicks,at:Date.now()},{backup:false});}catch(error){reportError=error.message;}
      const marker=inside(dataDir,'update-installing.json');
      if(readJson(marker)?.token===record.migration.token)try{fs.unlinkSync(marker);}catch{}
    }
    let resumeError=null;
    if(resume&&record.systemTouched&&plan.task.exists&&(record.resumeTask??plan.task.state===4))try{windows('task-start',plan.taskName);}catch(error){resumeError=error.message;}
    let cleanupPending=true;
    try{cleanupPending=!cleanupFinishedInstall(dataDir,()=>false);}catch{}
    return {ok:true,recovered:true,resumeError,reportError,cleanupPending};
  }catch(error){
    await phase('recovery-failed',{error:error.message});throw error;
  }finally{release();}
}
