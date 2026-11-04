import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import path from 'node:path';import os from 'node:os';import {spawnSync} from 'node:child_process';
import {capturePluginRegistration,restorePluginRegistration,retainPluginPreference,pluginSections,replacePluginSections} from '../src/core/plugin-registration.mjs';
import {resolveInstallCli} from '../src/core/cli.mjs';
import {install} from '../src/install.mjs';import {createHash} from 'node:crypto';
const pluginId='gpt-niang-usage@gpt-niang-local';let cli;
function fixture(t){
  cli??=resolveInstallCli();const root=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-real-plugin-')),home=path.join(root,'codex-home'),marketplaceRoot=path.join(root,'market'),target=path.join(marketplaceRoot,'gpt-niang-usage');
  t.after(()=>{assert.equal(path.dirname(root),path.resolve(os.tmpdir()));fs.rmSync(root,{recursive:true,force:true});});
  const json=(file,value)=>{fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,JSON.stringify(value));};
  fs.mkdirSync(home);json(path.join(marketplaceRoot,'.agents/plugins/marketplace.json'),{name:'gpt-niang-local',plugins:[{name:'gpt-niang-usage',source:'./gpt-niang-usage'}]});
  const version=value=>json(path.join(target,'.codex-plugin/plugin.json'),{name:'gpt-niang-usage',version:value,description:'isolated registration test'});
  const execute=(file,args,options)=>spawnSync(file,args,{...options,env:{...options?.env,CODEX_HOME:home},encoding:'utf8',windowsHide:true});
  const run=(...args)=>{const result=execute(cli,['plugin',...args,'--json'],{timeout:30000});assert.equal(result.status,0,result.stdout+result.stderr);return JSON.parse(result.stdout);};
  const plan={target,marketplaceRoot,codexPath:cli,version:'1.3.6'};const config=path.join(home,'config.toml');
  return {root,home,marketplaceRoot,target,json,version,execute,run,plan,config};
}
test('owned TOML table edits preserve unrelated text, arrays and fake headers in multiline strings',()=>{
  const text=`notes = '''\n[plugins."gpt-niang-usage@gpt-niang-local"]\nnot a table\n'''\n[plugins."other@elsewhere"]\nenabled = false\n[[mcp_servers.test.headers]]\nvalue = "untouched"\n[plugins."gpt-niang-usage@gpt-niang-local"]\nenabled = false\n[windows]\nsetting = "keep"\n`;
  const snapshot=pluginSections(text).sections;assert.equal(snapshot.plugin,'[plugins."gpt-niang-usage@gpt-niang-local"]\nenabled = false\n');
  const edited=replacePluginSections(text,{...snapshot,plugin:null});assert.ok(edited.includes('not a table'));assert.ok(edited.includes('[[mcp_servers.test.headers]]'));assert.ok(edited.endsWith('[windows]\nsetting = "keep"\n'));
  assert.equal(replacePluginSections(text,snapshot),text);
  assert.throws(()=>pluginSections('[plugins."gpt-niang-usage@gpt-niang-local"]\nenabled=true\n[plugins."gpt-niang-usage@gpt-niang-local".permissions]\nx=1'),/嵌套设置/);
});
test('a quoted literal table name cannot alias an owned dotted TOML table',()=>{
 const text='["plugins.gpt-niang-usage@gpt-niang-local"]\nenabled = false\n[plugins."gpt-niang-usage@gpt-niang-local"]\nenabled = true\n';
 const parsed=pluginSections(text);assert.equal(parsed.sections.plugin,'[plugins."gpt-niang-usage@gpt-niang-local"]\nenabled = true\n');
 const edited=replacePluginSections(text,{market:null,plugin:null});assert.equal(edited,'["plugins.gpt-niang-usage@gpt-niang-local"]\nenabled = false\n');
});
for(const enabled of [true,false])test('real Codex CLI restores old cache/version and '+(enabled?'enabled':'disabled')+' preference',{skip:process.platform!=='win32',timeout:30000},t=>{
  const f=fixture(t);f.version('1.3.5');f.run('marketplace','add',f.marketplaceRoot);f.run('add',pluginId);
  fs.appendFileSync(f.config,'\n[plugins."unrelated@other"]\nenabled = false\n');
  if(!enabled)fs.writeFileSync(f.config,fs.readFileSync(f.config,'utf8').replace('[plugins."'+pluginId+'"]\nenabled = true','[plugins."'+pluginId+'"]\nenabled = false'));
  const snapshot=capturePluginRegistration(f.plan,{execute:f.execute,home:f.home});assert.equal(snapshot.previous.enabled,enabled);
  f.version('1.3.6');f.run('marketplace','add',f.marketplaceRoot);f.run('add',pluginId);retainPluginPreference(snapshot);
  assert.equal(f.run('list','--marketplace','gpt-niang-local').installed[0].enabled,enabled);
  fs.appendFileSync(f.config,'\n[unrelated_user_edit]\nkeep = "typed during installation"\n');
  f.version('1.3.5');const result=restorePluginRegistration(snapshot,{execute:f.execute});assert.equal(result.version,'1.3.5');assert.equal(result.enabled,enabled);
  assert.ok(fs.readFileSync(f.config,'utf8').includes('typed during installation'));assert.ok(fs.readFileSync(f.config,'utf8').includes('[plugins."unrelated@other"]\nenabled = false'));
  assert.equal(fs.existsSync(path.join(f.home,'plugins/cache/gpt-niang-local/gpt-niang-usage/1.3.6')),false);
  assert.equal(restorePluginRegistration(snapshot,{execute:f.execute}).version,'1.3.5','recovery must be repeatable');
});
test('real Codex CLI restores an originally absent registration without changing other plugin settings',{skip:process.platform!=='win32',timeout:30000},t=>{
  const f=fixture(t);f.version('1.3.6');fs.writeFileSync(f.config,'[plugins."unrelated@other"]\nenabled = false\n');
  const snapshot=capturePluginRegistration(f.plan,{execute:f.execute,home:f.home});assert.equal(snapshot.previous,null);
  f.run('marketplace','add',f.marketplaceRoot);f.run('add',pluginId);assert.equal(restorePluginRegistration(snapshot,{execute:f.execute}).installed,false);
  assert.ok(fs.readFileSync(f.config,'utf8').includes('[plugins."unrelated@other"]\nenabled = false'));assert.equal(f.run('list','--marketplace','gpt-niang-local').installed.length,0);
});
test('rollback refuses a plugin subsequently registered from a different installation',{skip:process.platform!=='win32',timeout:30000},t=>{
  const f=fixture(t);f.version('1.3.5');f.run('marketplace','add',f.marketplaceRoot);f.run('add',pluginId);
  const snapshot=capturePluginRegistration(f.plan,{execute:f.execute,home:f.home}),foreign=path.join(f.root,'foreign');
  f.json(path.join(foreign,'.agents/plugins/marketplace.json'),{name:'gpt-niang-local',plugins:[{name:'gpt-niang-usage',source:'./gpt-niang-usage'}]});
  f.json(path.join(foreign,'gpt-niang-usage/.codex-plugin/plugin.json'),{name:'gpt-niang-usage',version:'1.9.9',description:'foreign install'});
  f.run('marketplace','remove','gpt-niang-local');f.run('marketplace','add',foreign);f.run('add',pluginId);const before=fs.readFileSync(f.config);
  assert.throws(()=>restorePluginRegistration(snapshot,{execute:f.execute}),/其他操作更改/);assert.deepEqual(fs.readFileSync(f.config),before);assert.equal(f.run('list','--marketplace','gpt-niang-local').installed[0].version,'1.9.9');
});
test('actual installer failure restores the original Codex registration after a real CLI upgrade',{skip:process.platform!=='win32',timeout:40000},async t=>{
  const f=fixture(t);f.version('1.3.5');f.run('marketplace','add',f.marketplaceRoot);f.run('add',pluginId);
  const dataDir=path.join(f.root,'data'),source=path.join(f.root,'source'),shortcut=path.join(f.root,'startup.lnk');fs.mkdirSync(dataDir);fs.mkdirSync(path.join(source,'native'),{recursive:true});
  const files={'native/GPTNiang.Start.exe':'fixture launcher','.codex-plugin/plugin.json':JSON.stringify({name:'gpt-niang-usage',version:'1.3.6',description:'new version'})};
  for(const [name,bytes]of Object.entries(files)){fs.mkdirSync(path.dirname(path.join(source,name)),{recursive:true});fs.writeFileSync(path.join(source,name),bytes);}f.json(path.join(source,'integrity.json'),{});
  const plan={...f.plan,dataDir,shortcut,previous:{},version:'1.3.6',sid:'fixture',taskName:'fixture',task:{exists:false},integrity:{files:Object.fromEntries(Object.entries(files).map(([name,bytes])=>[name,createHash('sha256').update(bytes).digest('hex')]))}};
  await assert.rejects(install(plan,{fileSource:source,execute:f.execute,capturePlugin:(plan,options)=>capturePluginRegistration(plan,{...options,home:f.home}),windows(){},stop:async()=>{},verify:async()=>{assert.equal(f.run('list','--marketplace','gpt-niang-local').installed[0].version,'1.3.6');throw Error('injected health failure');}}),/injected health failure/);
  const old=f.run('list','--marketplace','gpt-niang-local').installed[0];assert.equal(old.version,'1.3.5');assert.equal(old.enabled,true);assert.equal(JSON.parse(fs.readFileSync(path.join(f.target,'.codex-plugin/plugin.json'))).version,'1.3.5');
  assert.deepEqual(fs.readdirSync(f.marketplaceRoot).filter(name=>/\.(rollback|stage)-/.test(name)),[]);
});
