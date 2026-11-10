import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import {spawn,spawnSync} from 'node:child_process';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {normalizeSettings} from '../src/core/settings.mjs';
import * as storage from '../src/core/storage.mjs';
import {requestRefresh} from '../runtime/refresh-client.mjs';
const app=fileURLToPath(new URL('../',import.meta.url)),pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
function temporary(t){const directory=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-compat-'));t.after(async()=>{assert.equal(path.dirname(directory),path.resolve(os.tmpdir()));await fs.promises.rm(directory,{recursive:true,force:true,maxRetries:10,retryDelay:50});});return directory;}
for(const invalid of ['missing','directory'])test('headless refresh recovers from a '+invalid+' configured Node host',{timeout:5000},async t=>{
 const base=temporary(t),root=path.join(base,'program'),dataDir=path.join(base,'data'),configPath=path.join(root,'installation.json');fs.mkdirSync(path.join(root,'runtime'),{recursive:true});fs.mkdirSync(dataDir);
 const snapshot={ok:true,queryOk:true,windows:[],observedAt:123,hostFallback:true};
 fs.writeFileSync(path.join(root,'runtime/watch.mjs'),`import fs from 'node:fs';import path from 'node:path';const config=JSON.parse(fs.readFileSync(process.argv[2]));const requests=path.join(config.dataDir,'refresh-requests');const end=setTimeout(()=>{clearInterval(timer);process.exit(1);},1500);const timer=setInterval(()=>{const names=fs.readdirSync(requests);if(!names.length)return;const request=JSON.parse(fs.readFileSync(path.join(requests,names[0])));const results=path.join(config.dataDir,'refresh-results');fs.mkdirSync(results,{recursive:true});fs.writeFileSync(path.join(results,request.id+'.json'),JSON.stringify({requestId:request.id,snapshot:${JSON.stringify(snapshot)}}));clearInterval(timer);clearTimeout(end);},20);`);
 const config={appDir:root,dataDir,nodePath:invalid==='directory'?base:path.join(base,'removed-node.exe')};fs.writeFileSync(configPath,JSON.stringify(config));
 assert.deepEqual(await requestRefresh(config,configPath,{timeoutMs:2000,pollMs:20}),snapshot);
});

for(const scenario of ['path-case','missing-node','node-directory'])test(`actual start script accepts legacy ${scenario} under Unicode and punctuation paths`,{skip:process.platform!=='win32',timeout:8000},async t=>{
  const dir=temporary(t),root=path.join(dir,"中文 & # % ' 🌟",'程序'),data=path.join(dir,'个人设置'),src=path.join(root,'src');
  fs.mkdirSync(path.join(src,'core'),{recursive:true});fs.mkdirSync(data);
  for(const name of ['start.mjs','core/storage.mjs'])fs.copyFileSync(path.join(app,'src',name),path.join(src,name));
  fs.writeFileSync(path.join(root,'package.json'),JSON.stringify({type:'module'}));
  const output=path.join(data,'supervisor-started.json');
  fs.writeFileSync(path.join(src,'supervisor.mjs'),`import fs from 'node:fs';fs.writeFileSync(${JSON.stringify(output)},JSON.stringify({pid:process.pid,host:process.execPath,node:process.versions.node}));`);
  fs.writeFileSync(path.join(root,'installation.json'),JSON.stringify({appDir:scenario==='path-case'?root.toUpperCase():root,dataDir:data,nodePath:scenario==='path-case'?process.execPath:scenario==='node-directory'?dir:path.join(dir,'removed-node.exe')}));
  const child=spawn(process.execPath,[path.join(src,'start.mjs')],{windowsHide:true,env:storage.guiEnvironment(),stdio:'pipe'});let error='';child.stderr.on('data',b=>error+=b);
  assert.equal(await new Promise((resolve,reject)=>{child.once('exit',resolve);child.once('error',reject);}),0,error);
  for(let n=0;n<100&&!fs.existsSync(output);n++)await pause(20);
  assert.ok(fs.existsSync(output),'the supervisor was not launched: '+error);
  const actual=JSON.parse(fs.readFileSync(output));assert.equal(actual.host,process.execPath);assert.ok(actual.node);
  for(let n=0;n<100;n++){try{process.kill(actual.pid,0);await pause(10);}catch{break;}}
  assert.throws(()=>process.kill(actual.pid,0));
});

test('Windows path casing does not turn an installed GUI into a candidate or reject its supervisor',{skip:process.platform!=='win32'},()=>{
  const file=path.join(app,'src/main.mjs'),code=fs.readFileSync(file,'utf8'),start=code.indexOf('const root ='),end=code.indexOf('const candidateRoot =',start);
  const config={appDir:app.toUpperCase(),architecture:'javascript-electron'},context={path,fileURLToPath,process:{argv:['electron','main.mjs','--installed']},readJson:()=>config,samePath:storage.samePath};
  vm.createContext(context);vm.runInContext(code.slice(start,end).replaceAll('import.meta.url',JSON.stringify(pathToFileURL(file).href)),context);
  assert.equal(vm.runInContext('candidate',context),false);
  const supervisor=fs.readFileSync(path.join(app,'src/supervisor.mjs'),'utf8'),a=supervisor.indexOf('const root ='),b=supervisor.indexOf('const dataDir =',a);
  const supervisorContext={path,fileURLToPath,readJson:()=>({...config,dataDir:path.join(app,'../test-data')}),samePath:storage.samePath};
  vm.createContext(supervisorContext);assert.doesNotThrow(()=>vm.runInContext(supervisor.slice(a,b).replaceAll('import.meta.url',JSON.stringify(pathToFileURL(path.join(app,'src/supervisor.mjs')).href)),supervisorContext));
});

test('bootstrap logging keeps the installed data binding when its Windows path casing changes',{skip:process.platform!=='win32'},()=>{
  const config={appDir:app.toUpperCase(),dataDir:path.resolve(app,'../isolated-data'),architecture:'javascript-electron'},code=fs.readFileSync(path.join(app,'src/bootstrap.cjs'),'utf8');
  const context={__dirname:path.join(app,'src'),process:{argv:['electron','app'],pid:1,platform:process.platform,on(){}},require:name=>name==='node:fs'?{readFileSync:()=>JSON.stringify(config),mkdirSync(){},appendFileSync(){}}:name==='node:path'?path:{app:{exit(){}}}};
  vm.createContext(context);vm.runInContext(code.slice(0,code.indexOf('import("./main.mjs")')),context);
  assert.equal(vm.runInContext('installed',context),true);assert.equal(vm.runInContext('file',context),path.join(config.dataDir,'startup.log'));
});

test('legacy setting string versions and case-insensitive enums match the original PowerShell reader',{skip:process.platform!=='win32'},t=>{
  const directory=temporary(t),file=path.join(directory,'settings.json'),saved={layoutVersion:'2',right:4,left:-14,bottom:-12,anchor:'FREE',side:'LEFT',colorMode:'ORIGINAL',soundOn:false,scale:1.2,bubbleScale:1.4};
  fs.writeFileSync(file,'\uFEFF'+JSON.stringify(saved));
  const legacy=fs.readFileSync(path.resolve(app,process.env.GPT_NIANG_LEGACY_ROOT??'../gpt-niang-usage','widget.ps1'),'utf8'),a=legacy.indexOf('try{$settings=Get-Content -LiteralPath $settingsFile'),b=legacy.indexOf('Initialize-WidgetAutoQuoteSettings $settings',a);
  assert.ok(a>=0&&b>a);
  const command=`$settingsFile='${file.replaceAll("'","''")}';$script:offsetRight=0;$script:offsetLeft=$null;$script:offsetBottom=0;$script:anchor='right';$script:side='right';$script:colorMode='mixed';$script:scale=1;$script:bubbleScale=1;${legacy.slice(a,b)}\n@{left=$script:offsetLeft;bottom=$script:offsetBottom;anchor=([string]$script:anchor).ToLowerInvariant();side=([string]$script:side).ToLowerInvariant();colorMode=([string]$script:colorMode).ToLowerInvariant()}|ConvertTo-Json -Compress`;
  const result=spawnSync(path.join(process.env.WINDIR,'System32/WindowsPowerShell/v1.0/powershell.exe'),['-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',Buffer.from(command,'utf16le').toString('base64')],{windowsHide:true,encoding:'utf8',timeout:10000});
  assert.equal(result.status,0,result.stderr);const expected=JSON.parse(result.stdout.replace(/^\uFEFF/,'')),normalized=normalizeSettings(storage.readJson(file));
  assert.deepEqual(Object.fromEntries(Object.keys(expected).map(key=>[key,normalized[key]])),expected);
});

test('update path validation accepts Windows casing while still rejecting overlapping personal directories',{skip:process.platform!=='win32'},()=>{
  const code=fs.readFileSync(path.join(app,'src/core/update-transaction.mjs'),'utf8'),start=code.indexOf('function validate(job)'),end=code.indexOf('function clearMarker(',start),context={path,samePath:storage.samePath};
  vm.createContext(context);vm.runInContext(code.slice(start,end),context);
  const job={root:'C:\\Widget',dataDir:'C:\\Personal',source:'c:\\PERSONAL\\UPDATES\\token',token:'token',parentPid:1,expected:[{name:'package.json',hash:'fixture'}]};
  assert.doesNotThrow(()=>context.validate(job));
  for(const dataDir of ['c:\\WIDGET','c:\\WIDGET\\personal','c:\\'])assert.throws(()=>context.validate({...job,dataDir,source:path.join(dataDir,'updates/token')}),/目录无效/);
  assert.throws(()=>context.validate({...job,root:'c:\\personal\\program'}),/目录无效/);
  assert.throws(()=>context.validate({...job,source:'C:\\PersonalElsewhere\\updates\\token'}),/目录无效/);
});

test('runtime host fallback keeps valid choices and ignores stale paths or directories',t=>{
  const directory=temporary(t),bundled=path.join(directory,'node_modules/electron/dist/electron.exe'),configured=path.join(directory,'custom-node.exe');
  fs.mkdirSync(path.dirname(bundled),{recursive:true});fs.writeFileSync(bundled,'fixture');fs.writeFileSync(configured,'fixture');
  assert.equal(storage.resolveNodeHost(directory,configured),configured);
  assert.equal(storage.resolveNodeHost(directory,path.join(directory,'removed.exe')),bundled);
  assert.equal(storage.resolveNodeHost(directory,directory),bundled);
  fs.unlinkSync(bundled);assert.equal(storage.resolveNodeHost(directory,null),process.execPath);
  assert.throws(()=>storage.resolveNodeHost(directory,null,path.join(directory,'missing-fallback.exe')),/运行环境/);
});
