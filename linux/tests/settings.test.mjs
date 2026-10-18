import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {dataDirectory,normalizeSettings,saveSettings,loadSettings,displayWindows} from '../runtime/settings.mjs';
import {install,uninstall,setAutostart,autostartEnabled,desktopQuote} from '../runtime/install.mjs';

test('settings use XDG state, preserve both positions and bound malformed input',()=>{
  assert.equal(dataDirectory({HOME:'/home/example',XDG_STATE_HOME:'/state'}),'/state/gpt-niang-usage');
  assert.equal(dataDirectory({HOME:'/home/example',GPT_NIANG_DATA_DIR:'/override'}),'/override');
  const p=normalizeSettings({mode:'follow',scale:999,volume:-5,bubbleSeconds:NaN,desktop:{x:-1200,y:900},follow:{edge:'left',bottom:30},customQuotes:['line','',42]});
  assert.equal(p.scale,2.5);assert.equal(p.volume,0);assert.equal(p.bubbleSeconds,5);
  assert.deepEqual(p.desktop,{x:-1200,y:900});assert.deepEqual(p.follow,{edge:'left',bottom:30});
  assert.deepEqual(p.customQuotes,['line']);assert.deepEqual(normalizeSettings(p),p);
  assert.deepEqual(normalizeSettings({...p,mode:'desktop'}).follow,p.follow);
});

test('preferences survive restart and a corrupt file falls back safely',()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'niang-settings-'));
  try{
    const settings=normalizeSettings({scale:0.8,customQuotes:['持久语录'],mode:'follow'});
    saveSettings(dir,settings);assert.deepEqual(loadSettings(dir),settings);
    fs.writeFileSync(path.join(dir,'kde-settings.json'),'broken');
    assert.equal(loadSettings(dir).mode,'desktop');assert.equal(loadSettings(dir).customQuotes,null);
  }finally{fs.rmSync(dir,{recursive:true,force:true});}
});

test('quota rendering preserves zero, expired resets, stale errors and every window',()=>{
  const rows=displayWindows({queryOk:false,observedAt:1,windows:[
    {label:'5 小时',remaining:0,resetsAt:null},
    {label:'每周',remaining:80,resetsAt:1},
    {label:'个人额度',remaining:25.4,resetsAt:null},
  ]},200000);
  assert.equal(rows[0].value,'0%');assert.equal(rows[1].value,'—');assert.equal(rows[1].expired,true);
  assert.equal(rows[2].value,'25%');assert.ok(rows.every(w=>w.stale));assert.equal(rows.length,3);
});

test('user installation handles spaces, percent signs and preserves private settings on uninstall',()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'niang-install-'));
  const vars=['HOME','XDG_CONFIG_HOME','XDG_DATA_HOME','PATH','GPT_NIANG_CODEX_PATH'];const before=Object.fromEntries(vars.map(k=>[k,process.env[k]]));
  const root=path.join(dir,"龙 娘 100% 'app'");
  try{
    for(const key of vars)delete process.env[key];
    process.env.HOME=path.join(dir,'home');
    process.env.PATH=path.join(dir,'bin');
    fs.mkdirSync(process.env.PATH,{recursive:true});
    const codex=path.join(process.env.PATH,process.platform==='win32'?'codex.exe':'codex');
    fs.writeFileSync(codex,'fixture',{mode:0o755});
    fs.mkdirSync(path.join(root,'linux'),{recursive:true});
    const launcher=install(root,{autostart:true});
    const runtime=JSON.parse(fs.readFileSync(path.join(root,'linux/.runtime-paths.json'),'utf8'));
    assert.equal(runtime.node,process.execPath);assert.equal(runtime.codexPath,codex);
    assert.ok(fs.statSync(launcher).mode & 0o100);assert.equal(autostartEnabled(),true);
    const entry=fs.readFileSync(path.join(process.env.HOME,'.local/share/applications/org.gptniang.KDE.desktop'),'utf8');
    assert.ok(entry.includes('100%%'));assert.ok(entry.includes('Exec="'));
    const state=path.join(process.env.HOME,'.local/state/gpt-niang-usage');saveSettings(state,{scale:0.8});
    setAutostart(false,root);assert.equal(autostartEnabled(),false);
    uninstall(root);assert.equal(fs.existsSync(launcher),false);assert.equal(loadSettings(state).scale,0.8);
    assert.ok(fs.existsSync(root));
  }finally{
    for(const key of vars){if(before[key]===undefined)delete process.env[key];else process.env[key]=before[key];}
    fs.rmSync(dir,{recursive:true,force:true});
  }
});

test('installer refuses to replace an unrelated executable',()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'niang-install-conflict-'));
  const before=process.env.HOME;process.env.HOME=dir;
  try{
    fs.mkdirSync(path.join(dir,'.local/bin'),{recursive:true});fs.writeFileSync(path.join(dir,'.local/bin/gpt-niang'),'foreign');
    assert.throws(()=>install(dir),/已存在/);
    assert.equal(fs.readFileSync(path.join(dir,'.local/bin/gpt-niang'),'utf8'),'foreign');
  }finally{if(before===undefined)delete process.env.HOME;else process.env.HOME=before;fs.rmSync(dir,{recursive:true,force:true});}
});

test('desktop Exec quoting escapes substitutions as literal file names',()=>{
  assert.equal(desktopQuote('/tmp/$x`test`\\"%'), '"/tmp/\\$x\\`test\\`\\\\\\"%%"');
});
