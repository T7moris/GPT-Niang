import test from 'node:test';
import assert from 'node:assert/strict';
import {EventEmitter} from 'node:events';
import {PassThrough} from 'node:stream';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {normalizeLimits,freshness,readUsage,accountFingerprint} from '../runtime/usage.mjs';
import {mergeUsageSnapshot} from '../runtime/refresh-queue.mjs';
const w=(used=10,mins=300)=>({usedPercent:used,windowDurationMins:mins,resetsAt:2000000000});
const individual=(overrides={})=>({limit:'4000',used:'2082.8820300102234',remainingPercent:48,resetsAt:2000000000,...overrides});
test('Business personal cap works without primary or secondary windows',()=>{
  const r=normalizeLimits({rateLimitsByLimitId:{codex:{planType:'business',primary:null,secondary:null,individualLimit:individual()}}},1000);
  assert.equal(r.ok,true);assert.equal(r.queryOk,true);assert.equal(r.plan,'business');
  assert.equal(r.windows.length,1);
  const q=r.windows[0];
  assert.equal(q.kind,'individual');assert.equal(q.label,'个人额度');assert.equal(q.minutes,null);
  assert.equal(q.remaining,48);assert.equal(q.used,52);assert.equal(q.total,4000);
  assert.equal(q.amountUsed,2082.8820300102234);assert.equal(q.amountRemaining,4000-q.amountUsed);
  assert.equal(q.resetsAt,2000000000);
});
test('personal cap coexists with timed windows without discarding either',()=>{
  const r=normalizeLimits({rateLimits:{individualLimit:individual(),primary:w(10),secondary:w(80,10080)}});
  assert.equal(r.windows.length,3);assert.equal(r.queryOk,true);
  assert.deepEqual(r.windows.map(q=>q.remaining),[48,90,20]);
});
test('personal cap preserves exhausted, zero, full and decimal percentages',()=>{
  for(const remainingPercent of [0,0.1,48,100]){
    const q=normalizeLimits({rateLimits:{individualLimit:individual({remainingPercent})}}).windows[0];
    assert.equal(q.remaining,remainingPercent);assert.equal(q.used,100-remainingPercent);
  }
  const zero=normalizeLimits({rateLimits:{individualLimit:individual({limit:'0',used:'0',remainingPercent:0})}}).windows[0];
  assert.equal(zero.remaining,0);assert.equal(zero.amountRemaining,0);
});
test('derive a missing personal percentage only from valid amounts',()=>{
  for(const remainingPercent of [null,undefined]){
    const q=normalizeLimits({rateLimits:{individualLimit:individual({limit:'4000',used:'1000',remainingPercent})}}).windows[0];
    assert.equal(q.remaining,75);
  }
  const q=normalizeLimits({rateLimits:{individualLimit:individual({used:4500,remainingPercent:null})}}).windows[0];
  assert.equal(q.remaining,0);assert.equal(q.amountRemaining,0);
  for(const limit of [null,'', ' ',false,[],{},'NaN','Infinity',-1,'-1',0]){
    const r=normalizeLimits({rateLimits:{individualLimit:individual({limit,remainingPercent:null})}});
    assert.equal(r.ok,false);assert.equal(r.queryOk,false);
  }
});
test('malformed personal percentages are not replaced by guessed healthy values',()=>{
  for(const raw of [false,[],{},individual({remainingPercent:-1}),individual({remainingPercent:101}),individual({remainingPercent:'48'}),individual({remainingPercent:NaN})]){
    const r=normalizeLimits({rateLimits:{individualLimit:raw}});
    assert.equal(r.ok,false);assert.equal(r.queryOk,false);assert.equal(r.errorCode,'INVALID_WINDOWS');
  }
  assert.equal(normalizeLimits({rateLimits:{individualLimit:null}}).errorCode,'NO_WINDOWS');
});
test('personal reset and unknown amount fields remain unavailable, never invented',()=>{
  const r=normalizeLimits({rateLimits:{individualLimit:individual({limit:null,used:null,resetsAt:null})}},1000);
  assert.equal(r.ok,true);assert.equal(r.windows[0].total,null);assert.equal(r.windows[0].amountRemaining,null);
  assert.equal(r.windows[0].resetsAt,null);assert.equal(freshness(r.windows[0],1000,2000),'fresh');
  const expired=normalizeLimits({rateLimits:{individualLimit:individual({resetsAt:1})}},1000);
  assert.equal(freshness(expired.windows[0],1000,2000),'expired');
});
test('personal cap survives the read-only RPC and account snapshot pipeline',async()=>{
  const calls=[];
  const spawnProcess=()=>{
    const proc=new EventEmitter();
    proc.stdin=new PassThrough();proc.stdout=new PassThrough();proc.stderr=new PassThrough();proc.kill=()=>{};
    proc.stdin.on('data',chunk=>{
      for(const line of chunk.toString().trim().split('\n')){
        const request=JSON.parse(line);calls.push(request.method);
        if(request.id===undefined)continue;
        const result=request.id===1?{}:request.id===2?{account:{type:'chatgpt',email:'test@example.test',planType:'business'}}:{rateLimits:{planType:'business',individualLimit:individual()}};
        queueMicrotask(()=>proc.stdout.write(JSON.stringify({id:request.id,result})+'\n'));
      }
    });return proc;
  };
  const r=await readUsage('fake',{spawnProcess});
  assert.equal(r.ok,true);assert.equal(r.clearPrevious,false);assert.equal(r.windows[0].remaining,48);
  assert.deepEqual(calls,['initialize','initialized','account/read','account/rateLimits/read']);
  const personal={...normalizeLimits({rateLimits:{primary:w(1)}}),accountKey:'personal'};
  const switched=mergeUsageSnapshot(personal,r);
  assert.equal(switched.windows.length,1);assert.equal(switched.windows[0].kind,'individual');
  const unavailable={ok:false,queryOk:true,clearPrevious:true,windows:[],accountKey:r.accountKey};
  assert.deepEqual(mergeUsageSnapshot(switched,unavailable).windows,[]);
});
test('prefer current codex bucket over legacy and unrelated model buckets',()=>{
  const r=normalizeLimits({rateLimits:{primary:w(90)},rateLimitsByLimitId:{codex:{primary:w(12),secondary:w(61,10080)},other:{primary:w(98)}}},1000);
  assert.deepEqual(r.windows.map(x=>[x.minutes,x.used,x.remaining]),[[300,12,88],[10080,61,39]]);
});
test('missing current bucket does not borrow a different account or meter',()=>{
  assert.equal(normalizeLimits({rateLimits:{primary:w()},rateLimitsByLimitId:{other:{primary:w()}}}).ok,false);
});
test('missing and invalid fields stay unavailable, valid zero and full usage survive',()=>{
  for(const x of [null,{}, {usedPercent:null,windowDurationMins:300,resetsAt:2000000000},w(-1),w(101),w(NaN),w(5,0),w(5,1.5),w(5,Number.MAX_SAFE_INTEGER+1)])assert.equal(normalizeLimits({rateLimits:{primary:x}}).ok,false);
  assert.equal(normalizeLimits({rateLimits:{primary:w(0)}}).windows[0].remaining,100);
  assert.equal(normalizeLimits({rateLimits:{primary:w(100)}}).windows[0].remaining,0);
});
test('an exhausted window still reports zero remaining and keeps the other window',()=>{
  for(const [short,week] of [[100,34],[20,100],[100,100]]){
    const result=normalizeLimits({rateLimits:{primary:w(short),secondary:w(week,10080)}});
    assert.equal(result.ok,true);assert.equal(result.queryOk,true);
    assert.deepEqual(result.windows.map(window=>window.remaining),[100-short,100-week]);
  }
});
test('passed reset stays expired instead of invented replenishment',()=>{
  assert.equal(freshness({resetsAt:2},1000,3000),'expired');
  assert.equal(freshness({resetsAt:1000},1000,200000),'stale');
  assert.equal(freshness({resetsAt:1000},1000,2000),'fresh');
});
test('missing Codex executable returns a bounded actionable failure',async()=>{
  const r=await readUsage('Z:/not-a-codex-executable.exe',{timeoutMs:2000});
  assert.equal(r.ok,false);assert.deepEqual(r.windows,[]);
});
test('account read protocol error clears a snapshot whose account cannot be verified',async()=>{
  const calls=[];
  const spawnProcess=()=>{
    const proc=new EventEmitter();
    proc.stdin=new PassThrough();proc.stdout=new PassThrough();proc.stderr=new PassThrough();
    proc.kill=()=>{};
    let pending='';
    proc.stdin.on('data',chunk=>{
      pending+=chunk.toString();
      let at;
      while((at=pending.indexOf('\n'))>=0){
        const request=JSON.parse(pending.slice(0,at));pending=pending.slice(at+1);
        calls.push(request.method);
        if(request.method==='initialize')queueMicrotask(()=>proc.stdout.write(JSON.stringify({id:request.id,result:{}})+'\n'));
        else if(request.method==='account/read')queueMicrotask(()=>proc.stdout.write(JSON.stringify({id:request.id,error:{code:-32603,message:'temporary account service error'}})+'\n'));
      }
    });
    return proc;
  };
  const response=await readUsage('fake-codex',{timeoutMs:2000,spawnProcess});
  assert.equal(response.ok,false);assert.equal(response.clearPrevious,true);
  assert.deepEqual(calls,['initialize','initialized','account/read']);
  const previous=normalizeLimits({rateLimits:{primary:w(12)}},1000);
  const snapshot=mergeUsageSnapshot(previous,response,2000);
  assert.equal(snapshot.ok,false);assert.deepEqual(snapshot.windows,[]);assert.equal(snapshot.checkedAt,2000);
  assert.equal(snapshot.error,'暂时无法读取登录状态');
});

