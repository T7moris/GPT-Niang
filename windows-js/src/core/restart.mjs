import fs from 'node:fs';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {readJson,writeJson,samePath} from './storage.mjs';
import {claimProgramChange,ownerAlive} from './update-transaction.mjs';
import {stopProgramOwners} from './install-recovery.mjs';
import {installationHealthy} from './installation-health.mjs';

const terminal=new Set(['committed','rolled-back']);
const uuid=value=>typeof value==='string'&&/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(value);
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const flags=['stop.flag','supervisor-stop.flag','supervisor-disabled.flag','supervisor-pause.json'];
const readFlags=dataDir=>new Map(flags.map(name=>{const file=path.join(dataDir,name);return [name,fs.existsSync(file)?fs.readFileSync(file):null];}));
const flagState=values=>Object.fromEntries([...values].map(([name,value])=>[name,value?.toString('base64')??null]));
const xml=value=>String(value).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;');
const ownArguments=token=>'--restart-helper '+token;
function currentSid(){
  const value=execFileSync('whoami.exe',['/user','/fo','csv','/nh'],{windowsHide:true,encoding:'utf8'}).match(/S-\d-(?:\d+-)+\d+/)?.[0];
  if(!value)throw Error('无法确认当前 Windows 用户');return value;
}
export function windowsRestartSetup(root){return (op,...args)=>{
  const data=JSON.parse(execFileSync(path.join(root,'native/GPTNiang.Setup.exe'),[op,...args],{windowsHide:true,encoding:'utf8',timeout:15000}).replace(/^\uFEFF/,''));
  if(data.ok!==true)throw Error(data.error||'Windows 启动设置未完成');return data;
};}
function physical(directory){
  if(!path.isAbsolute(directory??'')||path.resolve(directory)===path.dirname(path.resolve(directory))||!samePath(fs.realpathSync(directory),directory))throw Error('重启目录无效或包含文件链接');
}
function pending(dataDir){
  for(const name of ['javascript-install-journal.json','javascript-update-journal.json']){
    const file=path.join(dataDir,name);if(fs.existsSync(file)&&!terminal.has(readJson(file)?.phase))throw Error('安装或更新尚未完成，请稍后重启');
  }
}
function matchesTask(task,config,args){return task?.exists&&samePath(task.command,config.launcherPath)&&task.arguments===args&&samePath(task.directory,path.dirname(config.launcherPath))&&task.actions===1&&task.level===0&&task.logon===3&&(task.sid??task.user)===config.sid;}
export function validateRestart(root,{sid=currentSid(),windows=windowsRestartSetup(root)}={}){
  physical(root);
  const config=readJson(path.join(root,'installation.json')),pkg=readJson(path.join(root,'package.json'));
  if(pkg?.name!=='gpt-niang-usage'||pkg.architecture!=='javascript-electron'||!samePath(config?.appDir,root)||config?.candidate||config?.architecture!=='javascript-electron'||config.version!==pkg.version||config.sid!==sid||config.taskName!=='GPT Niang Usage - '+sid)throw Error('重启入口不属于当前用户的已安装 GPT 娘');
  physical(config.dataDir);
  const relative=path.relative(root,config.dataDir),reverse=path.relative(config.dataDir,root);
  if(!relative||!reverse||(!relative.startsWith('..'+path.sep)&&!path.isAbsolute(relative))||(!reverse.startsWith('..'+path.sep)&&!path.isAbsolute(reverse)))throw Error('程序与个人目录不能重叠');
  if(!samePath(config.launcherPath,path.join(config.dataDir,'launcher/GPTNiang.Start.exe'))||!fs.statSync(config.launcherPath).isFile())throw Error('独立启动器位置不匹配');
  const binding=readJson(path.join(config.dataDir,'launcher/launcher.json'));
  if(!samePath(binding?.appDir,root)||!samePath(binding?.dataDir,config.dataDir)||binding?.sid!==sid)throw Error('独立启动器绑定不匹配');
  if(!matchesTask(windows('task-info',config.taskName),config,'--supervise'))throw Error('守护任务不属于本安装，未停止任何程序');
  pending(config.dataDir);return config;
}
async function approveRestart(config,token){
  const runtime=readJson(path.join(config.dataDir,'runtime.json'));
  if(!runtime||!ownerAlive(runtime.pid,runtime.processStartedTicks))return null;
  if(!samePath(runtime.appDir,config.appDir))throw Error('另一个挂件正在使用该数据目录');
  const at=Date.now(),file=path.join(config.dataDir,'restart-check-result.json');
  writeJson(path.join(config.dataDir,'display-request.json'),{mode:'restart-check',nonce:token,at},{backup:false});
  while(Date.now()-at<4000){
    const reply=readJson(file);
    if(reply?.token===token&&reply.pid===runtime.pid&&reply.at>=at){
      if(!reply.ok)throw Error(reply.error||'请先保存并关闭编辑窗口');
      return {pid:runtime.pid,ticks:runtime.processStartedTicks,at:reply.at};
    }
    await wait(50);
  }
  throw Error('挂件未响应重启检查，未停止任何程序');
}
function helperXml(config,token){return '<?xml version="1.0" encoding="UTF-16"?><Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Principals><Principal id="CurrentUser"><UserId>'+xml(config.sid)+'</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals><Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><ExecutionTimeLimit>PT1M</ExecutionTimeLimit></Settings><Actions Context="CurrentUser"><Exec><Command>'+xml(config.launcherPath)+'</Command><Arguments>'+ownArguments(token)+'</Arguments><WorkingDirectory>'+xml(path.dirname(config.launcherPath))+'</WorkingDirectory></Exec></Actions></Task>';}
function saveResult(config,token,data){writeJson(path.join(config.dataDir,'restart-result.json'),{token,...data,at:Date.now()},{backup:false});}
const preparing=new Map();
export function requestRestart(root,options={}){
  const key=path.resolve(root).toLowerCase();if(preparing.has(key))return preparing.get(key);
  const request=prepareRestart(root,options);preparing.set(key,request);
  void request.then(()=>preparing.delete(key),()=>preparing.delete(key));return request;
}
async function prepareRestart(root,{windows=windowsRestartSetup(root),sid=currentSid(),approve=approveRestart}={}){
  const config=validateRestart(root,{windows,sid}),release=claimProgramChange(config.dataDir);
  if(!release)throw Error('另一个安装、更新或重启正在准备，请稍后重试');
  const taskName='GPT Niang Restart - '+sid,requestFile=path.join(config.dataDir,'restart-request.json'),taskFile=path.join(config.dataDir,'restart-task.xml');
  let token=randomUUID(),registered=false;
  try{
    const previous=readJson(requestFile),oldTask=windows('task-info',taskName),last=readJson(path.join(config.dataDir,'restart-result.json'));
    if(oldTask.exists){
      if(!uuid(previous?.token)||!samePath(previous.root,root)||previous.sid!==sid||!matchesTask(oldTask,config,ownArguments(previous.token)))throw Error('已有重启任务不属于本安装');
      if(Date.now()-previous.at<60000&&last?.token!==previous.token)return previous;
      if(oldTask.state===4)throw Error('上一轮重启正在收尾，请稍后重试');
      windows('task-delete',taskName);
    }
    // Capture intent before awaiting the GUI or scheduling the helper. A later
    // exit/disable/resume belongs to the user and must cancel this request.
    const requestedFlags=flagState(readFlags(config.dataDir)),approved=await approve(config,token);
    validateRestart(root,{windows,sid});
    const record={schema:1,root:config.appDir,dataDir:config.dataDir,sid,version:config.version,taskName,token,approved,flagState:requestedFlags,at:Date.now()};
    writeJson(requestFile,record,{backup:false});
    fs.writeFileSync(taskFile,Buffer.concat([Buffer.from([255,254]),Buffer.from(helperXml(config,token),'utf16le')]));
    windows('task-register',taskName,taskFile,sid);registered=true;
    if(!matchesTask(windows('task-info',taskName),config,ownArguments(token)))throw Error('重启任务校验失败');
    windows('task-start',taskName);return record;
  }catch(error){
    saveResult(config,token,{ok:false,error:error.message});
    if(registered&&matchesTask(windows('task-info',taskName),config,ownArguments(token)))try{windows('task-delete',taskName);}catch{}
    throw error;
  }finally{try{fs.unlinkSync(taskFile);}catch{}release();}
}
async function verifyRestart(config,startedAt){
  const deadline=Date.now()+25000;
  do{
    if(installationHealthy({root:config.appDir,version:config.version,runtime:readJson(path.join(config.dataDir,'runtime.json')),supervisor:readJson(path.join(config.dataDir,'supervisor-status.json')),settings:readJson(path.join(config.dataDir,'settings.json')),electronPath:config.electronPath,nodePath:config.electronPath,startedAt,requireSupervisor:true}))return;
    await wait(100);
  }while(Date.now()<deadline);
  throw Error('重启后挂件或守护进程未通过检查');
}
export async function runRestart(root,token,options={}){
  try{return await performRestart(root,token,options);}catch(error){
    // A rejected preflight must reach the waiting menu/CMD as well. Only touch
    // the helper whose exact launcher, token and current-user binding match.
    try{
      const config=readJson(path.join(root,'installation.json')),sid=options.sid??currentSid(),windows=options.windows??windowsRestartSetup(root);
      if(config?.sid===sid&&samePath(config.appDir,root)&&uuid(token)&&samePath(config.launcherPath,path.join(config.dataDir,'launcher/GPTNiang.Start.exe'))){
        physical(root);physical(config.dataDir);
        const request=readJson(path.join(config.dataDir,'restart-request.json')),taskName='GPT Niang Restart - '+sid;
        if(request?.token===token&&samePath(request.root,root)&&request.sid===sid&&matchesTask(windows('task-info',taskName),config,ownArguments(token))){saveResult(config,token,{ok:false,error:error.message});windows('task-delete',taskName);}
      }
    }catch{}
    throw error;
  }
}
async function performRestart(root,token,{windows=windowsRestartSetup(root),sid=currentSid(),stop=stopProgramOwners,verify=verifyRestart}={}){
  const config=validateRestart(root,{windows,sid}),request=readJson(path.join(config.dataDir,'restart-request.json'));
  if(!uuid(token)||request?.token!==token||request.schema!==1||request.sid!==sid||!samePath(request.root,root)||!samePath(request.dataDir,config.dataDir)||request.version!==config.version||Date.now()-request.at<0||Date.now()-request.at>60000)throw Error('重启请求已失效');
  const taskName='GPT Niang Restart - '+sid;
  if(request.taskName!==taskName||!matchesTask(windows('task-info',taskName),config,ownArguments(token)))throw Error('重启任务身份不匹配');
  let release,stopped=false;
  for(let n=0;n<20&&!(release=claimProgramChange(config.dataDir));n++)await wait(25);
  if(!release){saveResult(config,token,{ok:false,error:'安装或更新正在进行，未执行重启'});if(matchesTask(windows('task-info',taskName),config,ownArguments(token)))windows('task-delete',taskName);return;}
  let original;
  const removedFlags=new Set();
  try{
    validateRestart(root,{windows,sid});
    original=readFlags(config.dataDir);
    const currentFlags=flagState(original);
    if(flags.some(name=>currentFlags[name]!==request.flagState?.[name]))throw Error('停止或暂停状态发生变化，已保留外部操作');
    const runtime=readJson(path.join(config.dataDir,'runtime.json'));
    if(runtime&&ownerAlive(runtime.pid,runtime.processStartedTicks)&&(!request.approved||request.approved.pid!==runtime.pid||String(request.approved.ticks)!==String(runtime.processStartedTicks)||Date.now()-request.approved.at>10000))throw Error('挂件状态已改变，请重新发起重启');
    stopped=true;
    await stop({root:config.appDir,dataDir:config.dataDir,token,stopTask:()=>{if(!matchesTask(windows('task-info',config.taskName),config,'--supervise'))throw Error('守护任务在重启前发生变化');windows('task-stop',config.taskName);}});
    for(const name of flags){
      const file=path.join(config.dataDir,name),current=fs.existsSync(file)?fs.readFileSync(file):null;
      const expected=['stop.flag','supervisor-stop.flag'].includes(name)?Buffer.from(token):original.get(name);
      if(current?.toString('base64')!==expected?.toString('base64'))throw Error('停止或暂停状态发生变化，已保留外部操作');
      if(current){fs.unlinkSync(file);removedFlags.add(name);}
    }
    if(!matchesTask(windows('task-info',config.taskName),config,'--supervise'))throw Error('守护任务在重启时发生变化');
    const startedAt=Date.now();windows('task-start',config.taskName);await verify(config,startedAt);
    saveResult(config,token,{ok:true});
  }catch(error){
    if(stopped){
      for(const [name,value]of original){
        const file=path.join(config.dataDir,name),current=fs.existsSync(file)?fs.readFileSync(file):null;
        const ownStop=['stop.flag','supervisor-stop.flag'].includes(name)&&current?.toString()===token;
        if(!ownStop&&!(removedFlags.has(name)&&current===null))continue;
        if(value)fs.writeFileSync(file,value);else if(current)fs.unlinkSync(file);
      }
      try{const task=windows('task-info',config.taskName);if(matchesTask(task,config,'--supervise')&&task.state!==4)windows('task-start',config.taskName);}catch{}
    }
    saveResult(config,token,{ok:false,error:error.message});throw error;
  }finally{
    try{
      if(matchesTask(windows('task-info',taskName),config,ownArguments(token)))windows('task-delete',taskName);
    }catch(error){const result=readJson(path.join(config.dataDir,'restart-result.json'));if(result?.token===token)try{saveResult(config,token,{...result,cleanupError:error.message});}catch{}}
    finally{release();}
  }
}
export async function waitForRestart(dataDir,token,{timeoutMs=45000}={}){
  const start=Date.now();while(Date.now()-start<timeoutMs){const value=readJson(path.join(dataDir,'restart-result.json'));if(value?.token===token)return value;await wait(100);}
  throw Error('重启未及时完成，请查看后台状态后重试');
}
export const restartControl={request:requestRestart,wait:waitForRestart};
