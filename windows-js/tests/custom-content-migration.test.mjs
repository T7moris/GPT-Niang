import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import {install} from '../src/install.mjs';
import {Characters} from '../src/core/characters.mjs';
import {AudioStore} from '../src/core/audio.mjs';
import {QuoteStore} from '../src/core/quotes.mjs';
import {SettingsStore} from '../src/core/settings.mjs';
import {Colors} from '../src/core/colors.mjs';
import {personalState,personalHashes} from './fixtures/personal-state.mjs';
const app=fileURLToPath(new URL('../',import.meta.url));
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
for(const scenario of ['success','rollback','report-blocked'])test(`legacy custom content remains byte-identical after ${scenario}`,async t=>{
  const succeeds=scenario!=='rollback';
  const temp=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-custom-migration-'));
  t.after(()=>{assert.equal(path.dirname(temp),path.resolve(os.tmpdir()));fs.rmSync(temp,{recursive:true,force:true});});
  const target=path.join(temp,'program'),dataDir=path.join(temp,'personal'),source=path.join(temp,'source');
  fs.mkdirSync(target);fs.mkdirSync(path.join(source,'native'),{recursive:true});
  fs.writeFileSync(path.join(target,'legacy.ps1'),'original program');
  const personal=personalState(dataDir),files={'native/GPTNiang.Start.exe':'fixture launcher','new.txt':'new program'};
  if(scenario==='report-blocked')fs.mkdirSync(path.join(dataDir,'javascript-install-result.json'));
  for(const [name,bytes]of Object.entries(files))fs.writeFileSync(path.join(source,name),bytes);
  fs.writeFileSync(path.join(source,'integrity.json'),'{}');
  const plan={target,dataDir,shortcut:path.join(temp,'startup.lnk'),marketplaceRoot:temp,integrity:{files:Object.fromEntries(Object.entries(files).map(([k,v])=>[k,hash(v)]))},previous:{dataDir,unknownInstallSetting:'keep'},version:'1.3.6',sid:'fixture',taskName:'fixture',task:{exists:false}};
  const dependencies={capturePlugin:()=>null,fileSource:source,stop:async()=>{},windows(){},execute:()=>({status:0,stdout:JSON.stringify({installed:[{pluginId:'gpt-niang-usage@gpt-niang-local',version:'1.3.6',installed:true,enabled:true}]})}),verify:async()=>{assert.deepEqual(personalHashes(dataDir,personal.files),personal.files);if(!succeeds)throw Error('injected health failure');}};
  if(succeeds){const result=await install(plan,dependencies);assert.equal(result.backup,null);assert.equal(result.cleanupPending,false);if(scenario==='report-blocked')assert.ok(result.reportError);}
  else {await assert.rejects(install(plan,dependencies),/injected health failure/);assert.equal(fs.readFileSync(path.join(target,'legacy.ps1'),'utf8'),'original program');}
  assert.deepEqual(personalHashes(dataDir,personal.files),personal.files);
  assert.deepEqual(fs.readdirSync(temp).filter(name=>/\.(rollback|stage)-/.test(name)),[]);
  assert.deepEqual(fs.readdirSync(dataDir).filter(name=>name.startsWith('install-js-')),[]);
  const characters=new Characters(app,dataDir);
  assert.equal(characters.selected(personal.id).name,'我的角色 🌟');
  assert.equal(characters.removed()[0].id,personal.removed);
  assert.ok((await characters.display(personal.id)).url.startsWith('data:image/png;base64,'));
  const audio=new AudioStore(app,dataDir).payload();
  assert.equal(audio.preferences.mode,'custom');assert.ok(audio.slots.press);assert.ok(audio.slots.release);
  assert.deepEqual(new QuoteStore(dataDir,path.join(app,'assets')).list().quotes,personal.values['quotes.json'].quotes);
  const settings=new SettingsStore(path.join(dataDir,'settings.json'));
  assert.equal(settings.value.characterId,personal.id);assert.equal(settings.value.soundVolume,0.37);assert.equal(settings.value.bottom,-12);
  const colors=new Colors(settings.value,personal.values['color-triggers.json'].quotes);
  assert.equal(colors.scene({revision:1,collapsed:false,mode:'quote',text:'自定义触发词'}).scope,'full');
  assert.deepEqual(personalHashes(dataDir,personal.files),personal.files);
});
test('legacy color triggers accept strings, weighted rows and quote containers with the original normalization',()=>{
  const settings={colorMode:'special'};
  for(const saved of ['  自定义触发词  ',[{text:' 自定义触发词 ',weight:2}],'自定义触发词',{version:1,quotes:['自定义触发词','自定义触发词']}]) {
    const colors=new Colors(settings,saved);
    assert.deepEqual(colors.triggers,['自定义触发词']);
    assert.equal(colors.scene({revision:1,collapsed:false,mode:'quote',text:'自定义触发词'}).scope,'full');
    assert.equal(colors.scene({revision:2,collapsed:false,mode:'quote',text:'其他语录'}).scope,'none');
  }
  assert.deepEqual(new Colors(settings,null).triggers,['Token来，Token来']);
  assert.deepEqual(new Colors(settings,[]).triggers,[]);
  assert.equal(new Colors(settings,['Token来']).scene({revision:1,collapsed:false,mode:'quote',text:'TOKEN来'}).scope,'full');
  const edited=new Colors(settings,['Token来']);edited.triggers=['修改后的触发词'];
  assert.equal(edited.scene({revision:2,collapsed:false,mode:'quote',text:'TOKEN来'}).scope,'none');
  assert.equal(edited.scene({revision:3,collapsed:false,mode:'quote',text:'修改后的触发词'}).scope,'full');
});
