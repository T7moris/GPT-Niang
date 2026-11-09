import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {requestRestart,runRestart,waitForRestart,validateRestart} from './core/restart.mjs';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..'),args=process.argv.slice(2);
try{
  if(args[0]==='--restart-helper')await runRestart(root,args[1]);
  else if(args[0]==='--check'){const config=validateRestart(root);console.log(JSON.stringify({ok:true,root:config.appDir,dataDir:config.dataDir}));}
  else{
    const request=await requestRestart(root),result=await waitForRestart(request.dataDir,request.token);
    if(!result.ok)throw Error(result.error);console.log('GPT 娘已重启，个人设置已保留。');
  }
}catch(error){console.error(error.message);process.exitCode=1;}
