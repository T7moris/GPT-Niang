import fs from 'node:fs';
import path from 'node:path';
import {createHash,randomUUID} from 'node:crypto';
import net from 'node:net';
import {spawn} from 'node:child_process';
import {atomicJson} from './usage.mjs';

export function readJson(file) {
  try{return JSON.parse(fs.readFileSync(file,'utf8').replace(/^\uFEFF/,''));}catch{return null;}
}

export function processAlive(pid) {
  if(!Number.isSafeInteger(pid) || pid<=0)return false;
  try{process.kill(pid,0);return true;}catch(error){return error.code==='EPERM';}
}

export function healthyWorker(dataDir,now=Date.now()) {
  const status=readJson(path.join(dataDir,'worker-status.json'));
  const owner=readJson(path.join(dataDir,'worker.lock'));
  return status && owner && status.token===owner.token && status.pid===owner.pid && now-status.at>=0 && now-status.at<5000 && processAlive(status.pid) && (!status.parentPid || processAlive(status.parentPid))?status:null;
}

export function workerEndpoint(dataDir){
  const key=createHash('sha256').update(path.resolve(dataDir).toLowerCase()).digest('hex').slice(0,32);
  return process.platform==='win32'?'\\\\.\\pipe\\gpt-niang-usage-'+key:path.join(dataDir,'worker.sock');
}

export async function acquireWorkerLock(dataDir,parentPid=0,{pid=process.pid,onLost=()=>{},onConnection=socket=>socket.destroy()}={}) {
  fs.mkdirSync(dataDir,{recursive:true});
  const file=path.join(dataDir,'worker.lock');
  const owner={pid,parentPid,token:randomUUID(),startedAt:Date.now()};
  if(process.platform==='darwin'){
    // lockf -k uses a kernel flock and keeps its inode stable. The small holder
    // exits on stdin EOF, so a killed worker releases ownership automatically.
    const hold="process.stdout.write('locked\\n');process.stdin.resume();process.stdin.on('end',()=>process.exit(0));";
    const holder=spawn('/usr/bin/lockf',['-k','-s','-t','0',path.join(dataDir,'worker-ownership.lock'),process.execPath,'-e',hold],{stdio:['pipe','pipe','ignore']});
    let released=false;
    holder.stdin.on('error',()=>{});
    const claimed=await new Promise((resolve,reject)=>{
      const timer=setTimeout(()=>{released=true;holder.stdin.end();holder.kill();reject(new Error('macOS worker lock timed out'));},5000);
      holder.once('error',error=>{clearTimeout(timer);reject(error);});
      holder.stdout.once('data',()=>{clearTimeout(timer);resolve(true);});
      holder.once('exit',code=>{clearTimeout(timer);code===75?resolve(false):reject(new Error('macOS worker lock failed: '+code));});
    });
    if(!claimed)return null;
    holder.on('exit',()=>{if(!released)onLost();});
    const release=()=>new Promise(resolve=>{
      if(released){resolve();return;}
      released=true;
      try{if(readJson(file)?.token===owner.token)fs.unlinkSync(file);}catch{}
      holder.once('exit',resolve);holder.stdin.end();
    });
    try{atomicJson(file,owner);}catch(error){await release();throw error;}
    return {owner,release};
  }
  const endpoint=workerEndpoint(dataDir);
  // Windows removes the pipe with its owning process. Stale owner files are
  // informational only, so competing restarts cannot unlink a new owner's lock.
  const server=net.createServer(onConnection);
  const claimed=await new Promise((resolve,reject)=>{
    server.once('error',error=>error.code==='EADDRINUSE'?resolve(false):reject(error));
    server.listen(endpoint,()=>resolve(true));
  });
  if(!claimed)return null;
  try{atomicJson(file,owner);}catch(error){server.close();throw error;}
  return {owner,release(){
    try{if(readJson(file)?.token===owner.token)fs.unlinkSync(file);}catch{}
    return new Promise(resolve=>server.close(resolve));
  }};
}
