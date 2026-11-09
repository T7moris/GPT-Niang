import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import fs from 'node:fs';
import os from 'node:os';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {guiEnvironment} from '../src/core/storage.mjs';
import {installationHealthy} from '../src/core/installation-health.mjs';
test('a live GUI cannot pass installation health before its renderer confirms readiness',()=>{
 const root=path.resolve('health-fixture'),electronPath=path.join(root,'electron.exe'),now=Date.now();
 const runtime={pid:17,widget:1,appDir:root,architecture:'javascript-electron',version:'1.3.6',processStartedTicks:'17',at:now};
 const options={root,electronPath,version:'1.3.6',now,inspect:()=>({pid:17,path:electronPath,startedTicks:'17',startedAt:now})};
 assert.equal(installationHealthy({...options,runtime}),false);
 assert.equal(installationHealthy({...options,runtime:{...runtime,rendererReady:false}}),false);
 assert.equal(installationHealthy({...options,runtime:{...runtime,rendererReady:true}}),true);
});
// This fixture deliberately displays a real widget. Running ordinary tests
// must never opt the desktop into visible crash/recovery acceptance.
test('the real widget exits cleanly after its loaded renderer crashes',{skip:process.platform!=='win32'?'Windows only':process.env.GPT_NIANG_VISIBLE_TESTS!=='1'?'Set GPT_NIANG_VISIBLE_TESTS=1 to allow a visible widget':false,timeout:18000},async t=>{
 const root=fileURLToPath(new URL('../',import.meta.url)),data=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-renderer-crash-'));
 t.after(()=>{assert.equal(path.dirname(data),path.resolve(os.tmpdir()));fs.rmSync(data,{recursive:true,force:true});});
 fs.writeFileSync(path.join(data,'settings.json'),JSON.stringify({layoutVersion:2,followHost:false,soundOn:false,desktopTopmost:false}));
 const child=spawn(path.join(root,'node_modules/electron/dist/electron.exe'),[path.join(root,'tests/fixtures/renderer-crash.cjs'),data],{windowsHide:true,env:guiEnvironment(),stdio:'pipe'});let errors='';child.stderr.on('data',bytes=>errors+=bytes);
 const timer=setTimeout(()=>child.kill(),15000);
 let code;try{code=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',resolve);});}finally{clearTimeout(timer);}
 assert.equal(code,0,errors);
 assert.equal(JSON.parse(fs.readFileSync(path.join(data,'crash-requested.json'))).rendererReady,true);
 assert.match(fs.readFileSync(path.join(data,'renderer-errors.log'),'utf8'),/Renderer exited: crashed/);
});
