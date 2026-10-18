import fs from 'node:fs';
import path from 'node:path';
import https from 'node:https';
import {createHash, randomUUID} from 'node:crypto';
import {inflateRawSync} from 'node:zlib';
import {spawn,spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {homedir} from 'node:os';
import {atomicJson} from './usage.mjs';

export const DAY = 86400000;
export const RELEASE_API = 'https://api.github.com/repos/T7moris/GPT-Niang/releases/latest';
const RELEASE_PATH = '/T7moris/GPT-Niang/releases/download/';
const MAX_ZIP = 50 * 1024 * 1024, MAX_EXPANDED = 100 * 1024 * 1024;
const read = file => {try{return JSON.parse(fs.readFileSync(file,'utf8'));}catch{return null;}};
const readTransaction = file => {
  if(!fs.existsSync(file))return null;
  const record=read(file);
  if(!record || typeof record!=='object' || Array.isArray(record))throw new Error('Invalid update transaction; recover it before starting another update');
  return record;
};
const alive = pid => {try{process.kill(pid,0);return true;}catch{return false;}};
const pause = ms => new Promise(resolve=>setTimeout(resolve,ms));

export function resolveUpdateAgentDir(config={}, {userProfile=process.env.USERPROFILE||homedir()}={}) {
  if(config.updateAgent!==undefined) {
    if(typeof config.updateAgent!=='string' || !path.isAbsolute(config.updateAgent))throw new Error('Invalid stable updater directory');
    return path.resolve(config.updateAgent);
  }
  if(!userProfile || !path.isAbsolute(userProfile))throw new Error('User profile folder unavailable');
  return path.join(userProfile,'.gpt-niang','update-agent');
}

export function versionParts(version) {
  const match = /^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.exec(version);
  return match ? match.slice(1).map(BigInt) : null;
}
export function compareVersions(a,b) {
  const left=versionParts(a), right=versionParts(b);
  if(!left || !right)throw new Error('Invalid stable version');
  for(let i=0;i<3;i++)if(left[i]!==right[i])return left[i]>right[i]?1:-1;
  return 0;
}
export function updatePreferences(dataDir) {
  return {automatic:read(path.join(dataDir,'update-preferences.json'))?.automatic !== false};
}
export function checkDue(state,startedAt,now=Date.now()) {
  return now>=Math.max(startedAt+30000,Number(state?.nextCheckAt)||0);
}
export function isGitCheckout(directory) {
  for(let dir=path.resolve(directory);;dir=path.dirname(dir)) {
    if(fs.existsSync(path.join(dir,'.git')))return true;
    if(path.dirname(dir)===dir)return false;
  }
}
export function allowedUrl(value,{api=false}={}) {
  const url=new URL(value);
  if(url.protocol!=='https:' || url.username || url.password || url.port || url.hash)throw new Error('Untrusted update URL');
  const host=url.hostname.toLowerCase();
  const allowed=api ? value===RELEASE_API :
    (host==='github.com' && url.pathname.startsWith(RELEASE_PATH)) ||
    ['release-assets.githubusercontent.com','github-releases.githubusercontent.com'].includes(host);
  if(!allowed)throw new Error('Untrusted update host');
  return url;
}

// No token, cookie, proxy credentials or login configuration is read here.
export async function download(url,{limit=MAX_ZIP,api=false,request=https.get,onProgress=()=>{},redirects=0}={}) {
  allowedUrl(url,{api});
  if(redirects>5)throw new Error('Too many update redirects');
  return new Promise((resolve,reject)=>{
    const req=request(url,{headers:{'User-Agent':'GPTNiangUsage-Updater','Accept':api?'application/vnd.github+json':'application/octet-stream'}},response=>{
      const status=response.statusCode;
      if([301,302,303,307,308].includes(status)) {
        response.resume();
        if(api){reject(new Error('Unexpected API redirect'));return;}
        try{const next=new URL(response.headers.location,url).href;
          download(next,{limit,request,onProgress,redirects:redirects+1}).then(resolve,reject);
        }catch(error){reject(error);}return;
      }
      if(status!==200) {
        response.resume();
        const error=new Error('GitHub update request failed ('+status+')');
        if(status===429 || (status===403 && response.headers['x-ratelimit-remaining']==='0')) {
          const retry=response.headers['retry-after'];
          const seconds=/^\d+$/.test(retry??'')?Number(retry)*1000:Date.parse(retry)-Date.now();
          const reset=Number(response.headers['x-ratelimit-reset'])*1000-Date.now();
          const hints=[seconds,reset].filter(value=>Number.isFinite(value)&&value>=0);
          error.retryAfterMs=hints.length?Math.max(1000,...hints):DAY;
        }
        reject(error);return;
      }
      if(Number(response.headers['content-length'])>limit){response.destroy();reject(new Error('Update download exceeds size limit'));return;}
      const chunks=[];let bytes=0;
      response.on('data',chunk=>{
        bytes+=chunk.length;
        if(bytes>limit){response.destroy(new Error('Update download exceeds size limit'));return;}
        chunks.push(chunk);try{onProgress(bytes);}catch(error){response.destroy(error);}
      });
      response.on('error',reject);
      response.on('aborted',()=>reject(new Error('Update download interrupted')));
      response.on('end',()=>resolve(Buffer.concat(chunks)));
    });
    req.on('error',reject);
    req.setTimeout(30000,()=>req.destroy(new Error('Update download timed out')));
  });
}
export function selectRelease(release,currentVersion) {
  if(release.draft || release.prerelease || !versionParts(release.tag_name))return null;
  if(compareVersions(release.tag_name,currentVersion)<=0)return null;
  const version=release.tag_name.replace(/^v/,'');
  const name=`gpt-niang-usage-widget-v${version}-windows.zip`;
  const choose=name=>{
    const matches=(release.assets??[]).filter(asset=>asset.name===name);
    if(matches.length!==1)throw new Error('Required Windows release asset missing or duplicated');
    const asset=matches[0];allowedUrl(asset.browser_download_url);
    const expected=RELEASE_PATH+encodeURIComponent(release.tag_name)+'/'+encodeURIComponent(name);
    if(new URL(asset.browser_download_url).hostname!=='github.com' || new URL(asset.browser_download_url).pathname!==expected)throw new Error('Release asset path mismatch');
    if(asset.size>MAX_ZIP)throw new Error('Release asset exceeds size limit');
    return asset;
  };
  return {version,zip:choose(name),sums:choose('SHA256SUMS.txt')};
}
export function verifyHash(bytes,sums,asset) {
  const matching=sums.toString('utf8').split(/\r?\n/).filter(line=>line.slice(66).replace(/^\*/,'')===asset.name);
  if(matching.length!==1 || !/^[a-f\d]{64} [ *]/i.test(matching[0]))throw new Error('Invalid release checksum file');
  const hash=createHash('sha256').update(bytes).digest('hex');
  if(hash!==matching[0].slice(0,64).toLowerCase())throw new Error('Release SHA256 mismatch');
  verifyAssetDigest(bytes,asset);
  return hash;
}
export function verifyAssetDigest(bytes,asset) {
  if(asset.digest && asset.digest.toLowerCase()!=='sha256:'+createHash('sha256').update(bytes).digest('hex'))throw new Error('GitHub asset digest mismatch');
  if(Number.isSafeInteger(asset.size) && asset.size!==bytes.length)throw new Error('GitHub asset size mismatch');
}

let crcTable;
function crc32(bytes) {
  crcTable??=Array.from({length:256},(_,n)=>{for(let i=0;i<8;i++)n=(n&1)?0xedb88320^(n>>>1):n>>>1;return n>>>0;});
  let crc=0xffffffff;for(const byte of bytes)crc=crcTable[(crc^byte)&255]^(crc>>>8);
  return (crc^0xffffffff)>>>0;
}
export function safeZipName(name) {
  if(!name || name.includes('\\') || name.startsWith('/') || /[\x00-\x1f\x7f:<>"|?*]/.test(name))throw new Error('Unsafe ZIP path');
  const pieces=name.replace(/\/$/,'').split('/');
  if(name.length>1024 || pieces.some(part=>!part || part.length>255 || ['.','..','.git'].includes(part.toLowerCase()) || /[. ]$/.test(part) || /^(con|prn|aux|nul|conin\$|conout\$|com[1-9¹²³]|lpt[1-9¹²³])(?:\.|$)/i.test(part)))throw new Error('Illegal Windows ZIP path');
  if(/\.(exe|dll)$/i.test(name))throw new Error('Unexpected executable in update');
}

// Validate the central directory and every local record before writing any file.
// ZIP64, encryption, links, duplicate paths and overlapping records are not supported.
export function inspectZip(bytes) {
  if(bytes.length>MAX_ZIP || bytes.length<22)throw new Error('Invalid ZIP size');
  let end=-1;
  for(let i=bytes.length-22;i>=Math.max(0,bytes.length-65557);i--)if(bytes.readUInt32LE(i)===0x06054b50 && i+22+bytes.readUInt16LE(i+20)===bytes.length){end=i;break;}
  if(end<0)throw new Error('ZIP directory missing');
  const count=bytes.readUInt16LE(end+10),offset=bytes.readUInt32LE(end+16),size=bytes.readUInt32LE(end+12);
  if(!count || count>1000 || bytes.readUInt16LE(end+4) || bytes.readUInt16LE(end+6) || bytes.readUInt16LE(end+8)!==count || offset+size!==end)throw new Error('Unsupported ZIP directory');
  let cursor=offset,total=0;const entries=[],names=new Set(),ranges=[];
  for(let i=0;i<count;i++) {
    if(cursor+46>end || bytes.readUInt32LE(cursor)!==0x02014b50)throw new Error('Invalid ZIP entry');
    const flags=bytes.readUInt16LE(cursor+8),method=bytes.readUInt16LE(cursor+10),crc=bytes.readUInt32LE(cursor+16),compressed=bytes.readUInt32LE(cursor+20),expanded=bytes.readUInt32LE(cursor+24);
    const length=bytes.readUInt16LE(cursor+28),extra=bytes.readUInt16LE(cursor+30),comment=bytes.readUInt16LE(cursor+32),local=bytes.readUInt32LE(cursor+42);
    if(cursor+46+length+extra+comment>end || bytes.readUInt16LE(cursor+34) || (flags&~0x808) || ![0,8].includes(method))throw new Error('Unsupported ZIP entry');
    const raw=bytes.subarray(cursor+46,cursor+46+length),name=new TextDecoder('utf-8',{fatal:true}).decode(raw);safeZipName(name);
    const mode=bytes.readUInt32LE(cursor+38)>>>16,type=mode&0xf000;
    if(bytes.readUInt32LE(cursor+38)&0x400)throw new Error('ZIP reparse points are forbidden');
    if(type && type!==0x8000 && type!==0x4000)throw new Error('ZIP links or special files are forbidden');
    if(type===0x4000 && !name.endsWith('/'))throw new Error('ZIP directory type mismatch');
    const key=name.replace(/\/$/,'').toLowerCase();if(names.has(key))throw new Error('Duplicate ZIP path');names.add(key);
    total+=expanded;if(total>MAX_EXPANDED)throw new Error('ZIP expansion exceeds size limit');
    if(local+30>offset || bytes.readUInt32LE(local)!==0x04034b50 || bytes.readUInt16LE(local+6)!==flags || bytes.readUInt16LE(local+8)!==method)throw new Error('Invalid ZIP local record');
    const localNameLength=bytes.readUInt16LE(local+26),localExtra=bytes.readUInt16LE(local+28),start=local+30+localNameLength+localExtra,finish=start+compressed;
    if(finish>offset || !raw.equals(bytes.subarray(local+30,local+30+localNameLength)))throw new Error('ZIP local path mismatch');
    if(ranges.some(([a,b])=>local<b && finish>a))throw new Error('Overlapping ZIP records');ranges.push([local,finish]);
    let data;
    try{data=method===0?bytes.subarray(start,finish):inflateRawSync(bytes.subarray(start,finish),{maxOutputLength:Math.max(1,expanded)});}catch{throw new Error('Invalid ZIP compression');}
    if(data.length!==expanded || crc32(data)!==crc || (name.endsWith('/') && expanded!==0))throw new Error('ZIP entry integrity mismatch');
    entries.push({name,data});cursor+=46+length+extra+comment;
  }
  if(cursor!==end)throw new Error('ZIP directory size mismatch');
  const roots=new Set(entries.map(entry=>entry.name.split('/')[0]));if(roots.size!==1)throw new Error('Unexpected package roots');
  const root=[...roots][0],files=new Map(entries.filter(entry=>!entry.name.endsWith('/')).map(entry=>[entry.name.slice(root.length+1),entry.data]));
  for(const name of files.keys())for(let dir=path.posix.dirname(name);dir!=='.';dir=path.posix.dirname(dir))if(files.has(dir))throw new Error('ZIP file/directory collision');
  return {entries,root,files};
}
export function validatePackage(zip,version) {
  const json=name=>{try{return JSON.parse(zip.files.get(name).toString('utf8'));}catch{throw new Error('Invalid package metadata: '+name);}};
  if(json('gpt-niang-usage/.codex-plugin/plugin.json').version!==version || json('gpt-niang-usage/package.json').version!==version)throw new Error('Package version mismatch');
  json('.agents/plugins/marketplace.json');
  const required=json('gpt-niang-usage/runtime/install-files.json');
  if(!Array.isArray(required) || required.length>200)throw new Error('Invalid installation file list');
  for(const name of ['Install.ps1','runtime/update.mjs','runtime/update-helper.ps1','runtime/update-agent.ps1','runtime/update-lock.ps1','runtime/install-preflight.ps1','runtime/update-common.ps1',...required]) {
    safeZipName(name.replaceAll('\\','/'));
    if(!zip.files.has('gpt-niang-usage/'+name.replaceAll('\\','/')))throw new Error('Required package file missing: '+name);
  }
  for(const name of zip.files.keys())if(/(^|\/)(installation|settings|update-preferences|update-transaction)\.json$/i.test(name))throw new Error('Local state in release package');
}
export function extractPackage(zip,directory) {
  fs.mkdirSync(directory,{recursive:true});
  for(const {name,data} of zip.entries) {
    const destination=path.join(directory,...name.split('/'));
    if(name.endsWith('/'))fs.mkdirSync(destination,{recursive:true});
    else {fs.mkdirSync(path.dirname(destination),{recursive:true});fs.writeFileSync(destination,data,{flag:'wx'});}
  }
  return path.join(directory,zip.root);
}
export function validateExtractedPackage(archive,candidate,version,hash) {
  const bytes=fs.readFileSync(archive);
  if(createHash('sha256').update(bytes).digest('hex')!==hash.toLowerCase())throw new Error('Downloaded archive changed');
  const zip=inspectZip(bytes);validatePackage(zip,version);
  const found=new Set();
  const walk=directory=>{
    for(const name of fs.readdirSync(directory)) {
      const file=path.join(directory,name),stat=fs.lstatSync(file);
      if(stat.isSymbolicLink())throw new Error('Link in extracted package');
      if(stat.isDirectory())walk(file);
      else {
        const relative=path.relative(candidate,file).split(path.sep).join('/'),expected=zip.files.get(relative);
        if(!stat.isFile() || !expected || stat.size!==expected.length || !fs.readFileSync(file).equals(expected))throw new Error('Extracted package changed: '+relative);
        found.add(relative);
      }
    }
  };
  if(fs.lstatSync(candidate).isSymbolicLink())throw new Error('Linked candidate directory');
  walk(candidate);if(found.size!==zip.files.size)throw new Error('Extracted package files missing');
}

export function acquireUpdateLock(agentDir) {
  fs.mkdirSync(agentDir,{recursive:true});const dir=path.join(agentDir,'update.lock');
  try{fs.mkdirSync(dir);}catch(error){
    if(error.code!=='EEXIST')throw error;
    const owner=read(path.join(dir,'owner.json'));
    // An incomplete owner record is not reclaimed until its creator had time to publish it.
    if(owner ? [owner.pid,owner.helperPid].some(pid=>Number.isSafeInteger(pid)&&pid>0&&alive(pid)) : Date.now()-fs.statSync(dir).mtimeMs<60000)return null;
    if(process.platform!=='win32')throw new Error('Stale update recovery supports Windows only');
    const bridge=spawnSync(path.join(process.env.WINDIR,'System32','WindowsPowerShell','v1.0','powershell.exe'),['-NoProfile','-ExecutionPolicy','Bypass','-File',fileURLToPath(new URL('./update-lock.ps1',import.meta.url)),'-AgentDir',path.resolve(agentDir),'-OwnerPid',String(process.pid)],{windowsHide:true,encoding:'utf8',timeout:15000});
    if(bridge.error)throw new Error('Could not recover the stale update lock');
    if(bridge.status===2)return null;
    if(bridge.status!==0)throw new Error('Could not recover the stale update lock');
    const claimed=JSON.parse(bridge.stdout.trim());
    if(claimed.pid!==process.pid || read(path.join(dir,'owner.json'))?.token!==claimed.token)throw new Error('Update lock claim mismatch');
    return updateLockHandle(dir,claimed);
  }
  const owner={pid:process.pid,token:randomUUID(),at:Date.now()};atomicJson(path.join(dir,'owner.json'),owner);
  return updateLockHandle(dir,owner);
}
const updateLockHandle=(dir,owner)=>({owner,release(){if(read(path.join(dir,'owner.json'))?.token===owner.token)fs.rmSync(dir,{recursive:true});}});
function removeDownloadedJob(config,directory,token) {
  const parent=path.resolve(config.dataDir,'updates'),target=path.resolve(directory);
  if(!/^[a-f\d]{8}(?:-[a-f\d]{4}){3}-[a-f\d]{12}$/i.test(token) || target!==path.join(parent,token))throw new Error('Unsafe update cache cleanup path');
  for(let current=target;;current=path.dirname(current)){
    if(fs.existsSync(current) && fs.lstatSync(current).isSymbolicLink())throw new Error('Linked update cache cleanup path');
    if(path.dirname(current)===current)break;
  }
  const inspect=directory=>{
    for(const name of fs.readdirSync(directory)){
      const child=path.join(directory,name),stat=fs.lstatSync(child);
      if(stat.isSymbolicLink())throw new Error('Link in update cache');
      if(stat.isDirectory())inspect(child);
    }
  };
  if(fs.existsSync(target)){inspect(target);fs.rmSync(target,{recursive:true});}
}
function hasDownloadedJobs(config) {
  const parent=path.join(config.dataDir,'updates');
  try{return fs.readdirSync(parent).some(name=>fs.existsSync(path.join(parent,name,'update-job.json')));}catch{return false;}
}
export function installIdle(config,mode,now=Date.now()) {
  const idle=read(path.join(config.dataDir,'update-idle.json')),worker=read(path.join(config.dataDir,'worker-status.json'));
  return !!(idle && now-idle.at>=0 && now-idle.at<5000 && alive(idle.pid) && !idle.editor && !idle.menu && !idle.drag && !worker?.busy);
}
const jobs=new Map();
export function runUpdate(config,options={}) {
  const key=path.resolve(config.appDir);
  if(jobs.has(key))return jobs.get(key);
  const job=performUpdate(config,options).finally(()=>jobs.delete(key));jobs.set(key,job);return job;
}
async function performUpdate(config,{mode='manual',agentDir=resolveUpdateAgentDir(config),fetchBytes=download,cleanup=token=>new Promise((resolve,reject)=>{
  const child=spawn(path.join(process.env.WINDIR,'System32','WindowsPowerShell','v1.0','powershell.exe'),['-NoProfile','-ExecutionPolicy','Bypass','-File',path.join(agentDir,'update-helper.ps1'),'-Cleanup','-Token',token],{windowsHide:true,stdio:'ignore'});
  child.once('error',reject);child.once('exit',code=>code===0?resolve():reject(new Error('更新文件清理未完成，请关闭占用旧文件的程序后重试。')));
}),waitIdle=async()=>{
  while(!installIdle(config,mode)) {
    if(mode.startsWith('automatic') && !updatePreferences(config.dataDir).automatic)return false;
    const idle=read(path.join(config.dataDir,'update-idle.json'));
    if(!idle || !alive(idle.pid) || Date.now()-idle.at>60000)throw new Error('Widget closed before update installation');
    await pause(1000);
  }return true;
},launch=(journal,token)=>new Promise((resolve,reject)=>{
  const child=spawn(path.join(process.env.WINDIR,'System32','WindowsPowerShell','v1.0','powershell.exe'),['-NoProfile','-ExecutionPolicy','Bypass','-File',path.join(agentDir,'update-helper.ps1'),'-Token',token],{windowsHide:true,stdio:'ignore'});
  child.once('error',reject);child.once('exit',code=>code===0?resolve():reject(new Error('Update installation failed; see recovery diagnostics')));
})}={}) {
  const automatic=mode.startsWith('automatic');
  const stateFile=path.join(config.dataDir,'update-status.json');
  const state=read(stateFile)??{};const report=value=>atomicJson(stateFile,Object.assign(state,value));
  if(isGitCheckout(config.appDir)){report({phase:'source',message:'源码目录请使用 Git 更新，或另行安装 Release。'});return;}
  if(Date.now()<(state.retryAfterAt??0)){report({phase:'rate-limited',message:'GitHub 限流，请在允许重试的时间之后检查。'});return;}
  if(automatic && (!updatePreferences(config.dataDir).automatic || (mode==='automatic' && Date.now()<(state.nextCheckAt??0))))return;
  let lock,jobDir;
  try{lock=acquireUpdateLock(agentDir);}catch(error){report({phase:'failed',message:error.message,nextCheckAt:Date.now()+DAY});return;}
  if(!lock)return;
  try {
    const oldJournal=readTransaction(path.join(agentDir,'update-transaction.json'));
    if(oldJournal && !['committed','rolled-back'].includes(oldJournal.phase))throw new Error('Unfinished update requires recovery from the stable launcher');
    if(mode==='cleanup' || oldJournal?.cleanupPending || hasDownloadedJobs(config)){
      await cleanup(lock.owner.token);
      if(readTransaction(path.join(agentDir,'update-transaction.json'))?.cleanupPending)throw new Error('Previous update cleanup is still pending');
    }
    if(mode==='cleanup')return;
    report({phase:'checking',message:'正在检查正式版…',nextCheckAt:Date.now()+DAY,retryAfterAt:0});
    const release=JSON.parse((await fetchBytes(RELEASE_API,{api:true,limit:1024*1024})).toString('utf8'));
    const selected=selectRelease(release,config.version);
    if(!selected){report({phase:'current',message:'已是最新正式版。'});return;}
    report({phase:'downloading',version:selected.version,message:'正在下载更新…',bytes:0});
    const sums=await fetchBytes(selected.sums.browser_download_url,{limit:1024*1024});
    verifyAssetDigest(sums,selected.sums);
    let lastProgress=0;
    const bytes=await fetchBytes(selected.zip.browser_download_url,{limit:MAX_ZIP,onProgress:bytes=>{if(Date.now()-lastProgress>500){lastProgress=Date.now();report({bytes});}}});
    const hash=verifyHash(bytes,sums,selected.zip),zip=inspectZip(bytes);validatePackage(zip,selected.version);
    const directory=path.join(config.dataDir,'updates',lock.owner.token);
    fs.mkdirSync(path.dirname(directory),{recursive:true});fs.mkdirSync(directory);jobDir=directory;
    atomicJson(path.join(jobDir,'update-job.json'),{schema:1,token:lock.owner.token,appDir:config.appDir,dataDir:config.dataDir});
    const archive=path.join(jobDir,'release.zip');fs.writeFileSync(archive,bytes,{flag:'wx'});
    const candidate=extractPackage(zip,path.join(jobDir,'package'));
    report({phase:'waiting',message:'下载已校验，等待挂件空闲…'});
    if(!await waitIdle()){report({phase:'cancelled',message:'自动更新已关闭。'});return;}
    if(automatic && !updatePreferences(config.dataDir).automatic){report({phase:'cancelled',message:'自动更新已关闭。'});return;}
    const journal={schema:1,token:lock.owner.token,phase:'prepared',appDir:config.appDir,dataDir:config.dataDir,root:path.dirname(config.appDir),candidate,archive,hash,version:selected.version,oldVersion:config.version,mode:automatic?'automatic':'manual',at:new Date().toISOString()};
    atomicJson(path.join(agentDir,'update-transaction.json'),journal);
    report({phase:'installing',message:'正在安装更新…'});
    await launch(journal,lock.owner.token);
  } catch(error) {
    const finalJournal=read(path.join(agentDir,'update-transaction.json'));
    report({phase:finalJournal?.token===lock.owner.token && finalJournal.phase==='rolled-back'?'rolled-back':'failed',message:error.message,nextCheckAt:Math.max(state.nextCheckAt??0,Date.now()+(error.retryAfterMs??DAY)),retryAfterAt:error.retryAfterMs?Date.now()+error.retryAfterMs:0});
  } finally {
    try {
      if(jobDir){
        const journal=read(path.join(agentDir,'update-transaction.json'));
        if(!journal || journal.token!==lock.owner.token || ['committed','rolled-back'].includes(journal.phase)){
          try{removeDownloadedJob(config,jobDir,lock.owner.token);}catch(error){report({cleanupPending:true,cleanupError:error.message});}
        }
      }
    } finally {lock.release();}
  }
}

if(process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  if(process.platform!=='win32')throw new Error('The updater supports Windows only');
  if(process.argv[2]==='--validate-package'){
    validateExtractedPackage(process.argv[3],process.argv[4],process.argv[5],process.argv[6]);process.exit(0);
  }
  const config=read(process.argv[2]);
  if(!config?.appDir || !config.dataDir || !versionParts(config.version) || path.resolve(config.appDir)!==path.dirname(path.resolve(process.argv[2])))throw new Error('Invalid updater configuration');
  const agentDir=resolveUpdateAgentDir(config),binding=read(path.join(agentDir,'binding.json'));
  if(!binding || path.resolve(binding.appDir)!==path.resolve(config.appDir) || path.resolve(binding.dataDir)!==path.resolve(config.dataDir))throw new Error('Updater installation binding mismatch');
  await runUpdate(config,{agentDir,mode:['automatic','automatic-enabled','cleanup'].includes(process.argv[3])?process.argv[3]:'manual'});
}
