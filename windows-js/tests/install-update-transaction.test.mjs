import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { install } from "../src/install.mjs";
import { processIdentity } from "../runtime/process-identity.mjs";
import { renameWithRetry } from "../src/core/update-transaction.mjs";
import { cleanupFinishedUpdate } from "../src/core/update-cleanup.mjs";
import { personalState, personalHashes } from "./fixtures/personal-state.mjs";
const app = path.resolve(path.dirname(fileURLToPath(import.meta.url)), ".."),
  hash = (bytes) => createHash("sha256").update(bytes).digest("hex"),
  json = (file, value) => fs.writeFileSync(file, JSON.stringify(value)),
  read = (file) => JSON.parse(fs.readFileSync(file, "utf8"));
function temporary(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "gpt-js-transaction-"));
  t.after(() => {
    assert.ok(
      path.resolve(root).startsWith(path.resolve(os.tmpdir()) + path.sep),
    );
    fs.rmSync(root, { recursive: true, force: true });
  });
  return root;
}
test('rollback retries transient directory locks and preserves the old files', async t => {
  const dir=temporary(t),from=path.join(dir,'locked'),to=path.join(dir,'restored');
  fs.mkdirSync(from);fs.writeFileSync(path.join(from,'marker'),'old');let calls=0;
  await renameWithRetry(from,to,{attempts:5,delayMs:1,rename:(a,b)=>{if(++calls<3)throw Object.assign(Error('temporarily busy'),{code:'EBUSY'});fs.renameSync(a,b);}});
  assert.equal(calls,3);assert.equal(fs.readFileSync(path.join(to,'marker'),'utf8'),'old');assert.equal(fs.existsSync(from),false);
  let failed=0;
  await assert.rejects(renameWithRetry(to,from,{attempts:3,delayMs:1,rename:()=>{failed++;throw Object.assign(Error('still busy'),{code:'EBUSY'});}}),{code:'EBUSY'});
  assert.equal(failed,3);assert.equal(fs.readFileSync(path.join(to,'marker'),'utf8'),'old');
});

