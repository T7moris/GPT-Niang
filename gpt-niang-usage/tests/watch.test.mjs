import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {createRefreshQueue,readRefreshRequest} from '../runtime/refresh-queue.mjs';

function deferred(){let resolve;const promise=new Promise(done=>{resolve=done;});return {promise,resolve};}

test('requests while busy coalesce into one follow-up without concurrent queries',async()=>{
  const gates=[deferred(),deferred()],secondStarted=deferred();
  let calls=0,concurrent=0,peak=0;
  const refresh=createRefreshQueue(async()=>{
    const index=calls++;peak=Math.max(peak,++concurrent);
    if(index===1)secondStarted.resolve();
    await gates[index].promise;concurrent--;
  });
  const done=refresh.request();
  refresh.request();refresh.request();refresh.request();
  assert.equal(calls,1);assert.equal(refresh.busy,true);assert.equal(refresh.pending,true);
  gates[0].resolve();await secondStarted.promise;
  assert.equal(calls,2);assert.equal(refresh.pending,false);
  gates[1].resolve();await done;
  assert.equal(calls,2);assert.equal(peak,1);assert.equal(refresh.busy,false);
});

test('snapshot write failure is bounded and the next request still queries',async()=>{
  let reads=0,writes=0,errors=0,saved=null;
  const refresh=createRefreshQueue(async()=>{
    const result={observedAt:++reads};
    if(++writes===1)throw Object.assign(new Error('temporary file lock'),{code:'EPERM'});
    saved=result;
  },{onError:()=>{errors++;}});
  await refresh.request();
  assert.equal(errors,1);assert.equal(reads,1);assert.equal(refresh.busy,false);
  await refresh.request();
  assert.equal(reads,2);assert.equal(saved.observedAt,2);assert.equal(errors,1);
});

test('request content changes remain detectable with identical file timestamps',()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-niang-refresh-'));
  const flag=path.join(dir,'refresh.flag');
  try{
    const timestamp=new Date('2026-10-01T08:00:00.000Z');
    fs.writeFileSync(flag,'request-one');fs.utimesSync(flag,timestamp,timestamp);
    const first=readRefreshRequest(flag);
    fs.writeFileSync(flag,'request-two');fs.utimesSync(flag,timestamp,timestamp);
    const second=readRefreshRequest(flag);
    assert.notEqual(first,second);assert.equal(second,readRefreshRequest(flag));
    fs.writeFileSync(flag,'');assert.equal(readRefreshRequest(flag),null);
  } finally {if(fs.existsSync(flag))fs.unlinkSync(flag);fs.rmdirSync(dir);}
});
