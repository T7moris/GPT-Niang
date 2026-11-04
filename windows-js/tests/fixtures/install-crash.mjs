import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash,randomUUID} from 'node:crypto';
import {install} from '../../src/install.mjs';
import {recoverInstall} from '../../src/core/install-recovery.mjs';
import {personalState} from './personal-state.mjs';
const app=fileURLToPath(new URL('../../',import.meta.url)),root=process.argv[2]?path.resolve(process.argv[2]):null,wanted=process.argv[3];
const json=(file,value)=>{fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,JSON.stringify(value));};
const read=file=>JSON.parse(fs.readFileSync(file,'utf8'));
const phaseHook=async(phase,record)=>{if(phase===wanted){json(path.join(root,'checkpoint.json'),{phase,token:record.token});setInterval(()=>{},1000);await new Promise(()=>{});}};
export function fixtureWindows(root){return (op,...args)=>{
  const file=path.join(root,'task.json');
  if(op==='task-info')return fs.existsSync(file)?read(file):{exists:false};
  if(op==='task-register')json(file,fs.readFileSync(args[1]).toString('utf16le').includes('old-task')?read(path.join(root,'old-task.json')):{exists:true,command:path.join(root,'data/launcher/GPTNiang.Start.exe'),arguments:'--supervise'});
  if(op==='task-delete'&&fs.existsSync(file))fs.unlinkSync(file);
  if(op==='shortcut-write')fs.writeFileSync(args[0],'new shortcut');
};}
if(process.argv.includes('--recover')){
  await recoverInstall(path.join(root,'data'),{windows:fixtureWindows(root),stop:async()=>{},phaseHook,resume:false});
}else if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  const dataDir=path.join(root,'data'),target=path.join(root,'program'),migrationToken=randomUUID(),fileSource=path.join(dataDir,'updates',migrationToken),version='1.3.7';
  fs.mkdirSync(target,{recursive:true});fs.mkdirSync(path.join(fileSource,'native'),{recursive:true});
  const personal=personalState(dataDir);json(path.join(root,'personal.json'),personal);
  const previous={appDir:target,dataDir,version:'1.3.6',architecture:'powershell-wpf'};
  json(path.join(target,'package.json'),{name:'gpt-niang-usage',version:'1.3.6'});json(path.join(target,'installation.json'),previous);
  fs.writeFileSync(path.join(target,'old.txt'),'the original program');
  fs.writeFileSync(path.join(root,'startup.lnk'),'old shortcut');
  fs.writeFileSync(path.join(dataDir,'supervisor-pause.json'),'original pause');
  const market=path.join(root,'.agents/plugins/marketplace.json');json(market,{name:'gpt-niang-local',plugins:[]});fs.writeFileSync(market+'.bak','original market backup');
  const task={exists:true,state:4,xml:'old-task',command:path.join(root,'legacy-host.exe'),arguments:'old'};json(path.join(root,'task.json'),task);json(path.join(root,'old-task.json'),task);
  const files={'native/GPTNiang.Start.exe':fs.readFileSync(path.join(app,'native/GPTNiang.Start.exe')),'package.json':Buffer.from(JSON.stringify({name:'gpt-niang-usage',version,architecture:'javascript-electron'})),'new.txt':Buffer.from('new program')};
  for(const [name,content]of Object.entries(files))fs.writeFileSync(path.join(fileSource,name),content);
  json(path.join(fileSource,'integrity.json'),{});
  const plan={target,dataDir,shortcut:path.join(root,'startup.lnk'),marketplaceRoot:root,integrity:{files:Object.fromEntries(Object.entries(files).map(([name,content])=>[name,createHash('sha256').update(content).digest('hex')]))},previous,version,taskName:'isolated-fixture',sid:'fixture',task,nodePath:process.execPath};
  json(path.join(root,'plan.json'),plan);
  const migration={schema:1,root:target,dataDir,source:fileSource,token:migrationToken,version};
  await install(plan,{capturePlugin:()=>null,fileSource,migration,phaseHook,windows:fixtureWindows(root),stop:async()=>{fs.writeFileSync(path.join(dataDir,'stop.flag'),'installer stop');},execute:()=>({status:0,stdout:JSON.stringify({installed:[{pluginId:'gpt-niang-usage@gpt-niang-local',version,installed:true,enabled:true}]})}),verify:async()=>{}});
}
