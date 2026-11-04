import fs from 'node:fs';
import path from 'node:path';
import {randomUUID,createHash} from 'node:crypto';
import {inspectJavaScriptPackage} from './archive.mjs';
import {verifyHash} from './update-network.mjs';
import {inside,readJson,writeJson} from './storage.mjs';
import {processIdentity} from '../../runtime/process-identity.mjs';
import {removeTransactionDirectory} from './update-cleanup.mjs';
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
const buffer=value=>Buffer.from(value.buffer,value.byteOffset,value.byteLength);
export async function updateFiles(task){
  if(task.kind==='stage'){
    const bytes=buffer(task.bytes),sums=buffer(task.sums),digest=verifyHash(bytes,sums,task.asset),files=inspectJavaScriptPackage(bytes,task.version);
    const updates=inside(task.dataDir,'updates'),token=randomUUID(),directory=inside(updates,token);
    fs.mkdirSync(updates,{recursive:true});fs.mkdirSync(directory);
    try{
      for(const file of files){const target=inside(directory,file.name);fs.mkdirSync(path.dirname(target),{recursive:true});fs.writeFileSync(target,file.bytes,{flag:'wx'});}
      fs.writeFileSync(path.join(directory,'verified-package.zip'),bytes,{flag:'wx'});
      return {directory,hash:digest};
    }catch(error){
      try{removeTransactionDirectory(updates,token);}catch(cleanup){error.message+='；缓存清理未完成：'+cleanup.message;}
      throw error;
    }
  }
  if(task.kind!=='prepare')throw Error('无效更新文件任务');
  const source=path.resolve(task.directory),updates=path.resolve(task.dataDir,'updates');
  if(!source.startsWith(updates+path.sep))throw Error('更新缓存目录无效');
  const zip=fs.readFileSync(path.join(source,'verified-package.zip'));if(hash(zip)!==task.hash)throw Error('更新缓存已改变');
  const files=inspectJavaScriptPackage(zip,task.version);
  for(const file of files)if(!fs.readFileSync(inside(source,file.name)).equals(file.bytes))throw Error('更新候选文件已改变：'+file.name);
  if(!/^[a-z0-9-]{1,100}$/i.test(task.token??''))throw Error('更新助手标识无效');
  const agents=inside(task.dataDir,'update-agent-js'),agent=inside(agents,task.token);
  fs.mkdirSync(agents,{recursive:true});fs.mkdirSync(agent);
  try{
  for(const file of ['src/update-agent.mjs','src/core/storage.mjs','src/core/update-transaction.mjs','src/core/update-network.mjs','src/core/update-cleanup.mjs','src/core/installation-health.mjs','runtime/process-identity.mjs']){
    const target=inside(agent,file);fs.mkdirSync(path.dirname(target),{recursive:true});fs.copyFileSync(path.join(task.root,file),target);
  }
  const ffi=path.join(task.root,'node_modules','koffi');if(fs.existsSync(ffi))fs.cpSync(ffi,path.join(agent,'node_modules','koffi'),{recursive:true});
  const platformFfi=path.join(task.root,'node_modules','@koromix',`koffi-${process.platform}-${process.arch}`);
  if(fs.existsSync(platformFfi))fs.cpSync(platformFfi,path.join(agent,'node_modules','@koromix',path.basename(platformFfi)),{recursive:true});
  let executable=task.nodePath;const relative=path.relative(task.root,executable??task.root);
  let usable=false;try{usable=fs.statSync(executable).isFile();}catch{}
  if(!usable||(!relative.startsWith('..')&&!path.isAbsolute(relative))){
    const runtimeName='node_modules/electron/dist/electron.exe';
    if(!files.some(file=>file.name===runtimeName))throw Error('更新包缺少独立运行环境');
    // The verified staging runtime remains outside the directory being swapped.
    // Reuse it instead of copying another complete Electron distribution.
    executable=inside(source,runtimeName);
  }
  const job=path.join(agent,'job.json'),config=readJson(path.join(task.root,'installation.json'));
  const spec={root:task.root,dataDir:task.dataDir,source,parentPid:task.parentPid,parentStartedTicks:processIdentity(task.parentPid)?.startedTicks,version:task.version,fromVersion:readJson(path.join(task.root,'package.json'))?.version,hash:task.hash,token:task.token,agent,executable,job,launcherPath:config?.launcherPath,expected:files.map(f=>({name:f.name,hash:hash(f.bytes)}))};
  writeJson(job,spec,{backup:false});writeJson(path.join(task.dataDir,'javascript-update-journal.json'),{...spec,phase:'prepared',ownerPid:task.parentPid,ownerStartedTicks:spec.parentStartedTicks,at:Date.now()},{backup:false});
  return {agent,executable,job};
  }catch(error){
    try{removeTransactionDirectory(agents,task.token,[task.root,source]);}catch(cleanup){error.message+='；助手清理未完成：'+cleanup.message;}
    throw error;
  }
}
