import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import os from 'node:os';import path from 'node:path';import {fileURLToPath} from 'node:url';import {spawn} from 'node:child_process';import {guiEnvironment} from '../src/core/storage.mjs';
test('actual main and menu routes preserve persisted settings and custom content through a full interaction flow',{skip:process.platform!=='win32',timeout:45000},async t=>{
 const source=fileURLToPath(new URL('../',import.meta.url)),root=process.env.GPT_NIANG_TEST_ROOT??source,data=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-functional-main-'));t.after(()=>{assert.equal(path.dirname(data),path.resolve(os.tmpdir()));fs.rmSync(data,{recursive:true,force:true});});
 const child=spawn(path.join(root,'node_modules/electron/dist/electron.exe'),[path.join(source,'tests/fixtures/functional-main.cjs'),root,data],{windowsHide:true,env:guiEnvironment(),stdio:'pipe'});let output='',errors='';child.stdout.on('data',bytes=>output+=bytes);child.stderr.on('data',bytes=>errors+=bytes);
 assert.equal(await new Promise((resolve,reject)=>{child.once('exit',resolve);child.once('error',reject);}),0,errors);
 const line=output.trim().split(/\r?\n/).find(line=>line.startsWith('{'));assert.ok(line,errors+' '+output);const result=JSON.parse(line);assert.ok(result.checks>=40,JSON.stringify(result));
});
