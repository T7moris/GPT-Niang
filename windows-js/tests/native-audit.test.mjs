import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn,spawnSync} from 'node:child_process';
import {WindowsBridge} from '../src/windows/bridge.mjs';
import {guiEnvironment} from '../src/core/storage.mjs';
const app=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const pause=ms=>new Promise(r=>setTimeout(r,ms));
function temporary(t){const dir=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-native-fix-'));t.after(()=>{assert.ok(path.resolve(dir).startsWith(path.resolve(os.tmpdir())+path.sep));fs.rmSync(dir,{recursive:true,force:true});});return dir;}
test('slow accessibility provider remains limited to one task across host changes',{skip:process.platform!=='win32',timeout:15000},async t=>{
  const dir=temporary(t),native=path.join(dir,'native');fs.mkdirSync(native);
  const source=fs.readFileSync(path.join(app,'native','Bridge.cs'),'utf8'),boundary=source.indexOf(' static bool Ready(IntPtr handle)');assert.ok(boundary>0);
  const fake=source.slice(0,boundary)+' static int active=0;static bool Ready(IntPtr handle){int n=Interlocked.Increment(ref active);Console.Error.WriteLine("AUDIT_ACTIVE="+n);Thread.Sleep(600);Interlocked.Decrement(ref active);return true;}\n}\n';
  const bridgeSource=path.join(native,'Bridge.cs');fs.writeFileSync(bridgeSource,fake);
  const framework=path.join(process.env.WINDIR,'Microsoft.NET','Framework64','v4.0.30319'),wpf=path.join(framework,'WPF');
  const compile=spawnSync(path.join(framework,'csc.exe'),['/nologo','/target:exe','/optimize+','/out:'+path.join(native,'GPTNiang.Native.exe'),'/reference:System.Web.Extensions.dll','/reference:System.Xaml.dll',...['UIAutomationClient.dll','UIAutomationTypes.dll','WindowsBase.dll','PresentationCore.dll'].map(f=>'/reference:'+path.join(wpf,f)),bridgeSource,path.join(app,'native','music-audio.cs')],{windowsHide:true,encoding:'utf8'});assert.equal(compile.status,0,compile.stdout+compile.stderr);
  const bridge=new WindowsBridge(dir),active=[];bridge.child.stderr.on('data',b=>{for(const match of String(b).matchAll(/AUDIT_ACTIVE=(\d+)/g))active.push(+match[1]);});
  try{
    assert.equal(await bridge.probe(1),false);for(let n=0;n<10;n++)assert.equal(await bridge.probe(2),false);
    await pause(700);assert.equal(await bridge.probe(2),false);await pause(700);assert.equal(await bridge.probe(2),true);
    assert.ok(active.length>=2);assert.equal(Math.max(...active),1);
  }finally{const exit=new Promise(r=>bridge.child.once('exit',r));bridge.close();await exit;}
});
test('actual lamp page permits the character image and draws a visible halo',{skip:process.platform!=='win32',timeout:20000},async t=>{
  const dir=temporary(t),output=path.join(dir,'result.json'),electron=path.join(app,'node_modules','electron','dist','electron.exe'),main=path.join(app,'tests','fixtures','lamp-csp-main.cjs');
  const child=spawn(electron,[main],{windowsHide:true,stdio:'pipe',env:{...guiEnvironment(),GPT_NIANG_AUDIT_APP:app,GPT_NIANG_AUDIT_OUTPUT:output,GPT_NIANG_AUDIT_PROFILE:path.join(dir,'profile')}});let stderr='';child.stderr.on('data',b=>stderr+=b);
  const code=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',resolve);});assert.equal(code,0,stderr);
  const result=JSON.parse(fs.readFileSync(output,'utf8'));assert.equal(result.error,undefined,result.error);assert.ok(result.width>0);assert.ok(result.opaque>0);assert.deepEqual(result.violations,[]);
});
test('bundled Electron stages archives containing raw asar files',{skip:process.platform!=='win32',timeout:15000},async t=>{
  const dir=temporary(t),electron=path.join(app,'node_modules','electron','dist','electron.exe'),fixture=path.join(app,'tests','fixtures','update-io-electron.mjs');
  const child=spawn(electron,[fixture,dir],{windowsHide:true,stdio:'pipe',env:{...process.env,ELECTRON_RUN_AS_NODE:'1'}});let stderr='';child.stderr.on('data',b=>stderr+=b);
  const code=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',resolve);});assert.equal(code,0,stderr);
  assert.equal(fs.readFileSync(path.join(dir,'result.txt'),'utf8'),'ordinary file, not an archive');
});
test('bundled Electron installer copies raw asar files',{skip:process.platform!=='win32',timeout:15000},async t=>{
  const dir=temporary(t),electron=path.join(app,'node_modules','electron','dist','electron.exe'),fixture=path.join(app,'tests','fixtures','installer-electron.mjs');
  const child=spawn(electron,[fixture,dir],{windowsHide:true,stdio:'pipe',env:{...process.env,ELECTRON_RUN_AS_NODE:'1'}});let stderr='';child.stderr.on('data',b=>stderr+=b);
  const code=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',resolve);});assert.equal(code,0,stderr);
  assert.equal(fs.readFileSync(path.join(dir,'result.txt'),'utf8'),'raw-asar-installer-fixture');
});