function routingTimeoutServer(quotaResponse) {
  const calls=[];
  const spawnProcess=()=>{
    const proc=new EventEmitter();
    proc.stdin=new PassThrough();proc.stdout=new PassThrough();proc.stderr=new PassThrough();proc.kill=()=>{};
    let pending='';
    proc.stdin.on('data',chunk=>{
      pending+=chunk.toString();let at;
      while((at=pending.indexOf('\n'))>=0){
        const request=JSON.parse(pending.slice(0,at));pending=pending.slice(at+1);calls.push(request.method);
        if(request.method==='initialize')queueMicrotask(()=>proc.stdout.write(JSON.stringify({id:request.id,result:{}})+'\n'));
        else if(request.method==='account/read')queueMicrotask(()=>proc.stdout.write(JSON.stringify({id:request.id,error:{code:-32603,message:'workspace routing discovery timed out'}})+'\n'));
        else if(request.method==='account/rateLimits/read' && quotaResponse!==undefined)queueMicrotask(()=>proc.stdout.write(JSON.stringify({id:request.id,...quotaResponse})+'\n'));
      }
    });return proc;
  };
  return {calls,spawnProcess};
}

test('routing timeout can return a fresh direct quota without reusing an unverified account snapshot',async()=>{
  const identity='workspace-test-identity';
  const server=routingTimeoutServer({result:{accountId:identity,rateLimits:{planType:'plus',primary:w(12)}}});
  const seen=[];
  const result=await readUsage('fake-codex',{spawnProcess:server.spawnProcess,timeoutMs:1000,fallbackTimeoutMs:1000,onAccount:key=>seen.push(key)});
  assert.deepEqual(server.calls,['initialize','initialized','account/read','account/rateLimits/read']);
  assert.deepEqual(seen,[null]);
  assert.equal(result.queryOk,true);assert.equal(result.ok,true);assert.equal(result.windows[0].remaining,88);
  assert.equal(result.plan,'plus');assert.equal(result.authType,null);assert.equal(result.accountKey,null);assert.equal(result.clearPrevious,true);assert.equal(result.accountVerified,false);
  assert.equal(JSON.stringify(result).includes(identity),false);
  const previous={...normalizeLimits({rateLimits:{primary:w(90)}},1000),accountKey:'previous-account'};
  const snapshot=mergeUsageSnapshot(previous,result,2000);
  assert.equal(snapshot.windows[0].remaining,88);assert.equal(snapshot.accountKey,null);
  const nextFailure=mergeUsageSnapshot(snapshot,{ok:false,queryOk:false,accountKey:null,clearPrevious:true,windows:[]},3000);
  assert.deepEqual(nextFailure.windows,[]);
});

