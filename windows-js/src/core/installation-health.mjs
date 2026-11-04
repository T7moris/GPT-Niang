import path from 'node:path';
import {processIdentity,sameProcess} from '../../runtime/process-identity.mjs';
const same=(a,b)=>typeof a==='string'&&typeof b==='string'&&path.resolve(a).toLowerCase()===path.resolve(b).toLowerCase();
export function installationHealthy({root,version,runtime,supervisor,settings,startedAt=0,now=Date.now(),inspect=processIdentity,electronPath=path.join(root,'node_modules','electron','dist','electron.exe'),nodePath=electronPath,requireSupervisor=false}){
  const fresh=at=>Number.isFinite(at)&&at>=startedAt&&at<=now&&now-at<6000;
  const identified=(record,exe)=>{
    const identity=inspect(record?.pid);
    return identity&&same(identity.path,exe)&&identity.startedAt>=startedAt&&sameProcess(record,identity);
  };
  const electron=electronPath;
  const validRuntime=runtime?.architecture==='javascript-electron'&&same(runtime.appDir,root)&&runtime.version===version&&runtime.widget>0&&runtime.rendererReady===true&&fresh(runtime.at)&&identified(runtime,electron);
  // Explicitly visible or desktop installations must have an initialized GUI.
  if(!supervisor)return !requireSupervisor&&Boolean(validRuntime);
  if(!same(supervisor.appDir,root)||supervisor.version!==version||!fresh(Date.parse(supervisor.at))||typeof supervisor.paused!=='boolean'||typeof supervisor.widgetRunning!=='boolean'||!Number.isInteger(supervisor.visibleWindows)||supervisor.visibleWindows<0||!identified(supervisor,nodePath))return false;
  if(supervisor.paused||(settings?.followHost!==false&&supervisor.visibleWindows===0))return true;
  return Boolean(supervisor.widgetRunning&&validRuntime);
}
export function assertPluginRegistration(result,version,{enabled=true}={}){
  if(result.error||result.status!==0)throw Error('无法确认 Codex 插件注册状态');
  let catalog;try{catalog=JSON.parse(String(result.stdout).replace(/^\uFEFF/,''));}catch{throw Error('Codex 插件状态不是有效 JSON');}
  const matches=(catalog.installed??[]).filter(p=>p.pluginId==='gpt-niang-usage@gpt-niang-local'&&p.version===version&&p.installed===true&&p.enabled===enabled);
  if(matches.length!==1)throw Error('Codex 未报告状态一致的唯一当前版本 GPT 娘插件');
}
