import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import {fileURLToPath} from 'node:url';
import {freshness} from './usage.mjs';
import {requestRefresh} from './refresh-client.mjs';
import {pluginVersion} from './metadata.mjs';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const send=m=>process.stdout.write(JSON.stringify(m)+'\n');
const tool={name:'get_codex_usage',description:'自动识别当前 ChatGPT 套餐，读取 Codex 实际返回的额度窗口（如 5 小时、每周、30 天），返回已用、剩余百分比与北京时间重置时间。只读，不创建聊天或调用模型。',inputSchema:{type:'object',properties:{},additionalProperties:false},annotations:{readOnlyHint:true,destructiveHint:false,idempotentHint:true,openWorldHint:true}};
async function handle(m){
  if(!m || typeof m!=='object' || Array.isArray(m) || typeof m.method!=='string'){send({jsonrpc:'2.0',id:null,error:{code:-32600,message:'Invalid Request'}});return;}
  if(m.id===undefined)return;
  try{
    let result;
    switch(m.method){
      case 'initialize': result={protocolVersion:m.params?.protocolVersion??'2024-11-05',capabilities:{tools:{}},serverInfo:{name:'gpt-niang-usage',version:pluginVersion}};break;
      case 'ping':result={};break;
      case 'tools/list':result={tools:[tool]};break;
      case 'tools/call':{
        if(m.params?.name!==tool.name)throw new Error('Unknown tool');
        const configPath=path.join(root,'installation.json');
        const config=JSON.parse(fs.readFileSync(configPath,'utf8').replace(/^\uFEFF/,''));
        const r=await requestRefresh(config,configPath);
        const data={ok:r.ok,queryOk:r.queryOk,source:'Codex 官方订阅额度接口',plan:r.plan,planLabel:r.planLabel,planKnown:r.planKnown,planSource:r.planSource,authType:r.authType,errorCode:r.errorCode,observedAt:r.observedAt?new Date(r.observedAt).toISOString():null,error:r.error,windows:(r.windows??[]).map(w=>({...w,state:freshness(w,r.observedAt),resetBeijing:Number.isFinite(w.resetsAt) && w.resetsAt>0?new Intl.DateTimeFormat('zh-CN',{timeZone:'Asia/Shanghai',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false}).format(new Date(w.resetsAt*1000)):null}))};
        if(r.accountVerified===false)data.accountVerified=false;
        if(r.retryable)data.retryable=true;
        result={content:[{type:'text',text:JSON.stringify(data)}],isError:!r.ok || !r.queryOk};break;
      }
      default:send({jsonrpc:'2.0',id:m.id,error:{code:-32601,message:'Method not found'}});return;
    }
    send({jsonrpc:'2.0',id:m.id,result});
  }catch{send({jsonrpc:'2.0',id:m.id,error:{code:-32603,message:'GPT 娘额度服务暂不可用，请检查本地安装'}});}
}
readline.createInterface({input:process.stdin}).on('line',line=>{
  if(line.length>1024*1024)return;
  try{void handle(JSON.parse(line));}catch{send({jsonrpc:'2.0',id:null,error:{code:-32700,message:'Invalid JSON'}});}
});
