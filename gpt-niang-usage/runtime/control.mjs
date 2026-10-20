import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {atomicJson} from './usage.mjs';
import {requestRefresh} from './refresh-client.mjs';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const configPath=path.join(root,'installation.json');
const config=JSON.parse(fs.readFileSync(configPath,'utf8').replace(/^\uFEFF/,''));
const command=process.argv[2]??'status';
if(command==='query'){
  const result=await requestRefresh(config,configPath);
  console.log(JSON.stringify(result));process.exitCode=result.queryOk && result.ok?0:1;
}else if(command==='show' || command==='quote' || command==='menu' || command==='characters' || command==='close-menu' || command==='music-on' || command==='music-off'){
  atomicJson(path.join(config.dataDir,'display-request.json'),{mode:command==='show'?'quota':command,at:Date.now(),nonce:crypto.randomUUID()});
  console.log('已请求显示'+(command==='show'?'额度':command==='quote'?'语录':command==='characters'?'形象图库':'设置'));
}else if(command==='stop'){
  fs.writeFileSync(path.join(config.dataDir,'stop.flag'),'stop');console.log('已请求退出 GPT 娘');
}else if(command==='status'){
  let runtime=null,quota=null,presence=null;
  try{runtime=JSON.parse(fs.readFileSync(path.join(config.dataDir,'runtime.json'),'utf8').replace(/^\uFEFF/,''));}catch{}
  try{quota=JSON.parse(fs.readFileSync(path.join(config.dataDir,'status.json'),'utf8').replace(/^\uFEFF/,''));}catch{}
  try{presence=JSON.parse(fs.readFileSync(path.join(config.dataDir,'presence.json'),'utf8').replace(/^\uFEFF/,''));}catch{}
  console.log(JSON.stringify({runtime,quota,presence}));
}else throw new Error('Unknown command');
