import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { guiEnvironment } from '../src/core/storage.mjs';
test('native pixel no-ops preserve moves and exact GDI hit regions',{skip:process.platform!=='win32',timeout:20000},async t=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-js-native-noop-'));
  t.after(()=>{assert.equal(path.dirname(path.resolve(dir)),path.resolve(os.tmpdir()));fs.rmSync(dir,{recursive:true,force:true});});
  const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
  const child=spawn(path.join(root,'node_modules/electron/dist/electron.exe'),[path.join(root,'tests/fixtures/native-noop-electron.mjs'),dir],{windowsHide:true,env:guiEnvironment(),stdio:['ignore','pipe','pipe']});
  t.after(()=>{if(child.exitCode===null)child.kill();});
  let output='';child.stdout.on('data',b=>output+=b);child.stderr.on('data',b=>output+=b);
  const code=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',resolve);});
  assert.equal(code,0,output);const result=JSON.parse(fs.readFileSync(path.join(dir,'native-noop-result.json'),'utf8'));
  assert.equal(result.compared,84);assert.ok(result.shape.equivalentUpdates>0);
});
