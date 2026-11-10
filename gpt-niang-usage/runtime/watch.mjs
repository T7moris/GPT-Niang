import fs from 'node:fs';
import path from 'node:path';
import {readUsage,atomicJson,resolveCodexExecutable} from './usage.mjs';
import {createRefreshQueue,mergeUsageSnapshot,readRefreshRequest} from './refresh-queue.mjs';
import {acquireWorkerLock,processAlive,readJson,quotaPresenceActive} from './worker-state.mjs';
import {readPendingRequests,completeRequests,cleanRefreshResults,widgetUpdating,updatingSnapshot} from './refresh-client.mjs';

import {createPipeRefreshHandler} from './worker-ipc.mjs';
import {pluginVersion} from './metadata.mjs';

const config=readJson(process.argv[2]);
if(!config?.dataDir || !config?.codexPath)throw new Error('Invalid widget installation configuration');
if(widgetUpdating(config.dataDir))process.exit(0);
const parentPid=Number(process.argv[3]??0);
if(!Number.isSafeInteger(parentPid) || parentPid<0)throw new Error('Invalid parent process id');
const inheritStop=process.argv[4]==='--inherit-stop';
const handoffSupported=process.platform==='darwin' || inheritStop;
let refresh;
const ipc=createPipeRefreshHandler(()=>{if(refresh)void refresh.request();});
const lock=await acquireWorkerLock(config.dataDir,parentPid,{onLost:()=>process.exit(1),onConnection:ipc.onConnection});
if(!lock)process.exit(0);
const statusFile=path.join(config.dataDir,'status.json');
const healthFile=path.join(config.dataDir,'worker-status.json');
const handoffFile=handoffSupported?path.join(config.dataDir,'worker-handoff-'+lock.owner.token+'.flag'):null;
let status=null,requestToken=readRefreshRequest(path.join(config.dataDir,'refresh.flag')),lastActivity=Date.now(),heartbeat;
const activeRequestIds=new Set();
const initialStop=readRefreshRequest(path.join(config.dataDir,'stop.flag'));
const save=data=>{atomicJson(statusFile,data);status=data;};
const health=()=>atomicJson(healthFile,{...lock.owner,version:pluginVersion,...(handoffSupported?{handoffProtocol:1}:{}),at:Date.now(),busy:refresh.busy,lastRefresh:refresh.lastRefresh});
function stopForOwner(request) {
  if(request===null)return false;
  if(handoffSupported){
    const fields=request.split(':');
    const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    if(fields.length===4 && fields[1]==='worker-handoff' && uuid.test(fields[2]) && uuid.test(fields[3]))return fields[2]===lock.owner.token;
  }
  return true;
}
function exit() {
  clearInterval(heartbeat);
  // This path belongs only to the exiting owner's token; general stop.flag stays intact.
  try{if(handoffFile)fs.unlinkSync(handoffFile);}catch{}
  try{if(readJson(healthFile)?.token===lock.owner.token)fs.unlinkSync(healthFile);}catch{}
  try{lock.release();}catch{}
}
process.on('exit',exit);
process.on('SIGTERM',()=>process.exit(0));
process.on('SIGINT',()=>process.exit(0));
if(parentPid && !processAlive(parentPid))process.exit(0);
refresh=createRefreshQueue(async()=>{
  lastActivity=Date.now();
  const batch=readPendingRequests(config.dataDir);
  const pipeBatch=ipc.takeBatch();
  if(widgetUpdating(config.dataDir)){ipc.complete(pipeBatch,updatingSnapshot());completeRequests(config.dataDir,batch,updatingSnapshot());return;}
  for(const request of batch)activeRequestIds.add(request.id);
  try {
    const next=await readUsage(resolveCodexExecutable(config.codexPath),{onAccount:accountKey=>{
      if(status?.accountKey!==accountKey || !accountKey)save({ok:false,queryOk:false,accountKey,error:'正在读取当前账户额度…',windows:[],checkedAt:Date.now()});
    }});
    save(mergeUsageSnapshot(status,next));
    ipc.complete(pipeBatch,status);
    completeRequests(config.dataDir,batch,status);
    lastActivity=Date.now();
  } catch(error) {
    ipc.fail(pipeBatch);
    throw error;
  } finally {activeRequestIds.clear();}
},{onError:error=>{
  // A temporary filesystem failure must not stop the quota worker.
  const code=typeof error?.code==='string'?error.code:'IO';
  console.error('Quota snapshot could not be saved; next refresh will retry ('+code+').');
}});

// Persisted snapshots have not yet been matched to the current login.
save({ok:false,queryOk:false,error:'正在读取当前账户额度…',windows:[],checkedAt:Date.now()});
health();
if(parentPid)void refresh.request();
heartbeat=setInterval(()=>{
  if(widgetUpdating(config.dataDir)){completeRequests(config.dataDir,readPendingRequests(config.dataDir),updatingSnapshot());ipc.complete(ipc.takeBatch(),updatingSnapshot());process.exit(0);}
  const handingOff=handoffFile && readRefreshRequest(handoffFile)!==null;
  const stop=readRefreshRequest(path.join(config.dataDir,'stop.flag'));
  const stopApplies=stopForOwner(stop);
  // Mac GUI startup opts in to inheriting old requests; other GUI callers retain their stop behavior.
  if((parentPid && (!processAlive(parentPid) || (!inheritStop && stopApplies))) || (stopApplies && stop!==initialStop))process.exit(0);
  if(handingOff){
    if(!refresh.busy)process.exit(0);
    try{health();}catch{}
    return; // Finish the current query; leave new file requests for the next owner.
  }
  // macOS may opt into background quota alerts. Other clients keep visibility gating.
  const now=Date.now(),presence=readJson(path.join(config.dataDir,'presence.json'));
  const active=quotaPresenceActive(presence,now);
  if(active)lastActivity=now;
  const request=readRefreshRequest(path.join(config.dataDir,'refresh.flag'));
  const requested=request!==null && request!==requestToken;
  if(requested)requestToken=request;
  const pending=readPendingRequests(config.dataDir,now);
  if(requested)void refresh.request();
  else if(pending.some(request=>!activeRequestIds.has(request.id)) || (active && !refresh.busy && now-refresh.lastRefresh>=60000))void refresh.request();
  if(!parentPid && !active && !refresh.busy && pending.length===0 && ipc.pendingCount===0 && now-lastActivity>=30000)process.exit(0);
  cleanRefreshResults(config.dataDir,now);
  try{health();}catch{}
},1000);
