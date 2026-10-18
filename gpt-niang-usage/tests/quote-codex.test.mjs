import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {fileURLToPath} from 'node:url';
import {createCodexQuoteGenerator,createCodexModelReader} from '../runtime/quote-codex.mjs';
import {generationDefaults} from '../runtime/quote-generation.mjs';
import {atomicJson} from '../runtime/usage.mjs';
const preload=new URL('./fixtures/quote-cli.mjs',import.meta.url).href;
test('model discovery follows pagination and filters hidden/non-text models without a generation',async()=>{
  const read=createCodexModelReader({codexPath:process.execPath},{env:{...process.env,NODE_OPTIONS:'--import='+preload}});
  const result=await read();
  assert.equal(result.model,'configured-test-model');
  assert.deepEqual(result.models.map(row=>row.id),['first','second']);
});
function fixture(t,overrides={}){
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-niang-cli-test-')),trace=path.join(dir,'trace.json');
  t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
  return {trace,generate:createCodexQuoteGenerator({codexPath:process.execPath},{env:{...process.env,NODE_OPTIONS:'--import='+preload,QUOTE_TEST_TRACE:trace,...overrides}})};
}
test('CLI transport reuses model config, isolates instructions/tools and strips API-key env',async t=>{
  const f=fixture(t,{CODEX_API_KEY:'fake-test-key'}),controller=new AbortController();
  const output=await f.generate({settings:generationDefaults,samples:['样例'],signal:controller.signal});
  assert.deepEqual(output,{quotes:['模拟的新台词。']});
  const trace=JSON.parse(fs.readFileSync(f.trace,'utf8'));
  assert.equal(trace.args[trace.args.indexOf('--model')+1],'configured-test-model');
  assert.ok(trace.args.includes('--ignore-user-config'));assert.ok(trace.args.includes('project_doc_max_bytes=0'));
  assert.ok(trace.args.includes('shell_tool'));assert.ok(trace.args.includes('plugins'));assert.equal(trace.apiKeyPresent,false);
});
test('explicit model applies only to this generation',async t=>{
  const f=fixture(t);
  await f.generate({settings:{...generationDefaults,model:'chosen-test-model'},samples:[],signal:new AbortController().signal});
  const trace=JSON.parse(fs.readFileSync(f.trace,'utf8'));
  assert.equal(trace.args[trace.args.indexOf('--model')+1],'chosen-test-model');
});
test('API-key login is rejected before starting a model',async t=>{
  const f=fixture(t,{QUOTE_TEST_AUTH:'apiKey'});
  await assert.rejects(f.generate({settings:generationDefaults,samples:[],signal:new AbortController().signal}),{code:'AUTH_REQUIRED'});
  assert.equal(fs.existsSync(f.trace),false);
});
test('unexpected tools terminate the invocation and reject its output',async t=>{
  const f=fixture(t,{QUOTE_TEST_TOOL:'1'});
  await assert.rejects(f.generate({settings:generationDefaults,samples:[],signal:new AbortController().signal}),{code:'TOOLS_NOT_ALLOWED'});
});
test('cancel kills an in-flight CLI process',async t=>{
  const f=fixture(t,{QUOTE_TEST_HANG:'1'}),controller=new AbortController();
  const running=f.generate({settings:generationDefaults,samples:[],signal:controller.signal});
  const deadline=Date.now()+10000;
  while(!fs.existsSync(f.trace) && Date.now()<deadline)await new Promise(resolve=>setTimeout(resolve,30));
  assert.ok(fs.existsSync(f.trace),'CLI started');const {pid}=JSON.parse(fs.readFileSync(f.trace,'utf8'));
  controller.abort();await assert.rejects(running,{code:'CANCELLED'});
  assert.throws(()=>process.kill(pid,0));
});
test('guardian terminates the CLI when its worker pipe closes unexpectedly',async t=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-niang-guardian-test-')),trace=path.join(dir,'trace.json');
  const guardian=spawn(process.execPath,[fileURLToPath(new URL('../runtime/quote-exec.mjs',import.meta.url))],{windowsHide:true,env:{...process.env,NODE_OPTIONS:'--import='+preload,QUOTE_TEST_TRACE:trace,QUOTE_TEST_HANG:'1'},stdio:['pipe','ignore','ignore']});
  t.after(()=>{if(guardian.exitCode===null)guardian.kill();fs.rmSync(dir,{recursive:true,force:true});});
  guardian.stdin.write(JSON.stringify({cli:process.execPath,args:['exec'],directory:dir,prompt:'test'})+'\n');
  const deadline=Date.now()+10000;
  while(!fs.existsSync(trace) && Date.now()<deadline)await new Promise(resolve=>setTimeout(resolve,30));
  assert.ok(fs.existsSync(trace));const {pid}=JSON.parse(fs.readFileSync(trace,'utf8'));
  const exited=once(guardian,'close');guardian.stdin.end();await exited;
  assert.throws(()=>process.kill(pid,0));
});
test('an existing headless quota worker replenishes for the visible Windows UI',{skip:process.platform!=='win32'},async()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-niang-headless-quotes-'));
  let worker;
  try{
    const configFile=path.join(dir,'installation.json');
    atomicJson(configFile,{appDir:dir,dataDir:dir,codexPath:process.execPath});
    atomicJson(path.join(dir,'assets','quotes.json'),{quotes:['原有台词']});
    atomicJson(path.join(dir,'quote-generation.json'),{...generationDefaults,enabled:true,revision:'enabled'});
    atomicJson(path.join(dir,'presence.json'),{visible:true,codexVisible:true,pid:process.pid,at:Date.now()});
    worker=spawn(process.execPath,[fileURLToPath(new URL('../runtime/watch.mjs',import.meta.url)),configFile,'0'],{windowsHide:true,env:{...process.env,NODE_OPTIONS:'--import='+preload},stdio:'ignore'});
    const stock=path.join(dir,'generated-quotes.json'),deadline=Date.now()+10000;
    while(!fs.existsSync(stock) && Date.now()<deadline)await new Promise(resolve=>setTimeout(resolve,50));
    assert.ok(fs.existsSync(stock),'worker first launched without a GUI still generates for its later UI');
    assert.equal(JSON.parse(fs.readFileSync(stock,'utf8')).quotes[0].text,'模拟的新台词。');
    const exited=once(worker,'exit');fs.writeFileSync(path.join(dir,'stop.flag'),'test');await exited;
  }finally{
    if(worker?.exitCode===null && !worker.signalCode){const exited=once(worker,'exit');worker.kill();await exited;}
    fs.rmSync(dir,{recursive:true,force:true});
  }
});
