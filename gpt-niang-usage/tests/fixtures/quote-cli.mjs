// Test-only preload: exercises the real CLI transport/guardian without a model.
import fs from 'node:fs';
import readline from 'node:readline';
import path from 'node:path';
const command=path.basename(process.argv[1]??'');
if(['exec','features','app-server'].includes(command)){
  if(command==='exec' && process.argv.includes('--help')){
    console.log('--ignore-user-config --ignore-rules --ephemeral --output-schema');process.exit(0);
  }
  if(command==='features'){console.log('shell_tool stable true\nplugins stable true\nhooks stable true');process.exit(0);}
  if(command==='app-server'){
    const input=readline.createInterface({input:process.stdin});
    input.on('line',line=>{
      const q=JSON.parse(line);if(q.id===undefined)return;
      let result=q.id===1?{}:q.id===2?{account:{type:process.env.QUOTE_TEST_AUTH??'chatgpt'}}:{config:{model:'configured-test-model',model_provider:'openai'}};
      if(q.method==='model/list')result=q.params.cursor?{data:[{model:'second',displayName:'Second',inputModalities:['text']},{model:'audio',inputModalities:['audio']}],nextCursor:null}:{data:[{model:'first',displayName:'First',isDefault:true,inputModalities:['text']},{model:'hidden',hidden:true}],nextCursor:'next'};
      console.log(JSON.stringify({id:q.id,result}));
    });input.on('close',()=>process.exit(0));
  }
  if(command==='exec'){
    let prompt='';process.stdin.setEncoding('utf8');process.stdin.on('data',chunk=>{prompt+=chunk;});
    process.stdin.on('end',()=>{
      if(process.env.QUOTE_TEST_TRACE)fs.writeFileSync(process.env.QUOTE_TEST_TRACE,JSON.stringify({args:process.argv.slice(2),apiKeyPresent:!!process.env.CODEX_API_KEY,pid:process.pid}));
      if(process.env.QUOTE_TEST_HANG){setInterval(()=>{},1000);return;}
      if(process.env.QUOTE_TEST_TOOL){console.log(JSON.stringify({type:'item.started',item:{type:'command_execution'}}));setInterval(()=>{},1000);return;}
      const output=process.argv[process.argv.indexOf('--output-last-message')+1];
      fs.writeFileSync(output,JSON.stringify({quotes:['模拟的新台词。']}));
      console.log(JSON.stringify({type:'item.completed',item:{type:'agent_message',text:'{"quotes":["模拟的新台词。"]}'}}));
      process.exit(0);
    });
  }
  await new Promise(()=>{});
}
