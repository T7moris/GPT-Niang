import test from 'node:test';
import assert from 'node:assert/strict';
import {EventEmitter} from 'node:events';
import {PassThrough} from 'node:stream';
import {identifyPlan,quotaWindowLabel} from '../runtime/plan.mjs';
import {normalizeLimits,readUsage,accountFingerprint} from '../runtime/usage.mjs';
import {mergeUsageSnapshot} from '../runtime/refresh-queue.mjs';

const window=(minutes,used=20)=>({windowDurationMins:minutes,usedPercent:used,resetsAt:null});
function fakeServer(account,limits,error=false) {
  const methods=[];
  const spawnProcess=()=>{
    const proc=new EventEmitter();
    proc.stdin=new PassThrough();proc.stdout=new PassThrough();proc.stderr=new PassThrough();proc.kill=()=>{};
    proc.stdin.on('data',chunk=>{
      for(const line of chunk.toString().trim().split('\n')) {
        const request=JSON.parse(line);methods.push(request.method);
        if(request.id===undefined)continue;
        const response=request.id===1?{result:{}}:request.id===2?{result:{account}}:error?{error:{code:-32603}}:{result:limits};
        queueMicrotask(()=>proc.stdout.write(JSON.stringify({id:request.id,...response})+'\n'));
      }
    });return proc;
  };
  return {spawnProcess,methods};
}

test('all documented plans including Pro use actual windows without a plan-to-duration table',()=>{
  for(const plan of ['free','go','plus','pro','team','business','enterprise','edu','future-plan']) {
    for(const duration of [15,60,300,1440,10080,43200,31*1440,75]) {
      const result=normalizeLimits({rateLimitsByLimitId:{codex:{planType:plan,primary:window(duration)}}});
      assert.equal(result.ok,true,plan+'/'+duration);assert.equal(result.queryOk,true);
      assert.equal(result.plan,plan);assert.equal(result.windows[0].minutes,duration);
      assert.equal(result.windows[0].remaining,80);
    }
  }
});
test('Go 30-day and Pro exhausted windows retain labels, percentages and null resets',()=>{
  const go=normalizeLimits({rateLimits:{planType:'go',primary:window(43200,0),secondary:null}});
  assert.deepEqual(go.windows,[{label:'30 天',minutes:43200,used:0,remaining:100,resetsAt:null}]);
  const pro=normalizeLimits({rateLimits:{planType:'pro',primary:window(300,100),secondary:window(10080,5)}});
  assert.equal(pro.planLabel,'Pro');assert.deepEqual(pro.windows.map(w=>w.remaining),[0,95]);
  assert.equal(quotaWindowLabel(75),'75 分钟');assert.equal(quotaWindowLabel(60),'1 小时');
  assert.equal(quotaWindowLabel(1440),'1 天');assert.equal(quotaWindowLabel(10080),'每周');
});
test('known, unknown, absent and stale account plan metadata are distinguished',()=>{
  assert.deepEqual(identifyPlan('plus','pro','chatgpt'),{plan:'pro',planLabel:'Pro',planKnown:true,planSource:'rateLimits',authType:'chatgpt'});
  assert.equal(identifyPlan(' GO ',null).planLabel,'Go');
  assert.equal(identifyPlan('future-plan',null).planKnown,false);
  assert.equal(identifyPlan(null,null).plan,null);
  assert.equal(identifyPlan('pro\nTOKEN',null).plan,null);
});
test('a plan change in the quota response keeps the account snapshot stable',async()=>{
  const account={type:'chatgpt',email:'example@example.test',planType:'plus',accessToken:'private'};
  const server=fakeServer(account,{rateLimits:{planType:'pro',primary:window(300,7)}}),seen=[];
  const result=await readUsage('fake',{spawnProcess:server.spawnProcess,onAccount:key=>seen.push(key)});
  assert.equal(result.plan,'pro');assert.equal(result.planSource,'rateLimits');
  // The plan label is metadata, not account identity: one account must keep one
  // snapshot key so a failed refresh can preserve the previous windows.
  assert.deepEqual(seen,[accountFingerprint(account)]);
  assert.equal(result.accountKey,accountFingerprint(account));
  assert.deepEqual(server.methods,['initialize','initialized','account/read','account/rateLimits/read']);
  assert.equal(JSON.stringify(result).includes(account.email),false);
  assert.equal(JSON.stringify(result).includes(account.accessToken),false);
  const previous={...result,accountKey:seen[0],windows:[{remaining:99}]};
  const failed={ok:false,queryOk:false,windows:[],accountKey:seen[0],clearPrevious:false};
  assert.deepEqual(mergeUsageSnapshot(previous,failed).windows,[{remaining:99}]);
});
test('account plan remains identifiable when limits omit it or the quota request fails',async()=>{
  const account={type:'chatgpt',email:'pro@example.test',planType:'pro'};
  const fallback=await readUsage('fake',{spawnProcess:fakeServer(account,{rateLimits:{primary:window(60)}}).spawnProcess});
  assert.equal(fallback.plan,'pro');assert.equal(fallback.planSource,'account');assert.equal(fallback.ok,true);
  const failed=await readUsage('fake',{spawnProcess:fakeServer(account,null,true).spawnProcess});
  assert.equal(failed.plan,'pro');assert.equal(failed.queryOk,false);assert.equal(failed.errorCode,'RATE_LIMITS_READ_FAILED');
});
test('no windows, malformed windows and unsupported authentication do not masquerade as a plan failure',async()=>{
  const absent=normalizeLimits({rateLimits:{planType:'go',primary:null,secondary:null}});
  assert.equal(absent.queryOk,true);assert.equal(absent.errorCode,'NO_WINDOWS');
  const invalid=normalizeLimits({rateLimits:{primary:window(-1)}});
  assert.equal(invalid.queryOk,false);assert.equal(invalid.errorCode,'INVALID_WINDOWS');
  const server=fakeServer({type:'apiKey'},null);
  const api=await readUsage('fake',{spawnProcess:server.spawnProcess});
  assert.equal(api.errorCode,'AUTH_MODE_UNSUPPORTED');assert.equal(api.authType,'apiKey');
  assert.equal(server.methods.includes('account/rateLimits/read'),false);
});

// PR #9 regression cases, resolved using the existing exact-duration labels.
test('transport slots and calendar-like durations do not determine plan window meaning',()=>{
  const swapped=normalizeLimits({rateLimits:{planType:'pro',primary:window(10080,10),secondary:window(300,20)}});
  assert.deepEqual(swapped.windows.map(w=>[w.label,w.minutes,w.remaining]),[['5 小时',300,80],['每周',10080,90]]);
  const monthly=normalizeLimits({rateLimits:{planType:'team',primary:window(10080,5),secondary:window(43800,7)}});
  assert.equal(monthly.queryOk,true);
  assert.deepEqual(monthly.windows.map(w=>[w.label,w.minutes,w.remaining]),[['每周',10080,95],['730 小时',43800,93]]);
  for(const [minutes,label] of [[40320,'28 天'],[43200,'30 天'],[44640,'31 天'],[21600,'15 天'],[90,'90 分钟']]) {
    const actual=normalizeLimits({rateLimits:{primary:window(minutes)}});
    assert.equal(actual.queryOk,true);assert.equal(actual.windows[0].label,label);
  }
});
