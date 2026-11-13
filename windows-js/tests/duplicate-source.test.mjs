import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {UsageLedger} from '../src/core/usage-ledger.mjs';
const count=(input,stamp)=>({type:'event_msg',timestamp:stamp,payload:{type:'token_count',info:{total_token_usage:{input_tokens:input,cached_input_tokens:0,output_tokens:input/10},last_token_usage:{input_tokens:input,cached_input_tokens:0,output_tokens:input/10}}}});
test('same session ID in multiple files completes scans, deduplicates history, survives archive moves and old cursor keys',()=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-niang-duplicate-'));
 const home=path.join(root,'home'),dataDir=path.join(root,'state');
 fs.mkdirSync(path.join(home,'sessions'),{recursive:true});
 const header={type:'session_meta',payload:{id:'shared-session',model_provider:'fixture'}};
 const context={type:'turn_context',payload:{model:'fixture',turn_id:'shared-turn'}};
 const prefix=[header,context,count(1000,'2026-11-05T05:00:00Z')];
 const files=['a','b'].map(n=>path.join(home,'sessions',n+'.jsonl'));
 files.forEach((file,i)=>fs.writeFileSync(file,[...prefix,{type:'event_msg',payload:{type:'user_message',message:'x'.repeat(1200000)}},count(2000+i*1000,'2026-11-05T05:0'+(i+1)+':00Z')].map(x=>JSON.stringify(x)).join('\n')+'\n'));
 let ledger;
 try{
  ledger=new UsageLedger({dataDir,codexHome:home});
  for(let n=0;n<14;n++)ledger.scan({now:Date.now()+n*1500});
  let rows=ledger.db.prepare('select path,offset from files').all();
  assert.equal(rows.length,2,'each physical log must have its own cursor');
  for(const row of rows)assert.equal(row.offset,fs.statSync(row.path).size,'every log must finish');
  assert.equal(ledger.pendingBytes,0);
  assert.equal(ledger.snapshot().all.input,4000,'shared history counts once, unique increments count once');
  assert.equal(ledger.snapshot().threads.length,1,'one logical conversation appears once');
  assert.equal(ledger.snapshot().selected.total.input,3000,'choose the latest conversation state, not an older copy');
  assert.equal(ledger.snapshot({provider:'fixture'}).threads.length,1,'provider filtering also deduplicates conversations');
  ledger.close();
  fs.mkdirSync(path.join(home,'archived_sessions'));
  const archived=path.join(home,'archived_sessions','a.jsonl');fs.renameSync(files[0],archived);
  ledger=new UsageLedger({dataDir,codexHome:home});ledger.scan();
  assert.equal(ledger.db.prepare('select count(*) n from files').get().n,2);
  assert.equal(ledger.snapshot().all.input,4000);
  const legacy=ledger.db.prepare('select home,id from files where path=?').get(archived);
  ledger.db.prepare('update files set id=? where home=? and id=?').run('shared-session',legacy.home,legacy.id);
  fs.appendFileSync(archived,JSON.stringify(count(2500,'2026-11-05T05:03:00Z'))+'\n');
  ledger.scan({now:Date.now()+3000});
  assert.equal(ledger.snapshot().all.input,4500);
  assert.equal(ledger.db.prepare('select count(*) n from files').get().n,2,'old keyed cursor replaced without a duplicate');
 }finally{
  ledger?.close();
  assert.equal(path.dirname(root),path.resolve(os.tmpdir()));
  fs.rmSync(root,{recursive:true,force:true});
 }
});
