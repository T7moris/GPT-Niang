import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {fileURLToPath} from 'node:url';
import {acquireWorkerLock,workerEndpoint} from '../../gpt-niang-usage/runtime/worker-state.mjs';

test('a crashed socket owner admits exactly one concurrent recovery',{skip:process.platform!=='linux'},async()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'niang-socket-crash-'));
  const module=fileURLToPath(new URL('../../gpt-niang-usage/runtime/worker-state.mjs',import.meta.url));
  const child=spawn(process.execPath,['--input-type=module','-e',`import {acquireWorkerLock} from ${JSON.stringify('file://'+module)}; await acquireWorkerLock(process.argv[1]); console.log('ready'); setInterval(()=>{},1000);`,dir],{stdio:['ignore','pipe','inherit']});
  const locks=[];
  try{
    await once(child.stdout,'data');
    const exited=once(child,'exit');child.kill('SIGKILL');await exited;
    // The holder observes pipe EOF asynchronously; give the first restart the
    // same bounded retry that the runtime uses.
    const deadline=Date.now()+3000;
    while(!locks.some(Boolean) && Date.now()<deadline){
      const batch=await Promise.all(Array.from({length:6},()=>acquireWorkerLock(dir)));
      locks.push(...batch);if(!batch.some(Boolean))await new Promise(r=>setTimeout(r,20));
    }
    assert.equal(locks.filter(Boolean).length,1);
    assert.equal(fs.statSync(workerEndpoint(dir)).mode & 0o777,0o600);
  }finally{
    if(child.exitCode===null && child.signalCode===null)child.kill('SIGKILL');
    for(const lock of locks)if(lock)await lock.release();
    fs.rmSync(dir,{recursive:true,force:true});
  }
});

test('a long UTF-8 state path uses a private short socket endpoint',{skip:process.platform!=='linux'},async()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'niang-长路径-'));
  const state=path.join(dir,'桌面宠物'.repeat(15));let lock;
  try{
    lock=await acquireWorkerLock(state);assert.ok(lock);
    const endpoint=workerEndpoint(state);
    assert.ok(Buffer.byteLength(endpoint)<108);
    assert.equal(fs.statSync(path.dirname(endpoint)).mode & 0o777,0o700);
  }finally{if(lock)await lock.release();fs.rmSync(dir,{recursive:true,force:true});fs.rmSync(path.dirname(workerEndpoint(state)),{recursive:true,force:true});}
});
