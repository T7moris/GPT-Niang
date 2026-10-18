// Own the model process separately from watch.mjs. If the worker is forcibly
// killed, its stdin pipe closes and this guardian terminates the CLI tree.
import readline from 'node:readline';
import {spawn} from 'node:child_process';
import {stopProcessTree} from './quote-codex.mjs';

let child=null,started=false,exiting=false,rpc=false;
function stop(){
  if(exiting)return;exiting=true;
  stopProcessTree(child);
  process.exit(1);
}
process.on('SIGTERM',stop);process.on('SIGINT',stop);process.on('exit',()=>stopProcessTree(child));
process.stdout.on('error',stop);
const input=readline.createInterface({input:process.stdin});
input.on('close',stop);
input.on('line',line=>{
  if(started){if(rpc){try{child.stdin.write(line+'\n');}catch{stop();}}return;}started=true;
  try{
    const options=JSON.parse(line),{cli,args,directory,prompt}=options;rpc=options.rpc===true;
    child=spawn(cli,args,{cwd:directory,windowsHide:true,stdio:['pipe','pipe','ignore']});
    child.on('error',stop);child.stdin.on('error',stop);
    child.stdout.pipe(process.stdout);
    child.on('close',code=>{exiting=true;input.close();process.exitCode=code??1;process.stdin.destroy();});
    if(!rpc)child.stdin.end(prompt??'','utf8');
  }catch{stop();}
});
