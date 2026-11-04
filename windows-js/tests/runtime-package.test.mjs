import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {runtimeFiles} from '../scripts/runtime-files.mjs';
function fixture(t) {
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-runtime-files-'));
  t.after(()=>{assert.equal(path.dirname(root),path.resolve(os.tmpdir()));fs.rmSync(root,{recursive:true,force:true});});
  const put=(name,data)=>{const file=path.join(root,name);fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,typeof data==='string'?data:JSON.stringify(data));};
  put('package.json',{dependencies:{production:'1'},devDependencies:{development:'1'}});
  for(const name of ['package.json','index.js','path.txt','LICENSE','dist/electron.exe','dist/resources/default_app.asar','install.js'])put('node_modules/electron/'+name,'fixture');
  put('node_modules/production/package.json',{dependencies:{'@scope/child':'1'},optionalDependencies:{native:'1',absent:'1',wrong:'1'}});
  put('node_modules/production/index.js','fixture');
  put('node_modules/production/node_modules/@scope/child/package.json',{});
  put('node_modules/production/node_modules/@scope/child/index.js','nested');
  put('node_modules/native/package.json',{os:['win32'],cpu:['x64']});put('node_modules/native/addon.node','native');
  put('node_modules/wrong/package.json',{os:['linux']});put('node_modules/wrong/large.bin','wrong');
  put('node_modules/development/package.json',{});put('node_modules/development/index.js','developer');
  return {root,put};
}
test('runtime package includes transitive, nested and matching native dependencies without developer tools',t=>{
  const {root}=fixture(t),files=runtimeFiles(root,{platform:'win32',arch:'x64'});
  assert.ok(files.includes('node_modules/production/node_modules/@scope/child/index.js'));
  assert.ok(files.includes('node_modules/native/addon.node'));
  assert.ok(files.includes('node_modules/electron/dist/resources/default_app.asar'));
  assert.ok(!files.some(x=>x.includes('/development/')||x.includes('/wrong/')||x.endsWith('/install.js')));
});
test('runtime package fails for a missing required dependency instead of silently creating a broken build',t=>{
  const {root,put}=fixture(t);put('node_modules/production/package.json',{dependencies:{missing:'1'}});
  assert.throws(()=>runtimeFiles(root,{platform:'win32',arch:'x64'}),/Missing runtime dependency: missing/);
});
