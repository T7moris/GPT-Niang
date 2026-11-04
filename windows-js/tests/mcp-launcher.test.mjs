import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import path from 'node:path';import os from 'node:os';import {spawn} from 'node:child_process';import {fileURLToPath} from 'node:url';
const app=fileURLToPath(new URL('../',import.meta.url));
for(const kind of ['configured','bundled','foreign'])test('cached MCP launcher forwards stdio through '+kind+' installation binding',{skip:process.platform!=='win32',timeout:15000},async t=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-mcp-launch-')),installed=path.join(root,'installed'),cache=path.join(root,'c'.repeat(223-root.length-1)),data=path.join(root,'data'),launcher=path.join(cache,'native/GPTNiang.Start.exe');
 t.after(()=>{assert.equal(path.dirname(root),path.resolve(os.tmpdir()));fs.rmSync(root,{recursive:true,force:true});});
 for(const directory of [path.dirname(launcher),path.join(installed,'runtime'),data])fs.mkdirSync(directory,{recursive:true});
 fs.copyFileSync(path.join(app,'native/GPTNiang.Start.exe'),launcher);
 const nodePath=kind==='bundled'?path.join(root,'missing-node.exe'):process.execPath,configuration={appDir:installed,dataDir:data,nodePath,architecture:'javascript-electron',codexHome:path.join(root,'own-home')};
 fs.writeFileSync(path.join(cache,'installation.json'),JSON.stringify(configuration));fs.writeFileSync(path.join(installed,'installation.json'),JSON.stringify({...configuration,dataDir:kind==='foreign'?path.join(root,'foreign-data'):data}));
 fs.writeFileSync(path.join(installed,'runtime/mcp.mjs'),"import readline from 'node:readline';readline.createInterface({input:process.stdin}).on('line',line=>{console.log(JSON.stringify({line,executable:process.execPath,codexHome:process.env.CODEX_HOME}));console.error('forwarded stderr');});");
 if(kind==='bundled'){
  // Only the interpreter and its startup data are needed in Node mode. Use
  // hard links to immutable runtime files, avoiding a second runtime copy.
  const directory=path.join(installed,'node_modules/electron/dist');fs.mkdirSync(directory,{recursive:true});
  for(const name of fs.readdirSync(path.join(app,'node_modules/electron/dist'))){const file=path.join(app,'node_modules/electron/dist',name);if(fs.statSync(file).isFile())fs.linkSync(file,path.join(directory,name));}
 }
 const child=spawn(launcher,['--mcp'],{windowsHide:true,env:{...process.env,ELECTRON_RUN_AS_NODE:'1'},stdio:'pipe'}),run={stdout:'',stderr:'',status:null};child.stdin.on('error',()=>{});child.stdout.on('data',bytes=>run.stdout+=bytes);child.stderr.on('data',bytes=>run.stderr+=bytes);
 const exited=new Promise((resolve,reject)=>{child.once('exit',code=>{run.status=code;resolve();});child.once('error',reject);}),timer=setTimeout(()=>child.kill(),10000);
 child.stdin.write('中文输入 🌙\n');
 for(let n=0;n<100&&!run.stdout.includes('\n')&&child.exitCode===null;n++)await new Promise(resolve=>setTimeout(resolve,20));
 const interactive=run.stdout.includes('\n');child.stdin.end();try{await exited;}finally{clearTimeout(timer);}
 if(kind==='foreign'){assert.equal(run.status,1);assert.match(run.stderr,/binding mismatch/);assert.equal(run.stdout,'');return;}
 assert.equal(run.status,0,run.stderr);assert.equal(interactive,true,'must reply while the MCP connection remains open');const value=JSON.parse(run.stdout.trim());assert.equal(value.line,'中文输入 🌙');assert.equal(value.codexHome,configuration.codexHome);assert.match(run.stderr,/forwarded stderr/);
 assert.equal(path.resolve(value.executable),kind==='bundled'?path.join(installed,'node_modules/electron/dist/electron.exe'):process.execPath);
 assert.ok(path.join(cache,'node_modules/electron/dist/v8_context_snapshot.bin').length>259,'exercise the long cache path that the launcher avoids');
});
