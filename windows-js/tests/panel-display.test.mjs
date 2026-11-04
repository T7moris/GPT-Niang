import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {guiEnvironment} from '../src/core/storage.mjs';

for(const dpi of [1,1.25,1.5,2])test(`panel display, placement and transitions at ${dpi*100}% emulated raster scale`,{skip:process.platform!=='win32',timeout:45000},async(t)=>{
  const child=spawn(fileURLToPath(new URL('../node_modules/electron/dist/electron.exe',import.meta.url)),[fileURLToPath(new URL('./fixtures/panel-display-electron.mjs',import.meta.url))],{windowsHide:true,env:{...guiEnvironment(),PANEL_TEST_SCALE:String(dpi)},stdio:'pipe'});
  let output='',errors='';child.stdout.on('data',data=>output+=data);child.stderr.on('data',data=>errors+=data);
  assert.equal(await new Promise((resolve,reject)=>{child.once('exit',resolve);child.once('error',reject);}),0,errors);
  const result=JSON.parse(output.trim().split(/\r?\n/).find(line=>line.startsWith('{')));
  assert.ok(Math.abs(result.dpi-dpi)<.01,'raster scale did not apply');
  const failed=result.checks.filter(check=>!check.passed);
  assert.deepEqual(failed,[],JSON.stringify(failed,null,2));
  t.diagnostic(`${result.checks.length} display and interaction checks passed; actual emulated pixel ratio ${result.dpi}`);
});
