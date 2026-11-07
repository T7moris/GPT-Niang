import test from 'node:test';import assert from 'node:assert/strict';import path from 'node:path';
import {resolveSetupTarget} from '../src/core/setup-target.mjs';
const target=path.resolve('fixture-existing'),dataDir=path.resolve('fixture-personal'),row={pluginId:'gpt-niang-usage@gpt-niang-local',installed:true,source:{path:target}};
const options=(installed,config={appDir:target,dataDir})=>({codexPath:'fixture-codex',execute:()=>({status:0,stdout:JSON.stringify({installed})}),read:file=>file.endsWith('package.json')?{name:'gpt-niang-usage'}:config,env:{LOCALAPPDATA:path.resolve('fixture-local'),USERPROFILE:path.resolve('fixture-profile')}});
test('public installer keeps existing JavaScript and legacy installations with their original personal directory',()=>{
 assert.deepEqual(resolveSetupTarget(options([row])),{target,dataDir,existing:true});
 assert.deepEqual(resolveSetupTarget(options([row],{dataDir,version:'1.3.6'})),{target,dataDir,existing:true});
 const first=resolveSetupTarget(options([]));assert.equal(first.existing,false);assert.equal(path.dirname(first.target),path.dirname(first.dataDir));assert.notEqual(first.target,first.dataDir);
});
test('uncertain, duplicate or conflicting installations never silently become a fresh installation',()=>{
 assert.throws(()=>resolveSetupTarget(options([row,row])));
 assert.throws(()=>resolveSetupTarget(options([row],{appDir:path.resolve('other'),dataDir})));
 assert.throws(()=>resolveSetupTarget(options([row],{})));
 assert.throws(()=>resolveSetupTarget({...options([]),execute:()=>({status:1})}));
 assert.throws(()=>resolveSetupTarget({...options([]),execute:()=>({status:0,stdout:'{}'})}));
});
test('custom home environment is carried into read-only existing-install discovery',()=>{
 const custom=path.resolve('不同名称的 Codex 根目录'),opts=options([row]);opts.env.CODEX_HOME=custom;
 opts.execute=(_file,_args,configuration)=>{assert.equal(configuration.env.CODEX_HOME,custom);return {status:0,stdout:JSON.stringify({installed:[row]})};};
 assert.equal(resolveSetupTarget(opts).target,target);
});