test('a ready startup task with a detached live owner is resumed after installer rollback',async t=>{
  const root=temporary(t),target=path.join(root,'program'),source=path.join(root,'source'),dataDir=path.join(root,'data'),calls=[];
  fs.mkdirSync(target);fs.mkdirSync(dataDir);fs.mkdirSync(path.join(source,'native'),{recursive:true});
  fs.writeFileSync(path.join(target,'old.txt'),'old');fs.writeFileSync(path.join(source,'native/GPTNiang.Start.exe'),'fixture');json(path.join(source,'integrity.json'),{});
  json(path.join(dataDir,'runtime.json'),{pid:process.pid,processStartedTicks:processIdentity(process.pid)?.startedTicks,appDir:target});
  const plan={target,dataDir,shortcut:path.join(root,'startup.lnk'),marketplaceRoot:root,integrity:{files:{'native/GPTNiang.Start.exe':hash('fixture')}},previous:{},version:'1.3.5',sid:'fixture',taskName:'fixture',task:{exists:true,state:3,xml:'old-task'}};
  await assert.rejects(install(plan,{capturePlugin:()=>null,fileSource:source,stop:async()=>{},windows:(op)=>{calls.push(op);},execute:()=>({status:0,stdout:JSON.stringify({installed:[{pluginId:'gpt-niang-usage@gpt-niang-local',version:'1.3.5',installed:true,enabled:true}]})}),verify:async()=>{throw Error('injected unhealthy GUI');}}),/injected unhealthy GUI/);
  assert.equal(calls.filter(op=>op==='task-start').length,2,'one new start and one restored start');assert.equal(fs.readFileSync(path.join(target,'old.txt'),'utf8'),'old');
});
for(const stale of [false,true])test('rollback recognizes '+(stale?'stale':'live')+' legacy processStartedAt ownership without appDir',{skip:process.platform!=='win32'},async t=>{
  const root=temporary(t),target=path.join(root,'program'),source=path.join(root,'source'),dataDir=path.join(root,'data'),calls=[];
  fs.mkdirSync(target);fs.mkdirSync(dataDir);fs.mkdirSync(path.join(source,'native'),{recursive:true});
  fs.writeFileSync(path.join(target,'old.txt'),'old');fs.writeFileSync(path.join(source,'native/GPTNiang.Start.exe'),'fixture');json(path.join(source,'integrity.json'),{});
  const identity=processIdentity(process.pid);assert.ok(identity);
  json(path.join(dataDir,'supervisor-status.json'),{pid:process.pid,processStartedAt:new Date(identity.startedAt-(stale?1000:0)).toISOString()});
  const plan={target,dataDir,shortcut:path.join(root,'startup.lnk'),marketplaceRoot:root,integrity:{files:{'native/GPTNiang.Start.exe':hash('fixture')}},previous:{appDir:target,dataDir,architecture:'powershell-wpf'},version:'1.3.6',sid:'fixture',taskName:'fixture',task:{exists:true,state:3,xml:'old-task'}};
  await assert.rejects(install(plan,{capturePlugin:()=>null,fileSource:source,stop:async()=>{},windows:op=>{calls.push(op);},execute:()=>({status:0,stdout:JSON.stringify({installed:[{pluginId:'gpt-niang-usage@gpt-niang-local',version:'1.3.6',installed:true,enabled:true}]})}),verify:async()=>{throw Error('injected unhealthy GUI');}}),/injected unhealthy GUI/);
  assert.equal(calls.filter(op=>op==='task-start').length,stale?1:2);assert.equal(fs.readFileSync(path.join(target,'old.txt'),'utf8'),'old');
});
for (const failure of [
  "copy",
  "shortcut",
  "plugin",
  "startup",
  "new-install",
]) {
  test(`installer rollback restores files and pause intent after ${failure} failure`, async (t) => {
    const root = temporary(t),
      target = path.join(root, "app"),
      source = path.join(root, "source"),
      dataDir = path.join(root, "data"),
      shortcut = path.join(root, "startup.lnk"),
      market = path.join(root, ".agents", "plugins", "marketplace.json"),
      calls = [];
    for (const directory of [source, dataDir, path.dirname(market)])
      fs.mkdirSync(directory, { recursive: true });
    const existing = failure !== "new-install";
    if (existing) {
      fs.mkdirSync(target);
      fs.writeFileSync(path.join(target, "old.txt"), "old");
      fs.writeFileSync(shortcut, "old-link");
    }
    json(market, {
      name: "gpt-niang-local",
      plugins: [{ name: "unrelated", source: "./other" }],
    });
    const oldMarket = fs.readFileSync(market),
      pause = Buffer.from('{"mode":"desktop"}');
    fs.writeFileSync(path.join(dataDir, "supervisor-pause.json"), pause);
    fs.writeFileSync(path.join(dataDir, "quotes.json"), "personal-quotes");
    fs.writeFileSync(path.join(source, "new.txt"), "new");
    fs.mkdirSync(path.join(source,"native"));
    fs.writeFileSync(path.join(source,"native","GPTNiang.Start.exe"),"fixture-start");
    json(path.join(source, "integrity.json"), { version: 1 });
    const plan = {
      target,
      dataDir,
      shortcut,
      marketplaceRoot: root,
      integrity: { files: { "new.txt": hash("new"), "native/GPTNiang.Start.exe":hash("fixture-start") } },
      previous: {},
      version: "1.3.5",
      taskName: "fixture",
      sid: "fixture-sid",
      task: { exists: existing, state: 4, xml: "old-task" },
    };
    if (failure === "copy") fs.unlinkSync(path.join(source, "new.txt"));
    await assert.rejects(
      install(plan, {
        capturePlugin:()=>null,
        fileSource: source,
        stop: async () => {
          calls.push("stop");
          fs.writeFileSync(path.join(dataDir, "stop.flag"), "test-stop");
        },
        windows: (op) => {
          calls.push(op);
          if (
            (failure === "shortcut" || failure === "new-install") &&
            op === "shortcut-write"
          )
            throw Error("injected shortcut");
        },
        execute: (_exe,args) => {calls.push(args.join(' '));return {status:failure==='plugin'?1:0,stdout:JSON.stringify({installed:[{pluginId:'gpt-niang-usage@gpt-niang-local',version:'1.3.5',installed:true,enabled:true}]})};},
        verify: async () => {
          calls.push('verify');
          throw Error("injected startup");
        },
      }),
    );
    assert.equal(fs.existsSync(target), existing);
    if (existing)
      assert.equal(
        fs.readFileSync(path.join(target, "old.txt"), "utf8"),
        "old",
      );
    assert.deepEqual(fs.readFileSync(market), oldMarket);
    assert.equal(fs.existsSync(shortcut), existing);
    if (existing) assert.equal(fs.readFileSync(shortcut, "utf8"), "old-link");
    assert.deepEqual(
      fs.readFileSync(path.join(dataDir, "supervisor-pause.json")),
      pause,
    );
    assert.equal(fs.existsSync(path.join(dataDir, "stop.flag")), false);
    assert.equal(
      fs.readFileSync(path.join(dataDir, "quotes.json"), "utf8"),
      "personal-quotes",
    );
    if (failure === "copy") assert.deepEqual(calls, []);
    if (failure === "shortcut" || failure === "new-install") assert.ok(calls.includes('shortcut-write'));
    if (failure === "plugin") assert.ok(calls.some(c=>c.startsWith('plugin marketplace add')));
    if (failure === "startup") assert.ok(calls.includes('verify'));
  });
}
test('installed launcher, shortcut and task stay reachable if the program directory is missing',{skip:process.platform!=='win32'},async t=>{
  const temp=temporary(t),target=path.join(temp,'app'),source=path.join(temp,'source'),dataDir=path.join(temp,'data'),shortcut=path.join(temp,'startup.lnk'),setup=path.join(app,'native','GPTNiang.Setup.exe');
  fs.mkdirSync(path.join(source,'native'),{recursive:true});fs.mkdirSync(dataDir,{recursive:true});
  const binary=fs.readFileSync(path.join(app,'native','GPTNiang.Start.exe'));fs.writeFileSync(path.join(source,'native','GPTNiang.Start.exe'),binary);json(path.join(source,'integrity.json'),{version:1});
  const plan={target,dataDir,shortcut,marketplaceRoot:temp,integrity:{files:{'native/GPTNiang.Start.exe':hash(binary)}},previous:{},version:'1.3.5',taskName:'fixture',sid:'fixture',task:{exists:false}};
  let taskXml;
  const windows=(op,...args)=>{
    if(op==='task-register')taskXml=fs.readFileSync(args[1]).toString('utf16le');
    if(op==='shortcut-write'){const result=spawnSync(setup,[op,...args],{windowsHide:true,encoding:'utf8'});assert.equal(result.status,0,result.stdout+result.stderr);}
  };
  const execute=(_exe,args)=>({status:0,stdout:JSON.stringify({installed:[{pluginId:'gpt-niang-usage@gpt-niang-local',version:'1.3.5',installed:true,enabled:true}]})});
  await install(plan,{capturePlugin:()=>null,fileSource:source,stop:async()=>{},windows,execute,verify:async()=>{}});
  const info=spawnSync(setup,['shortcut-info',shortcut],{windowsHide:true,encoding:'utf8'});assert.equal(info.status,0,info.stdout+info.stderr);const link=JSON.parse(info.stdout.replace(/^\uFEFF/,''));
  assert.equal(path.resolve(link.target),path.resolve(plan.launcherPath));assert.equal(path.resolve(link.directory),path.dirname(path.resolve(plan.launcherPath)));
  assert.ok(taskXml.includes('<WorkingDirectory>'+path.dirname(plan.launcherPath)+'</WorkingDirectory>'));
  const moved=path.join(temp,'temporarily-moved');assert.equal(path.dirname(path.resolve(target)),path.resolve(temp));assert.equal(path.dirname(path.resolve(moved)),path.resolve(temp));
  fs.renameSync(target,moved);try{assert.ok(fs.existsSync(link.target));assert.ok(fs.existsSync(link.directory));}finally{fs.renameSync(moved,target);}
});
for (const success of [true, false]) {
  test(`update agent performs a real directory swap and ${success ? "commits a healthy program" : "restores a failed program"}`, async (t) => {
    const temp = temporary(t),
      root = path.join(temp, "app"),
      dataDir = path.join(temp, "data"),
      source = path.join(dataDir, "updates", "1.3.6");
    fs.mkdirSync(root);
    fs.mkdirSync(source, { recursive: true });
    const personal=personalState(dataDir);
    const pkg = (version) => ({
      name: "gpt-niang-usage",
      architecture: "javascript-electron",
      version,
      main: "main.cjs",
    });
    json(path.join(root, "package.json"), pkg("1.3.5"));
    fs.writeFileSync(
      path.join(root, "main.cjs"),
      `require('node:fs').writeFileSync(${JSON.stringify(path.join(dataDir, "restored.txt"))},'restored');`,
    );
    json(path.join(root, "installation.json"), {
      appDir: root,
      dataDir,
      electronPath: process.execPath,
    });
    fs.writeFileSync(path.join(root, "old-marker"), "old");
    const sourceFiles = {
      "package.json": JSON.stringify(pkg("1.3.6")),
      "main.cjs": success
        ? `const fs=require('node:fs');import(${JSON.stringify(new URL('../runtime/process-identity.mjs',import.meta.url).href)}).then(({processIdentity})=>{const id=processIdentity(process.pid);fs.writeFileSync(${JSON.stringify(path.join(dataDir, "runtime.json"))},JSON.stringify({pid:process.pid,widget:1,appDir:${JSON.stringify(root)},processStartedTicks:id.startedTicks,at:Date.now(),version:'1.3.6',architecture:'javascript-electron',rendererReady:true}));setInterval(()=>{},1000);});`
        : "process.exit(3);",
    };
    const expected = Object.entries(sourceFiles).map(([name, bytes]) => {
      fs.writeFileSync(path.join(source, name), bytes);
      return { name, hash: hash(bytes) };
    });
    fs.writeFileSync(
      path.join(source, "verified-package.zip"),
      "verified-archive-fixture",
    );
    const jobFile = path.join(temp, "job.json");
    json(jobFile, {
      root,
      dataDir,
      source,
      parentPid: 2147483647,
      expected,
      hash: hash("verified-archive-fixture"),
      version: "1.3.6",
      token: "fixture-token",
    });
    json(path.join(dataDir, "update-installing.json"), {
      token: "fixture-token",
    });
    const child = spawn(
      process.execPath,
      [path.join(app, "src", "update-agent.mjs"), jobFile],
      { windowsHide: true, stdio: "pipe" },
    );
    let diagnostics = "";
    child.stderr.on("data", (data) => {
      diagnostics += data;
    });
    const code = await new Promise((resolve, reject) => {
      child.on("error", reject);
      child.on("exit", resolve);
    });
    assert.equal(code, success ? 0 : 1, diagnostics);
    const result = read(path.join(dataDir, "javascript-update-result.json"));
    assert.equal(result.ok, success);
    assert.deepEqual(personalHashes(dataDir,personal.files),personal.files);
    assert.equal(
      read(path.join(root, "package.json")).version,
      success ? "1.3.6" : "1.3.5",
    );
    assert.equal(
      fs.existsSync(path.join(dataDir, "update-installing.json")),
      false,
    );
    if (success) {
      const runtime = read(path.join(dataDir, "runtime.json"));
      process.kill(runtime.pid);
      await new Promise((resolve) => setTimeout(resolve, 300));
      assert.equal(result.backup,null);
      assert.equal(fs.existsSync(root+'.rollback-fixture-token'),false);
    } else {
      assert.equal(
        fs.readFileSync(path.join(root, "old-marker"), "utf8"),
        "old",
      );
      for (
        let n = 0;
        n < 30 && !fs.existsSync(path.join(dataDir, "restored.txt"));
        n++
      )
        await new Promise((r) => setTimeout(r, 100));
      assert.equal(
        fs.readFileSync(path.join(dataDir, "restored.txt"), "utf8"),
        "restored",
      );
    }
    assert.equal(cleanupFinishedUpdate(dataDir,()=>false),true);
    assert.deepEqual(personalHashes(dataDir,personal.files),personal.files);
    assert.equal(fs.existsSync(source),false);
    assert.deepEqual(fs.readdirSync(temp).filter(name=>/\.(rollback|staging)-/.test(name)),[]);
  });
}
for(const supervisorWorks of [true,false]){
  test(`update ${supervisorWorks?'commits after the new supervisor becomes healthy':'rolls back when the new supervisor exits'}`,{skip:process.platform!=='win32',timeout:20000},async t=>{
    const temp=temporary(t),root=path.join(temp,'app'),dataDir=path.join(temp,'data'),source=path.join(dataDir,'updates','verified');
    fs.mkdirSync(root,{recursive:true});fs.mkdirSync(source,{recursive:true});
    const pkg=version=>({name:'gpt-niang-usage',architecture:'javascript-electron',version,main:'main.cjs'});
    json(path.join(root,'package.json'),pkg('1.3.5'));json(path.join(root,'installation.json'),{appDir:root,dataDir,electronPath:process.execPath,nodePath:process.execPath});
    fs.writeFileSync(path.join(root,'old-marker'),'old');fs.writeFileSync(path.join(root,'main.cjs'),`require('node:fs').writeFileSync(${JSON.stringify(path.join(dataDir,'restored.txt'))},'restored')`);
    const identityUrl=new URL('../runtime/process-identity.mjs',import.meta.url).href;
    const gui=`const fs=require('node:fs');import(${JSON.stringify(identityUrl)}).then(({processIdentity})=>{const id=processIdentity(process.pid),write=()=>fs.writeFileSync(${JSON.stringify(path.join(dataDir,'runtime.json'))},JSON.stringify({pid:process.pid,widget:1,appDir:${JSON.stringify(root)},processStartedTicks:id.startedTicks,at:Date.now(),version:'1.3.6',architecture:'javascript-electron',rendererReady:true}));write();setInterval(write,250);})`;
    const supervisor=supervisorWorks?`import fs from 'node:fs';import {processIdentity} from ${JSON.stringify(identityUrl)};const id=processIdentity(process.pid),write=()=>fs.writeFileSync(${JSON.stringify(path.join(dataDir,'supervisor-status.json'))},JSON.stringify({pid:process.pid,processStartedTicks:id.startedTicks,appDir:${JSON.stringify(root)},version:'1.3.6',at:new Date().toISOString(),paused:false,widgetRunning:true,visibleWindows:1}));write();setInterval(write,250);`:'process.exit(4);';
    const files={'package.json':JSON.stringify(pkg('1.3.6')),'main.cjs':gui,'src/start.mjs':supervisor},expected=[];
    for(const [name,content] of Object.entries(files)){const file=path.join(source,name);fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,content);expected.push({name,hash:hash(content)});}
    fs.writeFileSync(path.join(source,'verified-package.zip'),'fixture-archive');const jobFile=path.join(temp,'job.json');
    json(jobFile,{root,dataDir,source,version:'1.3.6',parentPid:2147483647,token:'supervisor-fixture',expected,hash:hash('fixture-archive')});
    const child=spawn(process.execPath,[path.join(app,'src/update-agent.mjs'),jobFile],{windowsHide:true,stdio:'pipe'});let diagnostics='';child.stderr.on('data',b=>diagnostics+=b);
    const code=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',resolve);});
    try{
      assert.equal(code,supervisorWorks?0:1,diagnostics);const result=read(path.join(dataDir,'javascript-update-result.json'));
      assert.equal(result.ok,supervisorWorks);assert.equal(read(path.join(root,'package.json')).version,supervisorWorks?'1.3.6':'1.3.5',JSON.stringify({result,journal:read(path.join(dataDir,'javascript-update-journal.json'))}));
      if(supervisorWorks)assert.equal(read(path.join(dataDir,'javascript-update-journal.json')).phase,'committed');
    }finally{
      for(const file of ['runtime.json','supervisor-status.json']){try{const item=read(path.join(dataDir,file));if(item?.pid&&item.processStartedTicks&&processIdentity(item.pid)?.startedTicks===item.processStartedTicks)process.kill(item.pid);}catch{}}
      await new Promise(r=>setTimeout(r,250));
    }
  });
}
test('update rollback lets the restored supervisor create exactly one GUI',{skip:process.platform!=='win32',timeout:15000},async t=>{
  const temp=temporary(t),root=path.join(temp,'app'),dataDir=path.join(temp,'data'),source=path.join(dataDir,'updates','one-owner');
  fs.mkdirSync(path.join(root,'src'),{recursive:true});fs.mkdirSync(source,{recursive:true});
  const pkg=version=>({name:'gpt-niang-usage',architecture:'javascript-electron',version,main:'main.cjs'}),gui=path.join(dataDir,'gui-starts.txt'),supervisor=path.join(dataDir,'supervisor-starts.txt');
  json(path.join(root,'package.json'),pkg('1.3.6'));json(path.join(root,'installation.json'),{appDir:root,dataDir,electronPath:process.execPath,nodePath:process.execPath});
  fs.writeFileSync(path.join(root,'main.cjs'),`require('node:fs').appendFileSync(${JSON.stringify(gui)},'gui\\n');`);
  fs.writeFileSync(path.join(root,'src/start.mjs'),`import fs from 'node:fs';import {spawn} from 'node:child_process';fs.appendFileSync(${JSON.stringify(supervisor)},'supervisor\\n');spawn(process.execPath,[${JSON.stringify(path.join(root,'main.cjs'))}],{windowsHide:true,stdio:'ignore'});`);
  const files={'package.json':JSON.stringify(pkg('1.3.7')),'main.cjs':'process.exit(23);'},expected=[];
  for(const [name,content]of Object.entries(files)){fs.writeFileSync(path.join(source,name),content);expected.push({name,hash:hash(content)});}
  fs.writeFileSync(path.join(source,'verified-package.zip'),'fixture');const job=path.join(temp,'job.json');json(job,{root,dataDir,source,parentPid:2147483647,version:'1.3.7',fromVersion:'1.3.6',token:'one-owner',hash:hash('fixture'),expected});
  const child=spawn(process.execPath,[path.join(app,'src/update-agent.mjs'),job],{windowsHide:true,stdio:'pipe'});let error='';child.stderr.on('data',bytes=>error+=bytes);assert.equal(await new Promise((resolve,reject)=>{child.once('exit',resolve);child.once('error',reject);}),1,error);
  for(let n=0;n<50&&!fs.existsSync(gui);n++)await new Promise(resolve=>setTimeout(resolve,50));await new Promise(resolve=>setTimeout(resolve,250));
  assert.equal(fs.readFileSync(gui,'utf8'),'gui\n');assert.equal(fs.readFileSync(supervisor,'utf8'),'supervisor\n');
});

