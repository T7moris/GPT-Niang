import {resolveSetupTarget} from './core/setup-target.mjs';
import path from 'node:path';import {spawn,spawnSync} from 'node:child_process';
async function main(){
 const explicit=process.argv.includes('--target'),target=explicit?null:resolveSetupTarget();
 if(process.argv.includes('--open')||process.argv.includes('--disable')||process.argv.includes('--uninstall')){
  if(!target?.existing)throw Error('请先运行安装GPT娘.cmd 完成安装');
  if(process.argv.includes('--check')){console.log(JSON.stringify({ok:true,checkOnly:true,...target}));return;}
  if(process.argv.includes('--open')){
   const child=spawn(path.join(target.target,'native','GPTNiang.Start.exe'),[],{cwd:target.target,windowsHide:true,detached:true,stdio:'ignore'});
   await new Promise((resolve,reject)=>{child.once('spawn',resolve);child.once('error',reject);});child.unref();return;
  }
  const result=spawnSync(path.join(target.target,'node_modules','electron','dist','electron.exe'),[path.join(target.target,'src','install.mjs'),process.argv.includes('--uninstall')?'--uninstall':'--disable','--target',target.target,'--data-dir',target.dataDir],{windowsHide:true,encoding:'utf8',env:{...process.env,ELECTRON_RUN_AS_NODE:'1'}});
  if(result.error||result.status!==0)throw Error(String(result.stderr||result.error?.message||'停用未完成').trim());
  console.log('已停用，个人数据已保留。');return;
 }
 if(target)process.argv.push('--target',target.target,'--data-dir',target.dataDir);
 const {preflight,install}=await import('./install.mjs'),plan=preflight();
 if(process.argv.includes('--check')){console.log(JSON.stringify({ok:true,checkOnly:true,target:plan.target,dataDir:plan.dataDir,version:plan.version,existing:target?.existing}));return;}
 console.log('正在安装 GPT 娘 JavaScript 架构 Beta 测试版。');
 const result=await install(plan);if(!result.ok)throw Error('安装未完成');
 console.log('安装完成，原有个人设置已保留。');
}
void main().catch(error=>{console.error(error.message);process.exitCode=1;});