test('routing timeout fallback rejects a quota response without an account identifier',async()=>{
  for(const accountId of [undefined,null,'',42]){
    const server=routingTimeoutServer({result:{accountId,rateLimits:{planType:'plus',primary:w()}}});
    const result=await readUsage('fake-codex',{spawnProcess:server.spawnProcess,timeoutMs:1000,fallbackTimeoutMs:1000});
    assert.equal(result.ok,false);assert.equal(result.clearPrevious,true);assert.deepEqual(result.windows,[]);
  }
});

test('routing timeout fallback reports quota failures and remains bounded',async()=>{
  const failed=routingTimeoutServer({error:{code:-32603,message:'quota unavailable'}});
  const result=await readUsage('fake-codex',{spawnProcess:failed.spawnProcess,timeoutMs:1000,fallbackTimeoutMs:1000});
  assert.equal(result.ok,false);assert.equal(result.clearPrevious,true);assert.deepEqual(result.windows,[]);
  const hanging=routingTimeoutServer(undefined);
  const timed=await readUsage('fake-codex',{spawnProcess:hanging.spawnProcess,timeoutMs:1000,fallbackTimeoutMs:25});
  assert.equal(timed.ok,false);assert.equal(timed.clearPrevious,true);assert.match(timed.error,/超时/);
});

