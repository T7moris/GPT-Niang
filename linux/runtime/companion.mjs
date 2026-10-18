import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import readline from 'node:readline';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';
import {atomicJson,resolveCodexExecutable} from '../../gpt-niang-usage/runtime/usage.mjs';
import {requestRefresh} from '../../gpt-niang-usage/runtime/refresh-client.mjs';
import {healthyWorker,readJson} from '../../gpt-niang-usage/runtime/worker-state.mjs';
import {dataDirectory,loadSettings,normalizeSettings,saveSettings,displayWindows} from './settings.mjs';
import {autostartEnabled,setAutostart} from './install.mjs';

process.umask(0o077);
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const dir=dataDirectory();
fs.mkdirSync(dir,{recursive:true,mode:0o700});
const configPath=path.join(dir,'linux-installation.json');
const config={dataDir:dir,nodePath:process.execPath,codexPath:resolveCodexExecutable(process.env.GPT_NIANG_CODEX_PATH)||'codex'};
atomicJson(configPath,config);
let settings=loadSettings(dir), host={}, drag=null, bridge, worker, stopping=false, visible=false, querying=false, lastQuery=0, bridgeRestarts=0;
let snapshot={ok:false,queryOk:false,windows:[],error:'正在读取当前账户额度…'};
const builtIn=JSON.parse(fs.readFileSync(path.join(root,'gpt-niang-usage/assets/quotes.json'),'utf8')).quotes.map(q=>q.text);
const send=data=>{if(!stopping)process.stdout.write(JSON.stringify(data)+'\n');};
const quotes=()=>settings.customQuotes===null?builtIn:settings.customQuotes;
const usage=()=>send({type:'usage',snapshot,windows:displayWindows(snapshot),busy:querying});
const save=()=>{
  settings=normalizeSettings(settings);saveSettings(dir,settings);
  send({type:'settings',settings,quotes:quotes(),autostart:autostartEnabled()});
  bridgeConfig();
};
function bridgeConfig() {
  if(bridge?.stdin.writable)bridge.stdin.write(JSON.stringify({settings,drag})+'\n');
}
function startWorker() {
  if(stopping || worker && worker.exitCode===null)return;
  // Account quota is global. Do not inherit an arbitrary source checkout's
  // project routing/configuration when starting its read-only app server.
  worker=spawn(process.execPath,[path.join(root,'gpt-niang-usage/runtime/watch.mjs'),configPath,String(process.pid)],{cwd:os.homedir(),stdio:['ignore','ignore','pipe']});
  worker.stderr.on('data',()=>{});
  worker.on('error',()=>send({type:'error',error:'无法启动额度后台'}));
}
async function refresh() {
  if(querying || stopping)return;
  querying=true;lastQuery=Date.now();usage();
  try {
    await requestRefresh(config,configPath,{startWorker});
    snapshot=readJson(path.join(dir,'status.json')) || snapshot;
  } catch {send({type:'error',error:'额度查询暂时失败，请重试'});}
  finally {querying=false;usage();}
}
function startBridge() {
  if(stopping)return;
  bridge=spawn(process.env.GPT_NIANG_PYTHON || 'python3',[path.join(root,'linux/runtime/kwin-bridge.py')],{stdio:['pipe','pipe','pipe']});
  bridge.stdin.on('error',()=>{});bridge.stderr.on('data',()=>{});
  const lines=readline.createInterface({input:bridge.stdout});
  lines.on('line',line=>{
    let data;try {data=JSON.parse(line);}catch{return;}
    if(data.type==='host'){host=data.host;send(data);}
    else if(data.type==='bridge'){
      if(data.ready){bridgeRestarts=0;bridgeConfig();}
      send(data);
    }
  });
  bridge.on('error',()=>send({type:'bridge',ready:false,error:'找不到 Python 3 或 KDE D-Bus 支持，请运行 gpt-niang doctor'}));
  bridge.on('exit',()=>{
    lines.close();
    if(stopping)return;
    send({type:'bridge',ready:false,error:'KWin 桥接已断开，正在重连…'});
    const retry=setTimeout(startBridge,Math.min(30000,1000*2**Math.min(bridgeRestarts++,5)));
    retry.unref();
  });
}
const input=readline.createInterface({input:process.stdin});
input.on('line',line=>{
  if(line.length>131072)return;
  let cmd;try{cmd=JSON.parse(line);}catch{return;}
  try {
    if(cmd.command==='settings'){
      const patch=cmd.patch || {};
      settings=normalizeSettings({...settings,...patch,desktop:patch.desktop?{...settings.desktop,...patch.desktop}:settings.desktop,follow:patch.follow?{...settings.follow,...patch.follow}:settings.follow});
      save();
    }else if(cmd.command==='refresh'){void refresh();}
    else if(cmd.command==='presence'){
      const resumed=!visible && cmd.visible;visible=!!cmd.visible;
      if(resumed && Date.now()-lastQuery>60000)void refresh();
    }else if(cmd.command==='dragStart'){
      if(Number.isFinite(cmd.x) && Number.isFinite(cmd.y)){drag={x:cmd.x,y:cmd.y};bridgeConfig();}
    }else if(cmd.command==='dragEnd'){
      if(drag && host.cursor){
        let x=Math.round(host.cursor.x-drag.x),y=Math.round(host.cursor.y-drag.y);
        const w=host.widget;
        if(settings.mode==='follow' && host.target && w){
          const g=host.target.geometry;
          settings.follow={edge:x+w.width/2<g.x+g.width/2?'left':'right',bottom:Math.max(0,g.y+g.height-y-w.height)};
        }else {
          for(const s of host.screens || []){
            const a=s.workArea;
            if(y>=a.y && y<a.y+a.height && w){
              if(Math.abs(x-a.x)<32)x=a.x;
              if(Math.abs(x+w.width-(a.x+a.width))<32)x=a.x+a.width-w.width;
            }
          }
          settings.desktop={x,y};
        }
      }
      drag=null;save();
    }else if(cmd.command==='autostart'){
      setAutostart(cmd.enabled===true,root);save();
    }else if(cmd.command==='quit'){shutdown();}
  }catch {send({type:'error',error:'无法保存设置，请检查用户目录权限'});}
});
function shutdown() {
  if(stopping)return;stopping=true;clearInterval(heartbeat);
  input.close();
  try{bridge?.stdin.end(JSON.stringify({command:'stop'})+'\n');}catch{}
  worker?.kill();
  try {const p=readJson(path.join(dir,'presence.json'));if(p?.pid===process.pid)fs.unlinkSync(path.join(dir,'presence.json'));}catch{}
  setTimeout(()=>{bridge?.kill();process.exit(0);},500).unref();
}
input.on('close',shutdown);
process.on('SIGTERM',shutdown);process.on('SIGINT',shutdown);
send({type:'init',settings,quotes:quotes(),autostart:autostartEnabled()});
startBridge();
const heartbeat=setInterval(()=>{
  try{
    atomicJson(path.join(dir,'presence.json'),{pid:process.pid,at:Date.now(),visible});
    const next=readJson(path.join(dir,'status.json'));
    if(next && JSON.stringify(next)!==JSON.stringify(snapshot)){snapshot=next;usage();}
    if(visible && Date.now()-lastQuery>=60000)void refresh();
    if(visible && !healthyWorker(dir))startWorker();
  }catch{send({type:'error',error:'无法写入挂件状态目录'});}
},1000);
