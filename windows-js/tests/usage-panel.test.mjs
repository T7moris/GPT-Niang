import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {guiEnvironment} from '../src/core/storage.mjs';

test('usage filters stay attached during refresh and keep working after provider changes', {skip:process.platform!=='win32',timeout:25000}, async t=>{
  const child=spawn(fileURLToPath(new URL('../node_modules/electron/dist/electron.exe',import.meta.url)),
    [fileURLToPath(new URL('./fixtures/usage-panel-electron.mjs',import.meta.url))],
    {windowsHide:true,env:guiEnvironment(),stdio:'pipe'});
  t.after(()=>{if(child.exitCode===null)child.kill();});
  let output='',errors='';
  child.stdout.on('data',bytes=>output+=bytes);
  child.stderr.on('data',bytes=>errors+=bytes);
  assert.equal(await new Promise((resolve,reject)=>{child.once('exit',resolve);child.once('error',reject);}),0,errors);
  const result=JSON.parse(output.trim().split(/\r?\n/).find(line=>line.startsWith('{')));
  for(const [name,passed] of Object.entries(result))assert.equal(passed,true,name+': '+JSON.stringify(result));
});
