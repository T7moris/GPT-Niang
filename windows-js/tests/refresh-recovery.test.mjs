import test from 'node:test';
import assert from 'node:assert/strict';
import {EventEmitter} from 'node:events';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import {createPipeRefreshHandler} from '../runtime/worker-ipc.mjs';
import {requestRefresh,readPendingRequests,completeRequests} from '../runtime/refresh-client.mjs';

class Socket extends EventEmitter {
  destroyed=false;
  writableEnded=false;
  setEncoding() {}
  setTimeout() {}
  write() {}
  end(message) {this.message=message;this.writableEnded=true;}
  destroy() {this.destroyed=true;this.emit('close');}
}

test('failed claimed pipe requests disconnect and the next batch still completes',()=>{
  let queries=0;
  const ipc=createPipeRefreshHandler(()=>queries++);
  const submit=id=>{
    const socket=new Socket();ipc.onConnection(socket);
    socket.emit('data',JSON.stringify({id,method:'refresh'})+'\n');
    return socket;
  };
  const failed=submit('01234567-89ab-4cde-8fab-0123456789ab');
  const batch=ipc.takeBatch();
  assert.equal(ipc.pendingCount,0);
  assert.equal(failed.destroyed,false);
  ipc.fail(batch);
  assert.equal(failed.destroyed,true);
  const next=submit('11234567-89ab-4cde-8fab-0123456789ab');
  const snapshot={ok:true,queryOk:true,windows:[],accountKey:'new-account'};
  const recovered=ipc.takeBatch();ipc.complete(recovered,snapshot);
  // An unrelated later filesystem failure must not truncate queued replies.
  ipc.fail(recovered);
  assert.equal(next.destroyed,false);
  assert.deepEqual(JSON.parse(next.message),{requestId:'11234567-89ab-4cde-8fab-0123456789ab',snapshot});
  assert.equal(queries,2);
});

test('a connected silent pipe leaves time for a successful filesystem fallback',{skip:process.platform==='darwin'},async()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'niang-recovery-'));
  const original=net.createConnection;
  const socket=new Socket();
  let starts=0;
  net.createConnection=()=>{queueMicrotask(()=>socket.emit('connect'));return socket;};
  const snapshot={ok:true,queryOk:true,windows:[{minutes:300,remaining:42}],accountKey:'current'};
  try {
    const result=await requestRefresh({dataDir:dir},'unused',{
      timeoutMs:300,pollMs:2,startWorker:()=>{
        starts++;completeRequests(dir,readPendingRequests(dir),snapshot);
      }
    });
    assert.deepEqual(result,snapshot);
    assert.equal(starts,1);
    assert.equal(socket.destroyed,true);
    assert.equal(readPendingRequests(dir).length,0);
    assert.deepEqual(fs.readdirSync(path.join(dir,'refresh-results')),[]);
  } finally {net.createConnection=original;fs.rmSync(dir,{recursive:true,force:true});}
});
