import fs from 'node:fs';import path from 'node:path';import {createHash} from 'node:crypto';
import {install} from '../../src/install.mjs';
const dir=process.argv[2],source=path.join(dir,'source'),target=path.join(dir,'program'),dataDir=path.join(dir,'data');fs.mkdirSync(path.join(source,'native'),{recursive:true});fs.mkdirSync(dataDir,{recursive:true});
const files={'native/GPTNiang.Start.exe':'launcher-fixture','node_modules/electron/dist/resources/default_app.asar':'raw-asar-installer-fixture'};
for(const [name,content] of Object.entries(files)){const f=path.join(source,name);fs.mkdirSync(path.dirname(f),{recursive:true});fs.writeFileSync(f,content);}
fs.writeFileSync(path.join(source,'integrity.json'),'{}');const hash=v=>createHash('sha256').update(v).digest('hex');
const plan={target,dataDir,shortcut:path.join(dir,'startup.lnk'),marketplaceRoot:dir,integrity:{files:Object.fromEntries(Object.entries(files).map(([name,value])=>[name,hash(value)]))},previous:{},version:'1.3.5',taskName:'fixture',sid:'fixture',task:{exists:false}};
await install(plan,{capturePlugin:()=>null,fileSource:source,stop:async()=>{},windows(){},execute:()=>({status:0,stdout:JSON.stringify({installed:[{pluginId:'gpt-niang-usage@gpt-niang-local',version:'1.3.5',installed:true,enabled:true}]})}),verify:async()=>{}});
fs.writeFileSync(path.join(dir,'result.txt'),fs.readFileSync(path.join(target,'node_modules','electron','dist','resources','default_app.asar')));
