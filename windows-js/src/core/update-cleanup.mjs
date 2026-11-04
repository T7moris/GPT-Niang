import fs from 'node:fs';
import path from 'node:path';
import {inside,readJson,writeJson} from './storage.mjs';
const key=file=>path.resolve(file).toLowerCase();
const overlaps=(a,b)=>key(a)===key(b)||key(a).startsWith(key(b)+path.sep)||key(b).startsWith(key(a)+path.sep);

// Delete only an exact transaction path. Never enumerate similarly named
// installations, follow directory links, or include the personal data root.
export function removeTransactionDirectory(parent,name,protectedPaths=[]) {
  const directory=inside(parent,name);
  if(protectedPaths.some(file=>overlaps(directory,file)))throw Error('清理路径包含正在使用的程序或个人目录');
  if(!fs.existsSync(directory))return;
  function inspect(current) {
    const stat=fs.lstatSync(current);
    if(stat.isSymbolicLink())throw Error('清理目录不能包含文件链接');
    if(stat.isDirectory())for(const entry of fs.readdirSync(current))inspect(path.join(current,entry));
  }
  inspect(directory);
  fs.rmSync(directory,{recursive:true,force:false});
}

export function cleanupFinishedUpdate(dataDir,isAlive) {
  const file=path.join(dataDir,'javascript-update-journal.json'),journal=readJson(file);
  if(!journal||journal.cleanupAt||!['committed','rolled-back'].includes(journal.phase))return true;
  if(!/^[a-z0-9-]{1,100}$/i.test(journal.token??'')||!path.isAbsolute(journal.root??'')||key(journal.dataDir??'.')!==key(dataDir))throw Error('更新清理记录无效');
  if(isAlive(journal.ownerPid,journal.ownerStartedTicks))return false;
  const root=path.resolve(journal.root),parent=path.dirname(root),protect=[root,dataDir],base=path.basename(root),token=journal.token;
  const backup=inside(parent,base+'.rollback-'+token);
  if(journal.phase==='rolled-back'&&fs.existsSync(backup))return false; // Recovery has not restored this copy.
  if(journal.phase==='committed')removeTransactionDirectory(parent,base+'.rollback-'+token,protect);
  for(const name of [base+'.staging-'+token,base+'.staging-'+token+'.failed'])removeTransactionDirectory(parent,name,protect);
  if(!journal.keepSource) {
    const updates=inside(dataDir,'updates'),source=path.resolve(journal.source??'.'),relative=path.relative(updates,source);
    if(!relative||relative.includes(path.sep)||relative==='..'||path.isAbsolute(relative))throw Error('更新缓存清理路径无效');
    removeTransactionDirectory(updates,relative,[root]);
  }
  if(journal.agent) {
    const agents=inside(dataDir,'update-agent-js');
    if(key(journal.agent)!==key(path.join(agents,token)))throw Error('更新助手清理路径无效');
    removeTransactionDirectory(agents,token,[root]);
  }
  writeJson(file,{...journal,cleanupAt:Date.now(),cleanupError:null},{backup:false});
  return true;
}

export function cleanupFinishedInstall(dataDir,isAlive) {
  const file=path.join(dataDir,'javascript-install-cleanup.json');let record=readJson(file);
  const journal=readJson(path.join(dataDir,'javascript-install-journal.json'));
  if(journal?.schema===1&&['committed','rolled-back'].includes(journal.phase)&&record?.token!==journal.token){
    if(record&&!record.cleanupAt)throw Error('上次安装清理尚未完成');
    record={root:journal.root,dataDir:journal.dataDir,token:journal.token,phase:journal.phase,ownerPid:journal.ownerPid,ownerStartedTicks:journal.ownerStartedTicks};
    writeJson(file,record,{backup:false});
  }
  if(!record||record.cleanupAt)return true;
  if(!/^[a-f0-9-]{36}$/i.test(record.token??'')||!path.isAbsolute(record.root??'')||key(record.dataDir??'.')!==key(dataDir)||!['committed','rolled-back'].includes(record.phase))throw Error('安装清理记录无效');
  if(isAlive(record.ownerPid,record.ownerStartedTicks))return false;
  const root=path.resolve(record.root),parent=path.dirname(root),base=path.basename(root),protect=[root,dataDir];
  const backup=inside(parent,base+'.rollback-'+record.token);
  if(record.phase==='rolled-back'&&fs.existsSync(backup))return false;
  if(record.phase==='committed')removeTransactionDirectory(parent,base+'.rollback-'+record.token,protect);
  for(const suffix of ['', '.failed'])removeTransactionDirectory(parent,base+'.stage-'+record.token+suffix,protect);
  removeTransactionDirectory(dataDir,'install-js-'+record.token,[root]);
  writeJson(file,{...record,cleanupAt:Date.now()},{backup:false});
  return true;
}

export function cleanupFinishedMigration(dataDir,isAlive) {
  const file=path.join(dataDir,'javascript-legacy-migration.json');let record=readJson(file);
  const journal=readJson(path.join(dataDir,'javascript-install-journal.json')),migration=journal?.migration;
  if(journal?.schema===1&&migration&&['committed','rolled-back'].includes(journal.phase)&&(!record||record.cleanupAt||record.token===migration.token)&&(!record||record.token!==migration.token||!['committed','rolled-back'].includes(record.phase))){
    record={...migration,phase:journal.phase,ownerPid:journal.ownerPid,ownerStartedTicks:journal.ownerStartedTicks,at:Date.now()};writeJson(file,record,{backup:false});
  }
  if(!record||record.cleanupAt)return true;
  if(!['committed','rolled-back'].includes(record.phase))return false;
  if(!/^[a-f0-9-]{36}$/i.test(record.token??'')||!path.isAbsolute(record.root??'')||key(record.dataDir??'.')!==key(dataDir))throw Error('迁移清理记录无效');
  if(isAlive(record.ownerPid,record.ownerStartedTicks))return false;
  const source=inside(dataDir,'updates/'+record.token);
  if(key(source)!==key(record.source??'.'))throw Error('迁移缓存清理路径无效');
  removeTransactionDirectory(inside(dataDir,'updates'),record.token,[record.root]);
  const job=inside(dataDir,'migration-jobs/'+record.token+'.json');
  if(fs.existsSync(job))fs.unlinkSync(job);
  const handoff=inside(dataDir,'javascript-migration-handoff.json');
  if(readJson(handoff)?.token===record.token)fs.unlinkSync(handoff);
  writeJson(file,{...record,cleanupAt:Date.now()},{backup:false});
  return true;
}
