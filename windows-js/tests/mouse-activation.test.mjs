import test from 'node:test';import assert from 'node:assert/strict';import {spawn} from 'node:child_process';import {fileURLToPath} from 'node:url';import {guiEnvironment} from '../src/core/storage.mjs';
test('non-focusable widget preserves every mouse press without activating or leaking native callbacks',{skip:process.platform!=='win32',timeout:15000},async(t)=>{
 const child=spawn(fileURLToPath(new URL('../node_modules/electron/dist/electron.exe',import.meta.url)),[fileURLToPath(new URL('./fixtures/mouse-activation-electron.mjs',import.meta.url))],{windowsHide:true,env:guiEnvironment(),stdio:'pipe'});let output='',error='';child.stdout.on('data',bytes=>output+=bytes);child.stderr.on('data',bytes=>error+=bytes);
 t.after(()=>{if(child.exitCode===null)child.kill();});
 assert.equal(await new Promise((resolve,reject)=>{child.once('exit',resolve);child.once('error',reject);}),0,error);
 const value=JSON.parse(output.trim().split(/\r?\n/).find(line=>line.startsWith('{')));assert.equal(value.before,4);assert.deepEqual(value.after,[3]);assert.equal(value.restored,value.before);
 for(const name of ['attached','same','noFocusChange','oneCallback','hidden','closed','empty','destroyedCleanup'])assert.equal(value[name],true,name+': '+JSON.stringify(value));
 assert.equal(value.ordinary,value.ordinaryBefore,'other native messages must continue through the original handler');
});