test('a missing reset keeps the valid percentage and does not invent expiry',()=>{
  for(const resetsAt of [null,undefined,NaN,0,-1,'2000000000',1e100,253402300799]) {
    const result=normalizeLimits({rateLimits:{primary:{...w(12),resetsAt}}},1000);
    assert.equal(result.ok,true);assert.equal(result.queryOk,true);
    assert.equal(result.windows[0].remaining,88);assert.equal(result.windows[0].resetsAt,null);
    assert.equal(freshness(result.windows[0],1000,2000),'fresh');
  }
});

test('only successful well-formed absence is distinguished from failed quota reads',()=>{
  assert.equal(normalizeLimits({rateLimits:{secondary:w(30,10080)}}).queryOk,true);
  assert.equal(normalizeLimits({rateLimits:{primary:null,secondary:null}}).queryOk,true);
  for(const response of [null,{}, {rateLimits:null},{rateLimits:[]},{rateLimitsByLimitId:{other:{primary:w()}}},{rateLimits:{primary:w(NaN),secondary:w(20,10080)}}])assert.equal(normalizeLimits(response).queryOk,false);
  const duplicate=normalizeLimits({rateLimits:{primary:w(10),secondary:w(20)}});
  assert.equal(duplicate.queryOk,false);assert.equal(duplicate.windows.length,1);
});

test('public account identity is fingerprinted without persisting email or credentials',()=>{
  const account={type:'chatgpt',email:'a@example.test',planType:'plus',accessToken:'not-stored'};
  const key=accountFingerprint(account);
  assert.match(key,/^[a-f0-9]{64}$/);
  assert.equal(key,accountFingerprint({...account,accessToken:'different'}));
  assert.notEqual(key,accountFingerprint({...account,email:'b@example.test'}));
  assert.equal(accountFingerprint({type:'chatgpt',email:null,planType:'plus'}),null);
});

test('quota failures reuse only a verified same-account snapshot',()=>{
  const previous={...normalizeLimits({rateLimits:{primary:w(12)}},1000),accountKey:'account-a'};
  const failed={ok:false,queryOk:false,error:'temporary failure',windows:[],accountKey:'account-a'};
  const same=mergeUsageSnapshot(previous,failed,2000);
  assert.equal(same.ok,true);assert.equal(same.queryOk,false);assert.equal(same.observedAt,1000);
  assert.equal(same.windows[0].remaining,88);
  for(const accountKey of ['account-b',null,undefined]) {
    const different=mergeUsageSnapshot(previous,{...failed,accountKey},2000);
    assert.equal(different.ok,false);assert.deepEqual(different.windows,[]);
  }
  const older={...previous,observedAt:500,windows:[{remaining:99}]};
  assert.equal(mergeUsageSnapshot(previous,older,2000),previous);
});

