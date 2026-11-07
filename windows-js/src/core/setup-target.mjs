import path from 'node:path';import {spawnSync} from 'node:child_process';
import {readJson,samePath} from './storage.mjs';import {resolveInstallCli} from './cli.mjs';
import {stableInstallPaths} from './install-paths.mjs';
export function resolveSetupTarget({env=process.env,execute=spawnSync,codexPath=resolveInstallCli(undefined,{env,execute}),read=readJson}={}){
  if(!codexPath)throw Error('未找到 Codex 桌面程序');
  const result=execute(codexPath,['plugin','list','--marketplace','gpt-niang-local','--json'],{windowsHide:true,timeout:30000,encoding:'utf8',env});
  if(result.error||result.status!==0)throw Error('无法确认现有 GPT 娘安装，已停止以保留原设置');
  let catalog;try{catalog=JSON.parse(String(result.stdout).replace(/^\uFEFF/,''));}catch{throw Error('插件安装信息无效');}
  if(!Array.isArray(catalog.installed))throw Error('插件安装信息缺少列表');
  const installed=catalog.installed.filter(row=>row.pluginId==='gpt-niang-usage@gpt-niang-local'&&row.installed===true);
  if(installed.length>1)throw Error('发现多个 GPT 娘安装，请先保留现用版本');
  if(installed.length){
    const target=installed[0].source?.path;
    if(typeof target!=='string'||!path.isAbsolute(target))throw Error('原安装位置无效');
    const config=read(path.join(target,'installation.json')),pkg=read(path.join(target,'package.json'));
    if(pkg?.name!=='gpt-niang-usage'||!path.isAbsolute(config?.dataDir??'')||(config.appDir&&!samePath(config.appDir,target)))throw Error('原安装信息不完整，请先修复原版本；个人设置未改变');
    return {target:path.resolve(target),dataDir:path.resolve(config.dataDir),existing:true};
  }
  return {...stableInstallPaths(env),existing:false};
}
