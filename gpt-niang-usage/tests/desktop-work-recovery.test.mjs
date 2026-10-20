import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {EventEmitter} from 'node:events';
import {PassThrough, Writable} from 'node:stream';
import {captureDesktopWorkContext, desktopContextRelayFile, DesktopAppStatusClient, DesktopWorkTracker, workStatus} from '../runtime/desktop-work-state.mjs';

const caller='00000000-0000-4000-8000-000000000001';
const pipe='\\\\.\\pipe\\gpt-niang-recovery-test';
async function fixture(run) {
  const home=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-work-recovery-'));
  const dataDir=path.join(home,'state');
  fs.writeFileSync(path.join(home,'installation.json'),JSON.stringify({dataDir}));
  const server=path.join(home,'plugins/cache/openai-bundled/codex-app-tools/1.0.0/server.mjs');
  fs.mkdirSync(path.dirname(server),{recursive:true});fs.writeFileSync(server,'// MCP fixture');
  try {await run({home,dataDir});}
  finally {fs.rmSync(home,{recursive:true,force:true});fs.rmSync(desktopContextRelayFile(dataDir),{force:true});}
}
function protocol({maximum,structured=false,hang=false}={}) {
  const children=[],calls=[],launches=[];
  function spawnProcess(binary,args,options) {
    launches.push({binary,args,options});
    const child=new EventEmitter();child.stdout=new PassThrough();child.stderr=new PassThrough();
    child.stdin=new Writable({write(chunk,encoding,done){
      const message=JSON.parse(chunk.toString());done();if(message.id===undefined)return;
      calls.push(message);
      let result={};
      if(message.method==='tools/list')result={tools:[{name:'list_threads',inputSchema:{properties:{limit:{maximum}}}},{name:'read_thread'}]};
      if(message.method==='tools/call'){
        if(hang)return;
        const value=message.params.name==='list_threads'?{threads:[{id:'ordinary-chat',kind:'chatgpt',status:'streaming'}],pinnedThreads:[]}:{thread:{id:message.params.arguments.threadId,status:'idle'}};
        result=structured?{structuredContent:value}:{content:[{type:'text',text:JSON.stringify(value)}]};
      }
      queueMicrotask(()=>child.stdout.write(JSON.stringify({jsonrpc:'2.0',id:message.id,result})+'\n'));
    }});
    child.kill=()=>{child.killed=true;child.stdout.end();child.stderr.end();queueMicrotask(()=>child.emit('exit',0));};
    children.push(child);return child;
  }
  return {spawnProcess,children,calls,launches};
}

test('ChatGPT Work caller is passed through the documented interaction-client argument',async()=>fixture(async({home,dataDir})=>{
  assert.equal(captureDesktopWorkContext(home,{}, {CODEX_APP_TOOLS_PIPE_PATH:pipe,CODEX_THREAD_ID:caller,CODEX_INTERNAL_ORIGINATOR_OVERRIDE:'codex_work_desktop'},[]),true);
  const p=protocol({maximum:250}),client=new DesktopAppStatusClient({dataDir,codexHome:home,spawnProcess:p.spawnProcess});
  try {
    const snapshot=await client.list();assert.equal(snapshot.threads[0].status,'streaming');
    assert.deepEqual(p.launches[0].args.slice(1),['--interaction-client-id',caller]);
    assert.equal(p.calls.find(x=>x.method==='tools/call').params.arguments.limit,250);
    await assert.rejects(client.call('send_message_to_thread',{}),/READ_ONLY/);
  } finally {client.stop();}
  assert.equal(p.children.every(x=>x.killed),true);
}));

test('a read-only state location can publish through the per-installation user-temp relay',async()=>fixture(async({home,dataDir})=>{
  fs.writeFileSync(dataDir,'not a writable directory');
  assert.equal(captureDesktopWorkContext(home,{}, {CODEX_APP_TOOLS_PIPE_PATH:pipe,CODEX_THREAD_ID:caller},[]),true);
  assert.equal(JSON.parse(fs.readFileSync(desktopContextRelayFile(dataDir),'utf8')).callerThreadId,caller);
  const p=protocol(),client=new DesktopAppStatusClient({dataDir,codexHome:home,spawnProcess:p.spawnProcess});
  try {assert.equal((await client.list()).threads.length,1);} finally {client.stop();}
}));