test('bundled Electron update agent copies asar files as ordinary files',{skip:process.platform!=='win32',timeout:15000},async t=>{
  const temp=temporary(t),root=path.join(temp,'app'),dataDir=path.join(temp,'data'),source=path.join(dataDir,'updates','fixture');fs.mkdirSync(root,{recursive:true});fs.mkdirSync(source,{recursive:true});
  const pkg=version=>({name:'gpt-niang-usage',architecture:'javascript-electron',version,main:'main.cjs'});
  json(path.join(root,'package.json'),pkg('1.3.5'));json(path.join(root,'installation.json'),{appDir:root,dataDir,electronPath:process.execPath});fs.writeFileSync(path.join(root,'main.cjs'),'process.exit(0)');
  const identityUrl=new URL('../runtime/process-identity.mjs',import.meta.url).href;
  const gui=`const fs=require('node:fs');import(${JSON.stringify(identityUrl)}).then(({processIdentity})=>{const id=processIdentity(process.pid);fs.writeFileSync(${JSON.stringify(path.join(dataDir,'runtime.json'))},JSON.stringify({pid:process.pid,widget:1,appDir:${JSON.stringify(root)},processStartedTicks:id.startedTicks,at:Date.now(),version:'1.3.6',architecture:'javascript-electron',rendererReady:true}));setInterval(()=>{},1000);});`;
  const archiveName='node_modules/electron/dist/resources/default_app.asar',files={'package.json':JSON.stringify(pkg('1.3.6')),'main.cjs':gui,[archiveName]:'raw-asar-fixture'},expected=[];
  for(const [name,content] of Object.entries(files)){const f=path.join(source,name);fs.mkdirSync(path.dirname(f),{recursive:true});fs.writeFileSync(f,content);expected.push({name,hash:hash(content)});}
  fs.writeFileSync(path.join(source,'verified-package.zip'),'fixture-archive');const jobFile=path.join(temp,'job.json');json(jobFile,{root,dataDir,source,version:'1.3.6',parentPid:2147483647,token:'asar-fixture',expected,hash:hash('fixture-archive')});
  const electron=path.join(app,'node_modules','electron','dist','electron.exe'),child=spawn(electron,[path.join(app,'src','update-agent.mjs'),jobFile],{windowsHide:true,stdio:'pipe',env:{...process.env,ELECTRON_RUN_AS_NODE:'1'}});let diagnostics='';child.stderr.on('data',b=>diagnostics+=b);
  const code=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',resolve);});
  try{assert.equal(code,0,diagnostics);assert.equal(fs.readFileSync(path.join(root,archiveName),'utf8'),'raw-asar-fixture');assert.equal(read(path.join(dataDir,'javascript-update-result.json')).ok,true);}
  finally{try{const running=read(path.join(dataDir,'runtime.json'));if(processIdentity(running.pid)?.startedTicks===running.processStartedTicks)process.kill(running.pid);}catch{}await new Promise(r=>setTimeout(r,200));}
});
