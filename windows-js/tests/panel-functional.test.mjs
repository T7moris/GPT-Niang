import test from 'node:test';import assert from 'node:assert/strict';import {spawn} from 'node:child_process';import {fileURLToPath} from 'node:url';import {guiEnvironment} from '../src/core/storage.mjs';
test('all panel input lifecycles retain disabled states, navigation, drafts and focus',{skip:process.platform!=='win32',timeout:25000},async()=>{
 const child=spawn(fileURLToPath(new URL('../node_modules/electron/dist/electron.exe',import.meta.url)),[fileURLToPath(new URL('./fixtures/panel-functional-electron.mjs',import.meta.url))],{windowsHide:true,env:guiEnvironment(),stdio:'pipe'});let output='',errors='';child.stdout.on('data',bytes=>output+=bytes);child.stderr.on('data',bytes=>errors+=bytes);
 assert.equal(await new Promise((resolve,reject)=>{child.once('exit',resolve);child.once('error',reject);}),0,errors);
 const result=JSON.parse(output.trim().split(/\r?\n/).find(line=>line.startsWith('{')));for(const [section,checks]of Object.entries(result))for(const [name,passed]of Object.entries(checks))assert.equal(passed,true,section+'.'+name+': '+JSON.stringify(result));
});
