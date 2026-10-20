import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import {acquireWorkerLock,workerEndpoint} from '../runtime/worker-state.mjs';
import {createPipeRefreshHandler,requestPipeRefresh} from '../runtime/worker-ipc.mjs';
import {requestRefresh} from '../runtime/refresh-client.mjs';

test('pipe clients receive a fresh correlated snapshot without request-file writes',{skip:process.platform==='darwin'},async()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'niang-ipc-'));
  let lock;let timer;
  const snapshot={ok:true,queryOk:true,windows:[{minutes:300,remaining:67}],observedAt:Date.now(),accountKey:'current-account'};
  const ipc=createPipeRefreshHandler(()=>{
    if(!timer)timer=setTimeout(()=>{const batch=ipc.takeBatch();ipc.complete(batch,snapshot);timer=null;},20);
  });
  try{
    lock=await acquireWorkerLock(dir,0,{onConnection:ipc.onConnection});
    const options={timeoutMs:1000,startWorker:()=>{throw new Error('Must reuse existing writer');}};
    const results=await Promise.all([requestRefresh({dataDir:dir},'unused',options),requestRefresh({dataDir:dir},'unused',options)]);
    assert.deepEqual(results,[snapshot,snapshot]);
    assert.equal(fs.existsSync(path.join(dir,'refresh-requests')),false);
    assert.equal(ipc.pendingCount,0);
  }finally{clearTimeout(timer);if(lock)await lock.release();fs.rmSync(dir,{recursive:true,force:true});}
});
test('unavailable or unresponsive pipe returns within its deadline',{skip:process.platform==='darwin'},async()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'niang-ipc-timeout-'));let lock;
  try{
    assert.equal(await requestPipeRefresh(dir,{timeoutMs:40}),null);
    lock=await acquireWorkerLock(dir,0,{onConnection:socket=>{socket.on('error',()=>{});socket.resume();}});
    assert.equal(await requestPipeRefresh(dir,{timeoutMs:40}),null);
  }finally{if(lock)await lock.release();fs.rmSync(dir,{recursive:true,force:true});}
});

test('pipe rejects unsupported methods and oversized messages without querying',{skip:process.platform==='darwin'},async()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'niang-ipc-invalid-'));let lock,queries=0;
  const ipc=createPipeRefreshHandler(()=>queries++);
  try{
    lock=await acquireWorkerLock(dir,0,{onConnection:ipc.onConnection});
    for(const message of [JSON.stringify({id:'01234567-89ab-4cde-8fab-0123456789ab',method:'execute'}), 'x'.repeat(4097)]){
      await new Promise((resolve,reject)=>{
        const socket=net.createConnection(workerEndpoint(dir));
        const timer=setTimeout(()=>{socket.destroy();reject(new Error('Invalid request was not disconnected'));},1000);
        socket.on('error',()=>{});socket.on('close',()=>{clearTimeout(timer);resolve();});
        socket.on('connect',()=>socket.write(message+'\n'));
      });
    }
    assert.equal(queries,0);assert.equal(ipc.pendingCount,0);
  }finally{if(lock)await lock.release();fs.rmSync(dir,{recursive:true,force:true});}
});
