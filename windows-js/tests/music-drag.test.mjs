import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';
import {guiEnvironment} from '../src/core/storage.mjs';
test('music grip physically moves the native widget without depending on audio callbacks',{skip:process.platform!=='win32',timeout:18000},async t=>{
  const source=fileURLToPath(new URL('../',import.meta.url)),root=process.env.GPT_NIANG_TEST_ROOT??source,data=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-native-music-drag-'));
  t.after(()=>{assert.equal(path.dirname(data),path.resolve(os.tmpdir()));fs.rmSync(data,{recursive:true,force:true});});
  const child=spawn(path.join(root,'node_modules/electron/dist/electron.exe'),[path.join(source,'tests/fixtures/music-drag-main.cjs'),root,data],{windowsHide:true,env:guiEnvironment(),stdio:'pipe'});let output='',errors='';
  child.stdout.on('data',b=>output+=b);child.stderr.on('data',b=>errors+=b);
  assert.equal(await new Promise((resolve,reject)=>{child.once('exit',resolve);child.once('error',reject);}),0,errors);
  const report=JSON.parse(output.trim().split(/\r?\n/).find(line=>line.startsWith('{')));assert.ok(report.dx<-40&&report.dx>-130,JSON.stringify(report));
});
