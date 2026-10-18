import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {atomicJson} from '../runtime/usage.mjs';
import {readJson} from '../runtime/worker-state.mjs';
import {createQuoteReplenisher,generationDefaults,normalizeGenerationSettings,quoteKey,unseenQuotes,validateGeneratedQuotes,readQuoteInventory} from '../runtime/quote-generation.mjs';

function setup(t,generate=async()=>({quotes:['新台词来了。']})){
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-niang-quote-test-'));
  const dataDir=path.join(dir,'data'),builtIn=path.join(dir,'base.json');
  let now=new Date(2026,9,18,12).getTime(),calls=0;
  atomicJson(builtIn,{quotes:['原有台词']});
  const options={dataDir,builtIn,platform:'win32',clock:()=>now,generate:args=>{calls++;return generate(args);}};
  const engine=createQuoteReplenisher(options);
  t.after(()=>{engine.close();fs.rmSync(dir,{recursive:true,force:true});});
  return {dir,dataDir,builtIn,engine,options,get calls(){return calls;},advance(ms){now+=ms;},
    enable(patch={}){atomicJson(path.join(dataDir,'quote-generation.json'),{...generationDefaults,enabled:true,revision:'first',...patch});},
    manual(id='manual'){atomicJson(path.join(dataDir,'quote-generation-request.json'),{id,revision:'first',at:now});},
    state(){return readJson(path.join(dataDir,'quote-generation-state.json'));},
    stock(){return readJson(path.join(dataDir,'generated-quotes.json'));}};
}
test('missing/malformed/disabled settings and hidden hosts never start model calls',async t=>{
  const f=setup(t);
  await f.engine.tick({visible:true});assert.equal(f.calls,0);
  f.enable({enabled:false});await f.engine.tick({visible:true});assert.equal(f.calls,0);
  fs.writeFileSync(path.join(f.dataDir,'quote-generation.json'),'broken');await f.engine.tick({visible:true});assert.equal(f.calls,0);
  f.enable();await f.engine.tick({visible:false});assert.equal(f.calls,0);
  const mac=createQuoteReplenisher({...f.options,platform:'darwin'});
  await mac.tick({visible:true});mac.close();assert.equal(f.calls,0);
});
test('manual bypasses all three automatic gates, updates budget/cooldown, and is consumed once',async t=>{
  const f=setup(t);f.enable({threshold:1,maxDaily:1});
  await f.engine.tick({visible:true});assert.equal(f.calls,0);
  f.manual();await f.engine.tick({visible:true});assert.equal(f.calls,1);
  assert.equal(f.state().attempts,1);assert.equal(f.state().totalAttempts,1);assert.equal(f.state().trigger,'manual');
  f.manual('second');await f.engine.tick({visible:true});assert.equal(f.calls,2);
  assert.equal(f.state().attempts,2);assert.equal(f.state().totalAttempts,2);
  await f.engine.tick({visible:true});assert.equal(f.calls,2);
  assert.equal(f.state().lastAttempt,new Date(2026,9,18,12).getTime());
  f.enable({threshold:100,maxDaily:100});await f.engine.tick({visible:true});assert.equal(f.calls,2,'manual calls start the automatic cooldown');
});
test('disabled, stale and old-revision manual requests never queue for a later enable',async t=>{
  const f=setup(t);f.enable({enabled:false});f.manual();await f.engine.tick({visible:true});
  f.enable({threshold:1});await f.engine.tick({visible:true});assert.equal(f.calls,0);
  f.manual('expired');f.advance(60001);await f.engine.tick({visible:true});assert.equal(f.calls,0);
  f.manual('old');f.enable({revision:'new',threshold:1});await f.engine.tick({visible:true});assert.equal(f.calls,0);
});
test('curation during generation preserves deleted/moved archive, suppresses regeneration and allows empty base',async t=>{
  let finish;
  const f=setup(t,()=>new Promise(resolve=>{finish=resolve;}));f.enable();
  atomicJson(path.join(f.dataDir,'generated-quotes.json'),{quotes:['移入常驻','讨厌的台词']});
  const job=f.engine.tick({visible:true});
  atomicJson(path.join(f.dataDir,'quote-library.json'),{base:[{text:'移入常驻',weight:2,preferred:true}],deleted:[{text:'讨厌的台词',source:'generated'}]});
  finish({quotes:['讨厌的台词','移入常驻','新句子']});await job;
  assert.equal(f.stock().quotes.length,3,'archive retained for undo');
  const inventory=readQuoteInventory(f.dataDir,f.builtIn);
  assert.deepEqual(inventory.generated.map(x=>x.text),['新句子']);assert.equal(inventory.base[0].preferred,true);
  atomicJson(path.join(f.dataDir,'quote-library.json'),{base:[],deleted:[]});
  assert.deepEqual(readQuoteInventory(f.dataDir,f.builtIn).base,[]);
});
test('threshold, 43 default, unseen history and custom list remain separate',async t=>{
  let requested;
  const f=setup(t,async args=>{requested=args.settings.batchSize;return {quotes:['新台词来了。','原有台词','新台词来了。']};});
  f.enable({threshold:1});await f.engine.tick({visible:true});assert.equal(f.calls,0);
  atomicJson(path.join(f.dataDir,'quote-history.json'),{shown:{[quoteKey('原有台词')]:true}});
  await f.engine.tick({visible:true});assert.equal(f.calls,1);assert.equal(requested,43);
  assert.deepEqual(f.stock().quotes,[{text:'新台词来了。',weight:1}]);
  assert.equal(fs.existsSync(path.join(f.dataDir,'quotes.json')),false);
  assert.equal(f.state().status,'ready');
});
test('failure/cancellation count, cooldown and daily cap survive worker restart',async t=>{
  const f=setup(t,async()=>{throw new Error('must never log this prompt/secret');});f.enable();
  await f.engine.tick({visible:true});assert.equal(f.calls,1);assert.equal(f.state().attempts,1);
  assert.equal(f.state().error,'GENERATION_FAILED');assert.ok(!JSON.stringify(f.state()).includes('secret'));
  const restarted=createQuoteReplenisher(f.options);t.after(()=>restarted.close());
  await restarted.tick({visible:true});assert.equal(f.calls,1);
  f.advance(30*60000);await restarted.tick({visible:true});assert.equal(f.calls,2);
  f.advance(30*60000);await restarted.tick({visible:true});assert.equal(f.calls,2);
  f.advance(24*60*60000);await restarted.tick({visible:true});assert.equal(f.calls,3);
});
test('custom limits apply and clock rollback cannot bypass them',async t=>{
  const f=setup(t,async()=>{throw new Error('offline');});f.enable({maxDaily:3,minIntervalMinutes:1});
  await f.engine.tick({visible:true});f.advance(60000);await f.engine.tick({visible:true});assert.equal(f.calls,2);
  f.advance(-24*60*60000);await f.engine.tick({visible:true});assert.equal(f.calls,2);
});
test('startup repairs interrupted status without resetting budget or cooldown',async t=>{
  const f=setup(t);f.enable();
  atomicJson(path.join(f.dataDir,'quote-generation-state.json'),{day:'2026-10-18',attempts:2,lastAttempt:new Date(2026,9,18,12).getTime(),status:'generating'});
  const restarted=createQuoteReplenisher(f.options);
  assert.equal(f.state().status,'cancelled');assert.equal(f.state().attempts,2);
  await restarted.tick({visible:true});assert.equal(f.calls,0);restarted.close();
});
test('a reused headless worker can generate for a valid UI and cancels on UI ownership change',async t=>{
  let finish,signal;
  const f=setup(t,args=>{signal=args.signal;return new Promise(resolve=>{finish=resolve;});});f.enable();
  const running=f.engine.tick({visible:true,ownerPid:123});assert.equal(f.calls,1);
  f.engine.tick({visible:true,ownerPid:456});assert.equal(signal.aborted,true);
  finish({quotes:['旧窗口结果']});await running;assert.equal(f.stock(),null);
});
test('disabling cancels active batch, rejects late output, remains off across restart',async t=>{
  let finish,signal;
  const f=setup(t,args=>{signal=args.signal;return new Promise(resolve=>{finish=resolve;});});f.enable();
  const running=f.engine.tick({visible:true});f.engine.tick({visible:false});assert.equal(signal.aborted,true);
  f.enable({enabled:false,revision:'disabled'});finish({quotes:['迟到的台词']});await running;
  assert.equal(f.stock(),null);assert.equal(f.state().status,'cancelled');assert.equal(f.state().attempts,1);
  const restarted=createQuoteReplenisher(f.options);await restarted.tick({visible:true});restarted.close();assert.equal(f.calls,1);
});
test('rapid off/on revision change and worker close invalidate in-flight batches',async t=>{
  let finish;
  const f=setup(t,()=>new Promise(resolve=>{finish=resolve;}));f.enable();
  const running=f.engine.tick({visible:true});f.enable({revision:'reenabled'});
  finish({quotes:['旧任务的结果']});await running;assert.equal(f.stock(),null);
  f.advance(30*60000);const second=f.engine.tick({visible:true});f.engine.close();finish({quotes:['退出后的结果']});await second;assert.equal(f.stock(),null);
});
test('the active poll observes disabled settings without a UI or scheduler tick',async t=>{
  const f=setup(t,({signal})=>new Promise((resolve,reject)=>signal.addEventListener('abort',()=>reject(new Error('abort')),{once:true})));
  f.enable();const running=f.engine.tick({visible:true});f.enable({enabled:false,revision:'off'});
  await running;assert.equal(f.state().status,'cancelled');assert.equal(f.stock(),null);
});
test('corrupt budget fails closed and invalid generated content never enters stock',async t=>{
  const f=setup(t);f.enable();fs.writeFileSync(path.join(f.dataDir,'quote-generation-state.json'),'broken');
  await f.engine.tick({visible:true});assert.equal(f.calls,0);
  const accepted=validateGeneratedQuotes({quotes:[null,123,{text:42},'旧句','新句','新句','a\nb','https://example.com','1. 编号','长'.repeat(41)]},[{text:'旧句'}],43);
  assert.deepEqual(accepted,[{text:'新句',weight:1}]);
  assert.equal(quoteKey('ＧＰＴ 娘'),quoteKey('GPT娘'));
  assert.deepEqual(unseenQuotes({base:[{text:'旧句',weight:1}],generated:[{text:'新句',weight:1}],shown:{[quoteKey('旧句')]:true}}).map(x=>x.text),['新句']);
  const config=normalizeGenerationSettings({enabled:'true',batchSize:-1,maxDaily:Infinity,model:'--bad model'});
  assert.equal(config.enabled,false);assert.equal(config.batchSize,43);assert.equal(config.maxDaily,2);assert.equal(config.model,'');
});
