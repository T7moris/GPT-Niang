import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {readJson,writeJson,inside} from './core/storage.mjs';
import {preflight,install} from './install.mjs';
import {ownerAlive} from './core/update-transaction.mjs';
import {processIdentity} from '../runtime/process-identity.mjs';
import {readInstallRecord} from './core/install-recovery.mjs';
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const same=(a,b)=>path.resolve(a).toLowerCase()===path.resolve(b).toLowerCase();
export function legacyMigrationReady(spec,{alive=ownerAlive,now=Date.now()}={}) {
  if(spec.mode==='automatic'&&readJson(path.join(spec.dataDir,'update-preferences.json'))?.automatic===false)throw Error('自动更新已关闭');
  const idle=readJson(path.join(spec.dataDir,'update-idle.json')),worker=readJson(path.join(spec.dataDir,'worker-status.json'));
  return !!(idle&&alive(idle.pid)&&now-idle.at>=0&&now-idle.at<5000&&!idle.editor&&!idle.menu&&!idle.drag&&!worker?.busy);
}
export async function runLegacyMigration(spec,{plan,perform=install,wait=pause,ready=legacyMigrationReady,alive=ownerAlive}={}) {
  if(spec?.schema!==1||!/^[a-f0-9-]{36}$/i.test(spec.token??'')||!path.isAbsolute(spec.root??'')||!path.isAbsolute(spec.dataDir??''))throw Error('迁移任务无效');
  const source=inside(spec.dataDir,'updates/'+spec.token);
  if(!same(source,spec.source)||!same(plan.target,spec.root)||!same(plan.dataDir,spec.dataDir)||plan.version!==spec.version||plan.previous?.architecture==='javascript-electron')throw Error('迁移安装标识不匹配');
  const parent=processIdentity(spec.parentPid),parentTicks=parent&&Math.abs(parent.startedAt-spec.parentStartedAt)<3000?parent.startedTicks:null;
  if(parentTicks){for(let n=0;n<300&&alive(spec.parentPid,parentTicks);n++)await wait(100);if(alive(spec.parentPid,parentTicks))throw Error('旧版更新进程尚未退出');}
  const prior=plan.previous?.updateAgent?readJson(path.join(plan.previous.updateAgent,'update-transaction.json')):null;
  if(prior&&(!['committed','rolled-back'].includes(prior.phase)||prior.cleanupPending))throw Error('旧版更新事务尚未完成');
  const deadline=Date.now()+60000;
  while(!ready(spec)){if(Date.now()>=deadline)throw Error('挂件尚未空闲，请稍后重试');await wait(500);}
  const identity=processIdentity(process.pid),marker=path.join(spec.dataDir,'update-installing.json'),receipt=path.join(spec.dataDir,'javascript-legacy-migration.json');
  writeJson(marker,{pid:process.pid,startedTicks:identity?.startedTicks,token:spec.token,at:Date.now()},{backup:false});
  try {
    const result=await perform(plan,{migration:spec,beforeStop:()=>{if(!ready(spec))throw Error('挂件已开始交互，暂停迁移并保留现用版本');}});
    writeJson(receipt,{...spec,phase:'committed',ownerPid:process.pid,ownerStartedTicks:identity?.startedTicks,at:Date.now()},{backup:false});
    return result;
  }catch(error){
    const journal=readInstallRecord(spec.dataDir),tracked=journal&&same(journal.source,spec.source);
    if(tracked&&journal.phase==='committed')return {ok:true,migrationReceiptPending:true,reportError:error.message};
    const restored=readJson(path.join(spec.root,'installation.json'));
    const phase=tracked?(journal.phase==='rolled-back'?'rolled-back':'recovery-failed'):(restored&&restored.architecture!=='javascript-electron'?'rolled-back':'recovery-failed');
    writeJson(receipt,{...spec,phase,ownerPid:process.pid,ownerStartedTicks:identity?.startedTicks,error:error.message,at:Date.now()},{backup:false});
    throw error;
  }finally {try{if(readJson(marker)?.token===spec.token)fs.unlinkSync(marker);}catch{}}
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  if(process.versions.electron)process.noAsar=true;
  const spec=readJson(process.argv[2]);
  try{await runLegacyMigration(spec,{plan:preflight()});}
  catch(error){
    // Preflight can fail before runLegacyMigration creates its normal receipt.
    // Retain the original program, report the failure and allow cache cleanup.
    try{
      if(spec?.schema===1&&/^[a-f0-9-]{36}$/i.test(spec.token??'')&&path.isAbsolute(spec.root)&&path.isAbsolute(spec.dataDir)&&same(spec.source,inside(spec.dataDir,'updates/'+spec.token))) {
        const original=readJson(path.join(spec.root,'installation.json'));
        const journal=readInstallRecord(spec.dataDir),pending=journal&&same(journal.source,spec.source)&&!['committed','rolled-back'].includes(journal.phase);
        if(!pending&&original&&same(original.appDir,spec.root)&&same(original.dataDir,spec.dataDir)&&original.architecture!=='javascript-electron') {
          writeJson(path.join(spec.dataDir,'javascript-legacy-migration.json'),{...spec,phase:'rolled-back',ownerPid:process.pid,ownerStartedTicks:processIdentity(process.pid)?.startedTicks,error:error.message,at:Date.now()},{backup:false});
          writeJson(path.join(spec.dataDir,'update-status.json'),{phase:'failed',message:'迁移未完成，现用版本保留：'+error.message,nextCheckAt:Date.now()+86400000},{backup:false});
        }
      }
    }catch{}
    console.error(error.message);process.exitCode=1;
  }
}