test('a newer published endpoint replaces an old connection without guessing an identity',async()=>fixture(async({home,dataDir})=>{
  captureDesktopWorkContext(home,{}, {CODEX_APP_TOOLS_PIPE_PATH:pipe,CODEX_THREAD_ID:caller},[]);
  const p=protocol({structured:true}),client=new DesktopAppStatusClient({dataDir,codexHome:home,spawnProcess:p.spawnProcess});
  try {
    await client.list();
    assert.equal(captureDesktopWorkContext(home,{}, {CODEX_APP_TOOLS_PIPE_PATH:pipe+'-new'},[]),false);
    captureDesktopWorkContext(home,{}, {CODEX_APP_TOOLS_PIPE_PATH:pipe+'-new',CODEX_THREAD_ID:caller},[]);
    await client.list();assert.equal(p.launches.length,2);assert.equal(p.children[0].killed,true);
    assert.equal(p.launches[1].options.env.CODEX_APP_TOOLS_PIPE_PATH,pipe+'-new');
  } finally {client.stop();}
}));

test('client timeout clears pending requests and its child',async()=>fixture(async({home,dataDir})=>{
  captureDesktopWorkContext(home,{}, {CODEX_APP_TOOLS_PIPE_PATH:pipe,CODEX_THREAD_ID:caller},[]);
  const p=protocol({hang:true}),client=new DesktopAppStatusClient({dataDir,codexHome:home,spawnProcess:p.spawnProcess,timeoutMs:20});
  try {await assert.rejects(client.list(),/TIMEOUT/);assert.equal(client.pending.size,0);assert.equal(client.child,null);assert.equal(p.children[0].killed,true);} finally {client.stop();}
}));

test('ordinary chat and other projects are discovered beyond the old fifty-chat boundary',async()=>{
  const rows=Array.from({length:80},(_,i)=>({id:String(i),kind:'chatgpt',projectId:i<60?'one':'another',status:i===75?'in_progress':'idle'}));
  const states=[],tracker=new DesktopWorkTracker({client:{async list(){return {threads:rows};}},onState:s=>states.push(s)});
  await tracker.poll();assert.equal(states.at(-1).activeCount,1);assert.equal(states.at(-1).discoveryLimit,500);
  rows[75].status='waitingOnUserInput';await tracker.poll();assert.equal(states.at(-1).activeCount,0);
});

test('unknown summary states are checked with read_thread instead of treated as idle',async()=>{
  const states=[],reads=[],tracker=new DesktopWorkTracker({client:{async list(){return {threads:[{id:'ordinary',kind:'chatgpt'}]};},async read(thread){reads.push(thread.id);return {id:thread.id,turns:[{status:'inProgress'}]};}},onState:s=>states.push(s)});
  await tracker.poll();assert.deepEqual(reads,['ordinary']);assert.equal(states.at(-1).activeCount,1);
});

test('status normalization covers normal streaming, local projects, waiting and failures',()=>{
  for(const status of ['active','running','inProgress','in_progress','in-progress','streaming','generating','queued','working'])assert.equal(workStatus({status}),true,status);
  for(const status of ['idle','completed','failed','waitingOnUserInput','waitingOnApproval','needsAttention','cancelled'])assert.equal(workStatus({status}),false,status);
  assert.equal(workStatus({status:'unknown'}),null);
});

test('diagnostics preserve a safe error code while avoiding raw endpoint or reply data',async()=>{
  const states=[],tracker=new DesktopWorkTracker({client:{async list(){throw Error('DESKTOP_CONTEXT_MISSING');}},onState:s=>states.push(s)});
  await tracker.poll();assert.equal(states.at(-1).lastError,'DESKTOP_CONTEXT_MISSING');
  tracker.client.list=async()=>{throw Error('private arbitrary error');};await tracker.poll();assert.equal(states.at(-1).lastError,'APP_STATUS_UNAVAILABLE');
});
