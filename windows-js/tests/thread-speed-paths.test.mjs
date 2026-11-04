import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {allowedRollout,RolloutTail} from '../runtime/thread-speed.mjs';

function fixture(t){
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'niang-archive-path-'));
  const home=path.join(root,'home');fs.mkdirSync(home);
  t.after(()=>{
    const actual=path.resolve(root),prefix=path.resolve(os.tmpdir())+path.sep;
    assert.ok(actual.startsWith(prefix)&&path.basename(actual).startsWith('niang-archive-path-'));
    fs.rmSync(actual,{recursive:true,force:true});
  });
  function write(relative,content=''){
    const file=path.join(home,relative);fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,content);return file;
  }
  return {root,home,write};
}
const usage=(at,count)=>JSON.stringify({timestamp:new Date(at).toISOString(),type:'event_msg',payload:{type:'token_count',info:{total_token_usage:{output_tokens:count}}}})+'\n';

test('a valid archived rollout is readable when the active sessions directory is absent',t=>{
  const {home,write}=fixture(t);
  const file=write('archived_sessions/rollout.jsonl',usage(1000,100)+usage(11000,400));
  assert.equal(fs.existsSync(path.join(home,'sessions')),false);
  const allowed=allowedRollout(file,home);
  assert.equal(allowed,fs.realpathSync(file));
  assert.equal(new RolloutTail(allowed).update().latest.tokensPerSecond,30);
});
test('active sessions stay readable when the archive directory is absent',t=>{
  const {home,write}=fixture(t),file=write('sessions/rollout.jsonl');
  assert.equal(allowedRollout(file,home),fs.realpathSync(file));
});
test('active and archived files are independently accepted when both roots exist',t=>{
  const {home,write}=fixture(t);
  for(const file of [write('sessions/active.jsonl'),write('archived_sessions/archived.jsonl')]){
    assert.equal(allowedRollout(file,home),fs.realpathSync(file));
  }
});
test('moving the last active file to archives does not require recreating sessions',t=>{
  const {home,write}=fixture(t),active=write('sessions/last.jsonl',usage(1000,100)+usage(11000,400));
  assert.equal(allowedRollout(active,home),fs.realpathSync(active));
  const archive=path.join(home,'archived_sessions');fs.mkdirSync(archive);
  const moved=path.join(archive,'last.jsonl');fs.renameSync(active,moved);fs.rmdirSync(path.join(home,'sessions'));
  assert.equal(allowedRollout(moved,home),fs.realpathSync(moved));
});
test('failure to inspect one allowed root does not suppress a valid file in the other',t=>{
  const {home,write}=fixture(t),file=write('archived_sessions/allowed.jsonl');
  const original=fs.realpathSync.bind(fs),blocked=path.join(home,'sessions');
  t.mock.method(fs,'realpathSync',target=>{
    if(target===blocked)throw Object.assign(new Error('isolated denied directory'),{code:'EACCES'});
    return original(target);
  });
  assert.equal(allowedRollout(file,home),original(file));
});
test('sibling-prefix and outside-home files remain rejected with either root missing',t=>{
  const {home,write}=fixture(t);write('archived_sessions/allowed.jsonl');
  assert.equal(allowedRollout(write('archived_sessions-extra/private.jsonl'),home),null);
  assert.equal(allowedRollout(write('private.jsonl'),home),null);
});
test('non-jsonl files and missing paths remain rejected',t=>{
  const {home,write}=fixture(t);
  assert.equal(allowedRollout(write('archived_sessions/notes.txt'),home),null);
  assert.equal(allowedRollout(path.join(home,'archived_sessions/missing.jsonl'),home),null);
});
test('an archive directory link escaping the allowed root remains rejected',t=>{
  const {root,home,write}=fixture(t);write('archived_sessions/allowed.jsonl');
  const outside=path.join(root,'outside');fs.mkdirSync(outside);fs.writeFileSync(path.join(outside,'private.jsonl'),'');
  const link=path.join(home,'archived_sessions','escape');
  fs.symlinkSync(outside,link,process.platform==='win32'?'junction':'dir');
  assert.equal(allowedRollout(path.join(link,'private.jsonl'),home),null);
});
test('an archive alias targeting a legitimate file still resolves to the canonical path',t=>{
  const {home,write}=fixture(t),real=write('archived_sessions/real/rollout.jsonl');
  const link=path.join(home,'archived_sessions','alias');
  fs.symlinkSync(path.dirname(real),link,process.platform==='win32'?'junction':'dir');
  assert.equal(allowedRollout(path.join(link,'rollout.jsonl'),home),fs.realpathSync(real));
});
