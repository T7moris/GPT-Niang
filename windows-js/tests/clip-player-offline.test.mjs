import test from 'node:test';import assert from 'node:assert/strict';import {spawn} from 'node:child_process';import {fileURLToPath} from 'node:url';import {guiEnvironment} from '../src/core/storage.mjs';
test('real offline PCM smoothly reaches zero without an audible output device',{skip:process.platform!=='win32',timeout:20000},async()=>{
 const child=spawn(fileURLToPath(new URL('../node_modules/electron/dist/electron.exe',import.meta.url)),[fileURLToPath(new URL('./fixtures/clip-player-offline.cjs',import.meta.url))],{windowsHide:true,env:guiEnvironment(),stdio:'pipe'});let output='',error='';child.stdout.on('data',data=>output+=data);child.stderr.on('data',data=>error+=data);
 assert.equal(await new Promise((resolve,reject)=>{child.once('exit',resolve);child.once('error',reject);}),0,error);
 const result=JSON.parse(output.trim().split(/\r?\n/).find(line=>line.startsWith('{')));assert.equal(result.actualOfflinePCM,true);assert.equal(result.visibleWindows,0);
});
