import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const app=fileURLToPath(new URL('../',import.meta.url));
const baseline=path.resolve(app,process.env.GPT_NIANG_LEGACY_ROOT??'../gpt-niang-usage');
const powershell=(args)=>spawnSync('powershell.exe',['-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',...args],{windowsHide:true,encoding:'utf8',timeout:10000});
const writeJson=(file,value)=>fs.writeFileSync(file,JSON.stringify(value));

test('old update-agent shortcuts reach the bound JS launcher and reject invalid bindings',{skip:process.platform!=='win32',timeout:45000},async t=>{
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-legacy-shortcut-'));
  t.after(()=>{assert.equal(path.dirname(root),path.resolve(os.tmpdir()));fs.rmSync(root,{recursive:true,force:true,maxRetries:20,retryDelay:50});});
  const appDir=path.join(root,'program space'),dataDir=path.join(root,'data'),agent=path.join(root,'old-agent');
  const launcherPath=path.join(dataDir,'launcher/GPTNiang.Start.exe'),marker=path.join(root,'launched.json');
  for(const dir of [path.join(appDir,'runtime'),path.join(appDir,'src'),path.join(appDir,'node_modules/electron/dist'),path.dirname(launcherPath),agent])fs.mkdirSync(dir,{recursive:true});
  fs.copyFileSync(path.join(app,'runtime/start-supervisor.ps1'),path.join(appDir,'runtime/start-supervisor.ps1'));
  fs.copyFileSync(path.join(app,'native/GPTNiang.Start.exe'),launcherPath);
  // The real native launcher invokes a harmless Node entry in an isolated root.
  fs.copyFileSync(process.execPath,path.join(appDir,'node_modules/electron/dist/electron.exe'));
  fs.writeFileSync(path.join(appDir,'src/start.mjs'),`import fs from 'node:fs';fs.writeFileSync(${JSON.stringify(marker)},JSON.stringify({cwd:process.cwd(),nodeMode:process.env.ELECTRON_RUN_AS_NODE}));`);
  for(const name of ['update-agent.ps1','update-common.ps1','supervisor-task.ps1'])fs.copyFileSync(path.join(baseline,'runtime',name),path.join(agent,name));
  const sidResult=powershell(['-Command','[Security.Principal.WindowsIdentity]::GetCurrent().User.Value']);
  assert.equal(sidResult.status,0,sidResult.stderr);
  const binding={sid:sidResult.stdout.trim(),appDir,dataDir};
  const config={...binding,launcherPath,version:'1.4.0-beta.4',architecture:'javascript-electron',candidate:false};
  const packageInfo={name:'gpt-niang-usage',version:config.version,architecture:config.architecture};
  writeJson(path.join(appDir,'package.json'),packageInfo);
  writeJson(path.join(agent,'binding.json'),binding);
  const reset=()=>{writeJson(path.join(appDir,'installation.json'),config);writeJson(path.join(path.dirname(launcherPath),'launcher.json'),binding);fs.rmSync(marker,{force:true});};
  const run=()=>powershell(['-File',path.join(agent,'update-agent.ps1')]);
  reset();const result=run();
  assert.equal(result.status,0,result.stderr+(fs.existsSync(path.join(agent,'update-diagnostic.txt'))?fs.readFileSync(path.join(agent,'update-diagnostic.txt'),'utf8'):''));
  for(let n=0;n<100&&!fs.existsSync(marker);n++)await new Promise(resolve=>setTimeout(resolve,20));
  assert.ok(fs.existsSync(marker),'old launcher must reach the JS entry point');
  assert.deepEqual(JSON.parse(fs.readFileSync(marker,'utf8')),{cwd:appDir,nodeMode:'1'});
  for(const [name,change] of [
    ['candidate',()=>writeJson(path.join(appDir,'installation.json'),{...config,candidate:true})],
    ['foreign user',()=>writeJson(path.join(appDir,'installation.json'),{...config,sid:'S-1-0-0'})],
    ['foreign app',()=>writeJson(path.join(appDir,'installation.json'),{...config,appDir:root})],
    ['foreign launcher',()=>writeJson(path.join(appDir,'installation.json'),{...config,launcherPath:path.join(root,'other.exe')})],
    ['foreign data binding',()=>writeJson(path.join(path.dirname(launcherPath),'launcher.json'),{...binding,dataDir:root})],
    ['version mismatch',()=>writeJson(path.join(appDir,'installation.json'),{...config,version:'0.0.0'})],
    ['missing launcher',()=>fs.renameSync(launcherPath,launcherPath+'.bak')],
  ]){
    reset();change();const rejected=run();
    assert.notEqual(rejected.status,0,name);
    assert.equal(fs.existsSync(marker),false,name+' must not launch');
  }
});
