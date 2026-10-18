import fs from 'node:fs';
import path from 'node:path';
import {spawnSync,spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {resolveCodexExecutable} from '../../gpt-niang-usage/runtime/usage.mjs';
import {dataDirectory} from './settings.mjs';
import {install,uninstall,setAutostart} from './install.mjs';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
let savedRuntime={};
try{savedRuntime=JSON.parse(fs.readFileSync(path.join(root,'linux/.runtime-paths.json'),'utf8'));}catch{}
if(!process.env.GPT_NIANG_CODEX_PATH && typeof savedRuntime.codexPath==='string')process.env.GPT_NIANG_CODEX_PATH=savedRuntime.codexPath;
const qml=path.join(root,'linux.qml');
const command=process.argv[2] || 'start';
function find(name) {
  for(const dir of (process.env.PATH || '').split(path.delimiter)){
    if(!dir)continue;
    const candidate=path.join(dir,name);
    try{fs.accessSync(candidate,fs.constants.X_OK);if(fs.statSync(candidate).isFile())return candidate;}catch{}
  }
  for(const dir of [path.join(process.env.HOME || '','.local/bin'),'/usr/bin','/usr/local/bin']){
    const candidate=path.join(dir,name);try{fs.accessSync(candidate,fs.constants.X_OK);return candidate;}catch{}
  }
}
const qs=process.env.GPT_NIANG_QUICKSHELL || find('quickshell') || find('qs');
function ipc(method,...args) {
  if(!qs)throw new Error('未找到 Quickshell；请运行 doctor');
  return spawnSync(qs,['ipc','-p',qml,'call','pet',method,...args],{encoding:'utf8',timeout:5000});
}
function doctor() {
  let ok=true;
  const check=(name,works,detail)=>{if(!works)ok=false;console.log((works?'[OK] ':'[缺少] ')+name+(detail?' — '+detail:''));};
  check('Node.js >=20',Number(process.versions.node.split('.')[0])>=20,process.version);
  const version=qs?spawnSync(qs,['--version'],{encoding:'utf8',timeout:5000}):null;
  const match=(version?.stdout || '').match(/Quickshell (\d+)\.(\d+)\.(\d+)/);
  const usable=match && (Number(match[1])>0 || Number(match[2])>2 || Number(match[2])===2 && Number(match[3])>=1);
  check('Quickshell >=0.2.1',!!usable,version?.stdout?.trim() || 'https://quickshell.org/docs/v0.3.0/guide/install-setup/');
  if(qs){
    const headless={...process.env,QT_QPA_PLATFORM:'offscreen',QT_QUICK_BACKEND:'software',QS_DISABLE_FILE_WATCHER:'1',XDG_SESSION_TYPE:'offscreen'};
    delete headless.WAYLAND_DISPLAY;delete headless.DISPLAY;
    const imports=spawnSync(qs,['--path',path.join(root,'linux/doctor.qml')],{encoding:'utf8',timeout:10000,env:headless});
    const passed=imports.status===0 && (imports.stdout+imports.stderr).includes('GPT_NIANG_QML_OK');
    check('Qt Quick Controls / Multimedia',passed,'QML 依赖加载检查');
    if(!passed)console.log((imports.stderr || imports.stdout || imports.error?.message || '').trim().split('\n').slice(-5).join('\n'));
  }
  const py=process.env.GPT_NIANG_PYTHON || (fs.existsSync('/usr/bin/python3')?'/usr/bin/python3':'python3');
  const python=spawnSync(py,['-c','import dbus,gi; from gi.repository import GLib'],{encoding:'utf8'});
  check('Python D-Bus / GLib',python.status===0,'Fedora: python3-dbus python3-gobject；Debian: python3-dbus python3-gi；Arch: python-dbus python-gobject');
  const kwin=spawnSync(py,['-c','import dbus; assert dbus.SessionBus().name_has_owner("org.kde.KWin")'],{encoding:'utf8'});
  check('KWin 会话 D-Bus',kwin.status===0,process.env.XDG_SESSION_TYPE || '未知会话');
  check('flock',!!find('flock'),'util-linux');
  const codex=resolveCodexExecutable(process.env.GPT_NIANG_CODEX_PATH);
  let codexReady=false;try{if(codex){fs.accessSync(codex,fs.constants.X_OK);codexReady=fs.statSync(codex).isFile();}}catch{}
  check('Codex CLI',codexReady,codex || '通过 GPT_NIANG_CODEX_PATH 指定桌面应用附带的 CLI');
  console.log('数据目录：'+dataDirectory());
  return ok;
}
try {
  if(command==='doctor'){process.exitCode=doctor()?0:1;}
  else if(command==='install'){
    if(!doctor())throw new Error('请先补齐以上依赖，再执行 install');
    console.log('已安装启动入口：'+install(root,{autostart:process.argv.includes('--autostart')}));
  }else if(command==='uninstall'){
    if(qs)ipc('quit');uninstall(root);console.log('已移除启动入口与自启动，偏好和源码保留。');
  }else if(command==='autostart'){
    if(!['on','off'].includes(process.argv[3]))throw new Error('用法：gpt-niang autostart on|off');
    setAutostart(process.argv[3]==='on',root);console.log('登录启动已'+(process.argv[3]==='on'?'开启':'关闭'));
  }else if(['status','refresh','stop','quote','show','settings','mode','scale'].includes(command)){
    if(command==='settings' && ipc('status').status!==0){
      const child=spawn(path.join(root,'linux/gpt-niang'),['start'],{detached:true,stdio:'ignore'});child.unref();
      for(let i=0;i<30;i++){
        await new Promise(r=>setTimeout(r,200));
        if(ipc('settings').status===0)process.exit(0);
      }
      throw new Error('挂件启动失败，请运行 gpt-niang start 查看日志');
    }
    const method={stop:'quit',mode:'setMode',scale:'setScale',show:'showQuota'}[command] || command;
    const args=['mode','scale'].includes(command)?[process.argv[3] || '']:[];
    const result=ipc(method,...args);
    if(result.status!==0)throw new Error(result.stderr?.trim() || '挂件未运行，请先执行 gpt-niang start');
    if(result.stdout?.trim())console.log(result.stdout.trim());
    if(command==='stop'){
      for(let i=0;i<15;i++){
        await new Promise(r=>setTimeout(r,200));
        if(ipc('status').status!==0)break;
      }
    }
  }else if(command==='start'){
    if(!qs)throw new Error('未找到 Quickshell；请运行 gpt-niang doctor');
    const existing=ipc('showQuota');
    if(existing.status===0)process.exit(0);
    // Keep an outer kernel lock across source/installed launch paths.
    fs.mkdirSync(dataDirectory(),{recursive:true,mode:0o700});
    const child=spawn(find('flock') || 'flock',['--nonblock',path.join(dataDirectory(),'kde-gui.lock'),qs,'--no-duplicate','--path',qml],{stdio:'inherit',env:{...process.env,GPT_NIANG_NODE:process.execPath,GPT_NIANG_PYTHON:process.env.GPT_NIANG_PYTHON || '/usr/bin/python3',QS_DISABLE_FILE_WATCHER:process.argv.includes('--dev')?'0':'1'}});
    child.on('error',error=>{console.error(error.message);process.exitCode=1;});
    for(const sig of ['SIGTERM','SIGINT'])process.on(sig,()=>child.kill(sig));
    child.on('exit',code=>{process.exitCode=code || 0;});
  }else {
    console.log('gpt-niang start | settings | status | refresh | show | quote | stop\n  mode desktop|follow | scale 0.6..2.5 | doctor | install [--autostart]\n  autostart on|off | uninstall');
  }
}catch(error){console.error(error.message);process.exitCode=1;}
