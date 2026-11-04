import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {removeTransactionDirectory,cleanupFinishedUpdate} from '../src/core/update-cleanup.mjs';
function fixture(t){const root=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-cleanup-'));t.after(()=>{assert.equal(path.dirname(root),path.resolve(os.tmpdir()));fs.rmSync(root,{recursive:true,force:true});});return root;}
test('cleanup rejects parent traversal, current program, personal root and directory links',t=>{
  const root=fixture(t),data=path.join(root,'data'),program=path.join(root,'program');fs.mkdirSync(data);fs.mkdirSync(program);
  fs.writeFileSync(path.join(data,'personal.txt'),'keep');
  assert.throws(()=>removeTransactionDirectory(root,'../outside'),/超出/);
  assert.throws(()=>removeTransactionDirectory(root,'data',[data,program]),/个人目录/);
  const cache=path.join(root,'cache');fs.mkdirSync(cache);fs.symlinkSync(data,path.join(cache,'linked'),process.platform==='win32'?'junction':'dir');
  assert.throws(()=>removeTransactionDirectory(root,'cache',[program]),/链接/);
  assert.equal(fs.readFileSync(path.join(data,'personal.txt'),'utf8'),'keep');
});
test('terminal update removes only its own cache and agent after the owner exits',t=>{
  const root=fixture(t),program=path.join(root,'program'),dataDir=path.join(root,'data'),token='fixture';
  const source=path.join(dataDir,'updates','verified'),agent=path.join(dataDir,'update-agent-js',token),unrelated=program+'.rollback-unrelated';
  for(const d of [program,source,agent,unrelated])fs.mkdirSync(d,{recursive:true});
  fs.writeFileSync(path.join(unrelated,'keep'),'unrelated');fs.writeFileSync(path.join(dataDir,'settings.json'),'personal');
  fs.writeFileSync(path.join(dataDir,'javascript-update-journal.json'),JSON.stringify({root:program,dataDir,token,source,agent,phase:'committed',ownerPid:123}));
  assert.equal(cleanupFinishedUpdate(dataDir,()=>true),false);assert.equal(fs.existsSync(source),true);
  assert.equal(cleanupFinishedUpdate(dataDir,()=>false),true);assert.equal(fs.existsSync(source),false);assert.equal(fs.existsSync(agent),false);
  assert.equal(fs.readFileSync(path.join(dataDir,'settings.json'),'utf8'),'personal');assert.equal(fs.existsSync(unrelated),true);
  assert.equal(cleanupFinishedUpdate(dataDir,()=>false),true);
});
