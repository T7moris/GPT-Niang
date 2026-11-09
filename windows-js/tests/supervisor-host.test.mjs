import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {randomUUID} from 'node:crypto';
const app=fileURLToPath(new URL('../',import.meta.url));
for(const [exitCode,restart] of [[0,false],[7,false],[0,true]])test(`the GUI ${restart?'restart':'supervisor'} host stays alive, drains output and returns child exit ${exitCode} without a console`,{skip:process.platform!=='win32',timeout:15000},async t=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-host-lifetime-'));
 t.after(()=>{assert.equal(path.dirname(root),path.resolve(os.tmpdir()));fs.rmSync(root,{recursive:true,force:true,maxRetries:20,retryDelay:50});});
 for(const directory of ['native','src','node_modules/electron/dist'])fs.mkdirSync(path.join(root,directory),{recursive:true});
 const launcher=path.join(root,'native/GPTNiang.Start.exe'),marker=path.join(root,'finished.json');fs.copyFileSync(path.join(app,'native/GPTNiang.Start.exe'),launcher);
 fs.copyFileSync(process.execPath,path.join(root,'node_modules/electron/dist/electron.exe'));
 const image=fs.readFileSync(launcher);assert.equal(image.readUInt16LE(image.readUInt32LE(0x3c)+92),2);
 fs.writeFileSync(path.join(root,restart?'src/restart-entry.mjs':'src/start.mjs'),`import fs from 'node:fs';import {createRequire} from 'node:module';const require=createRequire(import.meta.url);const koffi=require(${JSON.stringify(path.join(app,'node_modules/koffi'))});const getConsole=koffi.load('kernel32.dll').func('intptr_t __stdcall GetConsoleWindow()');process.stdout.write('x'.repeat(1024*1024));process.stderr.write('y'.repeat(1024*1024));setTimeout(()=>{process.stderr.write('DIAGNOSTIC_TAIL');fs.writeFileSync(${JSON.stringify(marker)},JSON.stringify({hasConsole:Boolean(getConsole()),supervise:process.argv.includes('--supervise'),restart:process.argv.includes('--restart-helper')}));process.exit(${exitCode});},250);`);
 const child=spawn(launcher,restart?['--restart-helper',randomUUID()]:['--supervise'],{windowsHide:true,stdio:'ignore'}),timer=setTimeout(()=>child.kill(),10000);
 await new Promise((resolve,reject)=>{child.once('spawn',resolve);child.once('error',reject);});
 assert.throws(()=>fs.copyFileSync(path.join(app,'native/GPTNiang.Start.exe'),launcher),error=>['EBUSY','EPERM','EACCES'].includes(error.code),'a running waiting host must be stopped before replacement');
 const code=await new Promise((resolve,reject)=>{child.once('exit',resolve);child.once('error',reject);}).finally(()=>clearTimeout(timer));
 assert.equal(code,exitCode);assert.equal(fs.existsSync(marker),true,'host must not exit before the child');
 assert.doesNotThrow(()=>fs.copyFileSync(path.join(app,'native/GPTNiang.Start.exe'),launcher));
 assert.deepEqual(JSON.parse(fs.readFileSync(marker)),{hasConsole:false,supervise:!restart,restart});
 if(exitCode){const diagnostic=fs.readFileSync(path.join(root,'native/supervisor-launch-error.txt'),'utf8');assert.match(diagnostic,/exit code: 7/);assert.ok(diagnostic.endsWith('DIAGNOSTIC_TAIL'));assert.ok(diagnostic.length<16500);}
});
