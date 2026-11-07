import path from 'node:path';
import {samePath} from './storage.mjs';

export function resolveLauncherBinding({exists,binding,previous,target,dataDir,sid,launcherPath,task,link}) {
  const expected={appDir:target,dataDir,sid};
  if(exists){
    if(!samePath(binding?.appDir,target)||!samePath(binding?.dataDir,dataDir)||binding?.sid!==sid)throw Error('独立启动器绑定不匹配');
    return {value:binding,recovered:false};
  }
  const taskOwn=task?.exists&&samePath(task.command,launcherPath)&&task.arguments==='--supervise'&&task.actions===1&&task.level===0&&task.logon===3&&(task.sid??task.user)===sid&&samePath(task.directory,path.dirname(launcherPath));
  const linkOwn=link?.exists&&samePath(link.target,launcherPath)&&!link.arguments&&samePath(link.directory,path.dirname(launcherPath));
  // The normal preflight additionally checks the original program identity,
  // every task action and the shortcut. Do not infer ownership from a folder name.
  if(!samePath(previous?.appDir,target)||!samePath(previous?.dataDir,dataDir)||previous?.sid!==sid||!samePath(previous?.launcherPath,launcherPath)||previous?.candidate||!(taskOwn||linkOwn))throw Error('启动器绑定缺失，且原安装身份不足以安全恢复');
  return {value:expected,recovered:true};
}
export function resolveLegacyLauncherBinding({exists,binding,previous,target,dataDir,sid,agent,task}) {
  if(exists){
    if(!samePath(binding?.appDir,target)||!samePath(binding?.dataDir,dataDir)||binding?.sid!==sid)throw Error('旧启动器绑定不匹配');
    return {value:binding,recovered:false};
  }
  if(!samePath(previous?.appDir,target)||!samePath(previous?.dataDir,dataDir)||!samePath(previous?.updateAgent,agent)||(previous?.sid&&previous.sid!==sid)||previous?.candidate||!task?.exists||task.actions!==1||task.level!==0||task.logon!==3||(task.sid??task.user)!==sid)throw Error('旧绑定缺失，且原安装身份不足以安全恢复');
  return {value:{appDir:target,dataDir,sid},recovered:true};
}
