import fs from 'node:fs';
import path from 'node:path';
import {createHash,randomUUID} from 'node:crypto';
import net from 'node:net';
import os from 'node:os';
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
  const resolved=path.resolve(dataDir);
  const key=createHash('sha256').update(process.platform==='win32'?resolved.toLowerCase():resolved).digest('hex').slice(0,32);
  // sockaddr_un has a small byte limit, including UTF-8 directory names.
  if(process.platform==='linux' && Buffer.byteLength(path.join(dataDir,'worker.sock'))>100)
    return path.join(os.tmpdir(),'gpt-niang-'+process.getuid()+'-'+key,'worker.sock');
  return process.platform==='win32'?'\\\\.\\pipe\\gpt-niang-usage-'+key:path.join(dataDir,'worker.sock');
}

async function acquireLinuxLock(dataDir,file,owner,onLost,onConnection) {
  // flock protects the stable inode while recovering an abandoned Unix socket.
  // Its holder exits on pipe EOF even if the worker dies from SIGKILL. Never
  // decide that a socket is stale and unlink it without kernel ownership.
  const hold="process.stdout.write('locked\\n');process.stdin.resume();process.stdin.on('end',()=>process.exit(0));";
  const flock=['/usr/bin/flock','/bin/flock'].find(file=>fs.existsSync(file)) || 'flock';
  const holder=spawn(flock,['--nonblock','--conflict-exit-code','75',path.join(dataDir,'worker-ownership.lock'),process.execPath,'-e',hold],{stdio:['pipe','pipe','ignore']});
  let released=false,server;
  holder.stdin.on('error',()=>{});
  const claimed=await new Promise((resolve,reject)=>{
    const timer=setTimeout(()=>{released=true;holder.stdin.end();holder.kill();reject(new Error('Linux worker lock timed out'));},5000);
    holder.once('error',error=>{clearTimeout(timer);reject(error);});
    holder.stdout.once('data',()=>{clearTimeout(timer);resolve(true);});
    holder.once('exit',code=>{clearTimeout(timer);code===75?resolve(false):reject(new Error('Linux worker lock failed: '+code));});
  });
  if(!claimed)return null;
  holder.on('exit',()=>{if(!released)onLost();});
  const releaseHolder=()=>new Promise(resolve=>{
    if(released){resolve();return;}
    released=true;
    if(holder.exitCode!==null){resolve();return;}
    holder.once('exit',resolve);holder.stdin.end();
  });
  const endpoint=workerEndpoint(dataDir);
  try {
    const parent=path.dirname(endpoint);
    fs.mkdirSync(parent,{recursive:true,mode:0o700});
    const stat=fs.lstatSync(parent);
    if(!stat.isDirectory() || stat.uid!==process.getuid())throw new Error('Unsafe Linux worker socket directory');
    if(parent!==dataDir)fs.chmodSync(parent,0o700);
    if(fs.existsSync(endpoint)){
      if(!fs.lstatSync(endpoint).isSocket())throw new Error('Worker endpoint is not a socket');
      const active=await new Promise(resolve=>{
        const socket=net.createConnection(endpoint);
        const finish=value=>{socket.destroy();resolve(value);};
        socket.once('connect',()=>finish(true));
        // Permission errors do not establish that the endpoint is stale.
        socket.once('error',error=>finish(!['ECONNREFUSED','ENOENT'].includes(error.code)));
        socket.setTimeout(500,()=>finish(true));
      });
      if(active){await releaseHolder();return null;}
      fs.rmSync(endpoint,{force:true});
    }
    server=net.createServer(onConnection);
    await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(endpoint,resolve);});
    fs.chmodSync(endpoint,0o600);
    atomicJson(file,owner);
  } catch(error) {
    if(server?.listening)await new Promise(resolve=>server.close(resolve));
    await releaseHolder();throw error;
  }
  return {owner,async release(){
    if(released)return;
    try{if(readJson(file)?.token===owner.token)fs.unlinkSync(file);}catch{}
    await new Promise(resolve=>server.close(resolve));
    await releaseHolder();
  }};
}

export async function acquireWorkerLock(dataDir,parentPid=0,{pid=process.pid,onLost=()=>{},onConnection=socket=>socket.destroy()}={}) {
  fs.mkdirSync(dataDir,{recursive:true});
  const file=path.join(dataDir,'worker.lock');
  const owner={pid,parentPid,token:randomUUID(),startedAt:Date.now()};
  if(process.platform==='linux')return acquireLinuxLock(dataDir,file,owner,onLost,onConnection);
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
