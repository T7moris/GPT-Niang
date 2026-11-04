import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {fileURLToPath} from 'node:url';
import {atomicJson} from '../runtime/usage.mjs';
import {requestRefresh} from '../runtime/refresh-client.mjs';
import {readJson} from '../runtime/worker-state.mjs';

test('the worker exposes a fresh direct quota after routing timeout and clears it on later failure',async()=>{
  const temp=path.resolve(os.tmpdir());
  const prefix=path.join(temp,'gpt-niang-direct-fallback-');
  const dir=fs.mkdtempSync(prefix);
  const worker=fileURLToPath(new URL('../runtime/watch.mjs',import.meta.url));
  const config={dataDir:dir,nodePath:process.execPath,codexPath:process.execPath};
  const configPath=path.join(dir,'installation.json');
  const identity='fixture-workspace-identity';
  const script=[
    "const fs=require('node:fs'),readline=require('node:readline');",
    "const send=(id,value)=>process.stdout.write(JSON.stringify({id,...value})+'\\n');",
    "readline.createInterface({input:process.stdin}).on('line',line=>{const r=JSON.parse(line);",
    "if(r.id===1)send(1,{result:{}});",
    "if(r.id===2)send(2,{error:{code:-32603,message:'workspace routing discovery timed out'}});",
    "if(r.id===3){if(fs.existsSync('fail.flag'))send(3,{error:{code:-32603,message:'quota unavailable'}});",
    `else send(3,{result:{accountId:${JSON.stringify(identity)},rateLimits:{planType:'plus',primary:{windowDurationMins:300,usedPercent:12,resetsAt:null}}}});}`,
    "});"
  ].join('\n');
  let child,mcp;
  try{
    fs.writeFileSync(path.join(dir,'app-server'),script);
    atomicJson(configPath,config);
    const runtimeSource=fileURLToPath(new URL('../runtime/',import.meta.url));
    const runtimeTarget=path.join(dir,'runtime');fs.mkdirSync(runtimeTarget);
    for(const name of fs.readdirSync(runtimeSource))if(name.endsWith('.mjs'))fs.copyFileSync(path.join(runtimeSource,name),path.join(runtimeTarget,name));
    fs.mkdirSync(path.join(dir,'.codex-plugin'));
    fs.copyFileSync(fileURLToPath(new URL('../.codex-plugin/plugin.json',import.meta.url)),path.join(dir,'.codex-plugin','plugin.json'));
    atomicJson(path.join(dir,'status.json'),{ok:true,queryOk:true,accountKey:'old-user',windows:[{remaining:99}],observedAt:1});
    const startWorker=()=>{
      if(child)return;
      const env={...process.env};
      for(const key of Object.keys(env))if(['localappdata','path'].includes(key.toLowerCase()))delete env[key];
      child=spawn(process.execPath,[worker,configPath,'0'],{cwd:dir,env:{...env,LOCALAPPDATA:dir,PATH:dir,GPT_NIANG_CODEX_APP:path.join(dir,'absent.app')},windowsHide:true,stdio:'ignore'});
    };
    const options={startWorker,timeoutMs:8000,pollMs:20};
    const first=await requestRefresh(config,configPath,options);
    assert.equal(first.ok,true);assert.equal(first.queryOk,true);assert.equal(first.windows[0].remaining,88);
    assert.equal(first.accountKey,null);assert.equal(first.clearPrevious,true);assert.equal(first.accountVerified,false);
    const saved=readJson(path.join(dir,'status.json'));
    assert.equal(saved.accountKey,null);assert.equal(JSON.stringify(saved).includes(identity),false);
    mcp=spawn(process.execPath,[path.join(runtimeTarget,'mcp.mjs')],{windowsHide:true,stdio:['pipe','pipe','pipe']});
    let output='';mcp.stdout.on('data',chunk=>{output+=chunk;});
    const closed=once(mcp,'close');
    mcp.stdin.end(JSON.stringify({jsonrpc:'2.0',id:1,method:'tools/call',params:{name:'get_codex_usage'}})+'\n');
    const [exitCode]=await closed;assert.equal(exitCode,0);
    const reply=JSON.parse(output.trim());
    assert.equal(reply.result.isError,false);
    const exposed=JSON.parse(reply.result.content[0].text);
    assert.equal(exposed.accountVerified,false);assert.equal(exposed.windows[0].remaining,88);
    assert.equal(JSON.stringify(exposed).includes(identity),false);
    fs.writeFileSync(path.join(dir,'fail.flag'),'fail');
    const second=await requestRefresh(config,configPath,options);
    assert.equal(second.ok,false);assert.equal(second.queryOk,false);assert.deepEqual(second.windows,[]);
    assert.deepEqual(readJson(path.join(dir,'status.json')).windows,[]);
  } finally {
    if(mcp && mcp.exitCode===null && mcp.signalCode===null){const exited=once(mcp,'exit');mcp.kill();await exited;}
    if(child && child.exitCode===null && child.signalCode===null){const exited=once(child,'exit');child.kill();await exited;}
    const resolved=path.resolve(dir);
    assert.equal(path.dirname(resolved),temp);
    assert.ok(resolved.startsWith(prefix) && path.basename(resolved).startsWith('gpt-niang-direct-fallback-'));
    fs.rmSync(resolved,{recursive:true,force:true});
  }
});