test('account identity is attached even when the quota read fails',async()=>{
  const account={type:'chatgpt',email:'b@example.test',planType:'plus'};
  const seen=[];
  const spawnProcess=()=>{
    const proc=new EventEmitter();
    proc.stdin=new PassThrough();proc.stdout=new PassThrough();proc.stderr=new PassThrough();proc.kill=()=>{};
    proc.stdin.on('data',chunk=>{
      for(const line of chunk.toString().trim().split('\n')) {
        const request=JSON.parse(line);
        if(request.id===undefined)continue;
        const response=request.id===1?{result:{}}:request.id===2?{result:{account}}:{error:{code:-32603}};
        queueMicrotask(()=>proc.stdout.write(JSON.stringify({id:request.id,...response})+'\n'));
      }
    });return proc;
  };
  const result=await readUsage('fake-codex',{spawnProcess,onAccount:key=>seen.push(key)});
  assert.equal(result.ok,false);assert.equal(result.queryOk,false);assert.equal(result.clearPrevious,false);
  assert.equal(result.accountKey,accountFingerprint(account));assert.deepEqual(seen,[result.accountKey]);
  assert.equal(JSON.stringify(result).includes(account.email),false);
});

test('non-object JSON protocol messages are ignored without crashing the worker',async()=>{
  const spawnProcess=()=>{
    const proc=new EventEmitter();
    proc.stdin=new PassThrough();proc.stdout=new PassThrough();proc.stderr=new PassThrough();proc.kill=()=>{};
    proc.stdin.on('data',()=>queueMicrotask(()=>proc.stdout.write('null\nfalse\n42\n[]\n')));
    return proc;
  };
  const result=await readUsage('fake-codex',{spawnProcess,timeoutMs:25});
  assert.equal(result.ok,false);assert.equal(result.clearPrevious,true);assert.match(result.error,/超时/);
});

test('out-of-order quota responses cannot bypass account verification',async()=>{
  const account={type:'chatgpt',email:'verified@example.test',planType:'plus'};
  const spawnProcess=()=>{
    const proc=new EventEmitter();
    proc.stdin=new PassThrough();proc.stdout=new PassThrough();proc.stderr=new PassThrough();proc.kill=()=>{};
    proc.stdin.on('data',chunk=>{
      for(const line of chunk.toString().trim().split('\n')) {
        const request=JSON.parse(line);
        if(request.id===undefined)continue;
        queueMicrotask(()=>{
          if(request.id===1)proc.stdout.write(JSON.stringify({id:3,result:{rateLimits:{primary:w(99)}}})+'\n');
          const result=request.id===1?{}:request.id===2?{account}:{rateLimits:{primary:w(12)}};
          proc.stdout.write(JSON.stringify({id:request.id,result})+'\n');
        });
      }
    });return proc;
  };
  const result=await readUsage('fake-codex',{spawnProcess});
  assert.equal(result.ok,true);assert.equal(result.accountKey,accountFingerprint(account));
  assert.equal(result.windows[0].remaining,88);
});

test('MCP rejects malformed input without crashing and still serves read-only protocol metadata',async()=>{
  const proc=spawn(process.execPath,[fileURLToPath(new URL('../runtime/mcp.mjs',import.meta.url))],{windowsHide:true,stdio:['pipe','pipe','pipe']});
  let output='',errors='';
  proc.stdout.on('data',chunk=>{output+=chunk;});proc.stderr.on('data',chunk=>{errors+=chunk;});
  const closed=new Promise((resolve,reject)=>{proc.on('error',reject);proc.on('close',code=>resolve(code));});
  proc.stdin.end(['{bad-json','null','[]','false','{"id":7}',JSON.stringify({jsonrpc:'2.0',id:1,method:'initialize'}),JSON.stringify({jsonrpc:'2.0',id:2,method:'ping'}),JSON.stringify({jsonrpc:'2.0',id:3,method:'tools/list'})].join('\n')+'\n');
  assert.equal(await closed,0,errors);
  const responses=output.trim().split('\n').map(line=>JSON.parse(line));
  assert.equal(responses.filter(response=>response.error?.code===-32700).length,1);
  assert.equal(responses.filter(response=>response.error?.code===-32600).length,4);
  assert.equal(responses.find(response=>response.id===1).result.serverInfo.name,'gpt-niang-usage');
  assert.deepEqual(responses.find(response=>response.id===2).result,{});
  assert.equal(responses.find(response=>response.id===3).result.tools[0].name,'get_codex_usage');
});
