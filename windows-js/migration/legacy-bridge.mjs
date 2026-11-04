import fs from 'node:fs';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {readJson,writeJson,inside} from '../src/core/storage.mjs';
import {RELEASE_API,DAY,download,compareVersions,selectRelease,verifyHash,verifyAssetDigest} from '../src/core/update-network.mjs';
import {inspectJavaScriptPackage} from '../src/core/archive.mjs';
import {cleanupFinishedMigration,removeTransactionDirectory} from '../src/core/update-cleanup.mjs';
import {readInstallRecord,installFinished,recoverInstall} from '../src/core/install-recovery.mjs';
import {ownerAlive} from '../src/core/update-transaction.mjs';
import {processIdentity} from '../runtime/process-identity.mjs';
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
export function reconcileMigrationHandoff(config,{alive=ownerAlive,now=Date.now}={}){
  const file=path.join(config.dataDir,'javascript-migration-handoff.json'),handoff=readJson(file);
  if(!handoff)return true;
  if(!/^[a-f0-9-]{36}$/i.test(handoff.token??''))throw Error('迁移交接编号无效，保留缓存');
  const source=inside(config.dataDir,'updates/'+handoff.token),job=readJson(inside(config.dataDir,'migration-jobs/'+handoff.token+'.json'));
  const same=(a,b)=>typeof a==='string'&&typeof b==='string'&&path.resolve(a).toLowerCase()===path.resolve(b).toLowerCase();
  const installation=readInstallRecord(config.dataDir),receipt=readJson(path.join(config.dataDir,'javascript-legacy-migration.json'));
  if(same(handoff.source,source)&&((installation&&same(installation.source,source)&&installFinished.has(installation.phase))||(receipt?.token===handoff.token&&same(receipt.source,source)&&installFinished.has(receipt.phase))))return cleanupFinishedMigration(config.dataDir,alive);
  if(!same(handoff.source,source)||!job||job.token!==handoff.token||!same(job.root,config.appDir)||!same(job.dataDir,config.dataDir)||!same(job.source,source))throw Error('迁移交接绑定不匹配，保留缓存');
  if(alive(handoff.pid,handoff.startedTicks))return false;
  if(installation&&same(installation.source,source)&&!installFinished.has(installation.phase))return false;
  const original=readJson(path.join(config.appDir,'installation.json'));
  if(!original||!same(original.appDir,config.appDir)||!same(original.dataDir,config.dataDir)||original.architecture==='javascript-electron')throw Error('无法确认迁移前的安装，保留缓存');
  // No installer journal means the helper died before the first file swap.
  // Record a terminal receipt so the existing exact-path cleaner can remove it.
  writeJson(path.join(config.dataDir,'javascript-legacy-migration.json'),{...job,phase:'rolled-back',ownerPid:process.pid,ownerStartedTicks:processIdentity(process.pid)?.startedTicks,at:now(),error:'迁移助手已退出，现用版本保留。'},{backup:false});
  return cleanupFinishedMigration(config.dataDir,()=>false);
}
export function migrationRelease(release,currentVersion) {
  if(release.draft||release.prerelease)return null;
  if(compareVersions(release.tag_name,currentVersion)<0)return null;
  // The legacy bridge and JavaScript payload share one release version.
  return selectRelease(release,'0.0.0');
}
async function launchAgent({executable,source,job,target,dataDir}) {
  const child=spawn(executable,[path.join(source,'src','legacy-migration-agent.mjs'),job,'--target',target,'--data-dir',dataDir],{
    cwd:source,detached:true,windowsHide:true,stdio:'ignore',env:{...process.env,ELECTRON_RUN_AS_NODE:'1'},
  });
  await new Promise((resolve,reject)=>{child.once('spawn',resolve);child.once('error',reject);});child.unref();
  return child.pid;
}
export async function runLegacyBridge(config,{legacy,mode='manual',fetchBytes=download,launch=launchAgent,wait=pause,now=Date.now}={}) {
  const automatic=mode.startsWith('automatic'),stateFile=path.join(config.dataDir,'update-status.json');
  const state=readJson(stateFile)??{},report=value=>writeJson(stateFile,Object.assign(state,value),{backup:false});
  const installation=readInstallRecord(config.dataDir);
  if(installation&&!installFinished.has(installation.phase)){
    const recovery=await recoverInstall(config.dataDir);
    report({phase:recovery.busy?'waiting':'failed',message:recovery.busy?'上次安装或恢复仍在进行。':'上次安装中断，已恢复原版本。',nextCheckAt:now()+DAY});
    return recovery;
  }
  if(!reconcileMigrationHandoff(config))return;
  const alive=pid=>{if(!Number.isSafeInteger(pid)||pid<=0)return false;try{process.kill(pid,0);return true;}catch(error){return error.code==='EPERM';}};
  if(!cleanupFinishedMigration(config.dataDir,alive))throw Error('上次迁移助手尚未退出或恢复尚未完成');
  const handoff=readJson(path.join(config.dataDir,'javascript-migration-handoff.json'));
  if(handoff&&alive(handoff.pid))return;
  if(mode==='cleanup')return legacy.runUpdate(config,{mode});
  if(legacy.isGitCheckout(config.appDir)){report({phase:'source',message:'源码目录请使用 Git 更新。'});return;}
  if(automatic&&readJson(path.join(config.dataDir,'update-preferences.json'))?.automatic===false)return;
  if(now()<(state.retryAfterAt??0)||(automatic&&mode==='automatic'&&now()<(state.nextCheckAt??0)))return;
  const agentDir=config.updateAgent??path.join(process.env.LOCALAPPDATA,'GPTNiangUsage','update-agent');
  // Finish the old helper's transaction and cleanup before taking over its lock.
  await legacy.runUpdate(config,{mode:'cleanup',agentDir});
  const prior=readJson(path.join(agentDir,'update-transaction.json'));
  if(prior&&(!['committed','rolled-back'].includes(prior.phase)||prior.cleanupPending))throw Error('旧版本更新尚未完成恢复或清理');
  const lock=legacy.acquireUpdateLock(agentDir);if(!lock)return;
  const token=randomUUID(),source=inside(config.dataDir,'updates/'+token),job=inside(config.dataDir,'migration-jobs/'+token+'.json');
  let handedOff=false;
  try {
    report({phase:'checking',message:'正在检查 JavaScript 迁移更新…',nextCheckAt:now()+DAY,retryAfterAt:0});
    const release=JSON.parse((await fetchBytes(RELEASE_API,{api:true,limit:4*1024*1024})).toString('utf8'));
    const selected=migrationRelease(release,config.version);
    if(!selected){report({phase:'current',message:'当前已是最新正式版。'});return;}
    report({phase:'downloading',version:selected.version,message:'正在下载新的运行环境…',bytes:0});
    const sums=await fetchBytes(selected.sums.browser_download_url,{limit:1024*1024});verifyAssetDigest(sums,selected.sums);
    let lastProgress=0;
    const bytes=await fetchBytes(selected.zip.browser_download_url,{limit:1024*1024*1024,onProgress:bytes=>{if(now()-lastProgress>=500){lastProgress=now();report({bytes});}}});
    const hash=verifyHash(bytes,sums,selected.zip),files=inspectJavaScriptPackage(bytes,selected.version);
    const required=['src/legacy-migration-agent.mjs','node_modules/electron/dist/electron.exe'];
    for(const name of required)if(!files.some(file=>file.name===name))throw Error('迁移更新包缺少 '+name);
    fs.mkdirSync(source,{recursive:true});
    for(const file of files){const target=inside(source,file.name);fs.mkdirSync(path.dirname(target),{recursive:true});fs.writeFileSync(target,file.bytes,{flag:'wx'});}
    report({phase:'waiting',message:'已校验，等待挂件空闲；原有自定义内容继续保留。'});
    const deadline=now()+60000;
    while(!legacy.installIdle(config,mode,now())) {
      if(automatic&&readJson(path.join(config.dataDir,'update-preferences.json'))?.automatic===false){report({phase:'cancelled',message:'自动更新已关闭。'});return;}
      if(now()>=deadline)throw Error('挂件尚未空闲，请保存并关闭编辑窗口后重试');
      await wait(1000);
    }
    if(automatic&&readJson(path.join(config.dataDir,'update-preferences.json'))?.automatic===false){report({phase:'cancelled',message:'自动更新已关闭。'});return;}
    writeJson(job,{schema:1,token,source,root:config.appDir,dataDir:config.dataDir,version:selected.version,hash,mode:automatic?'automatic':'manual',parentPid:process.pid,parentStartedAt:Date.now()-process.uptime()*1000},{backup:false});
    report({phase:'installing',message:'正在切换运行环境，个人内容沿用原目录。',token});
    const pid=await launch({executable:inside(source,'node_modules/electron/dist/electron.exe'),source,job,target:config.appDir,dataDir:config.dataDir});
    handedOff=true;
    writeJson(path.join(config.dataDir,'javascript-migration-handoff.json'),{pid,startedTicks:processIdentity(pid)?.startedTicks,token,source,at:now()},{backup:false});
    return {handedOff:true,source,job,pid};
  }catch(error){report({phase:'failed',message:error.message,nextCheckAt:now()+(error.retryAfterMs??DAY),retryAfterAt:error.retryAfterMs?now()+error.retryAfterMs:0});throw error;}
  finally {
    // These exact paths were created by this invocation, never a directory scan.
    try{if(!handedOff){
      if(fs.existsSync(source))removeTransactionDirectory(inside(config.dataDir,'updates'),token,[config.appDir]);
      if(fs.existsSync(job))fs.unlinkSync(job);
    }}finally{lock.release();}
  }
}
