import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {Scene} from '../src/core/scene.mjs';

test('open menu follows bubble automatic dismissal and content changes',()=>{
 const source=fs.readFileSync(new URL('../src/main.mjs',import.meta.url),'utf8');
 const start=source.indexOf('  let phaseTimer = null;'),end=source.indexOf('  scene.on("refresh", refresh);',start);
 assert.ok(start>=0&&end>start);
 let now=1000,destroyed=false,menuState=null;
 const scene=new Scene({settings:{},quote:()=> 'test quote',now:()=>now});
 const context={scene,resetSchedule(){},clearTimeout(){},setTimeout(){return 1;},sizePreview:false,dismissCompletion(){},settingsStore:{loadFailed:false,save(){}},send(){},Date:{now:()=>now},menu:{isDestroyed:()=>destroyed,webContents:{send(channel,state){assert.equal(channel,'state');menuState=state;}}},dialogState:()=>scene.snapshot()};
 vm.runInNewContext(source.slice(start,end),context);
 scene.show('quota',{animate:false});assert.equal(menuState.collapsed,false);assert.equal(menuState.mode,'quota');
 now+=6000;scene.tick();assert.equal(menuState.collapsed,true,'menu must stop offering to hide an already dismissed bubble');
 scene.show('quote');assert.equal(menuState.mode,'quote');assert.equal(menuState.text,'test quote');
 destroyed=true;menuState=null;scene.hide();assert.equal(menuState,null,'closed menu is not messaged');
 context.menu=null;assert.doesNotThrow(()=>scene.show('quota'));
});

test('temporary settings-write failure cannot abort a bubble or its automatic dismissal',()=>{
 const source=fs.readFileSync(new URL('../src/main.mjs',import.meta.url),'utf8');
 const start=source.indexOf('  let phaseTimer = null;'),end=source.indexOf('  scene.on("refresh", refresh);',start);
 let now=1000,failed=true,rendered=0,menuState=null;const diagnostic=[];
 const scene=new Scene({settings:{},quote:()=> 'test quote',now:()=>now});
 const context={scene,resetSchedule(){},clearTimeout(){},setTimeout(){return 1;},sizePreview:false,dismissCompletion(){},settingsStore:{loadFailed:false,save(){if(failed)throw Object.assign(Error('injected settings write failure'),{code:'ENOSPC'});}},send(){rendered++;},Date:{now:()=>now},menu:{isDestroyed:()=>false,webContents:{send(_channel,value){menuState=value;}}},dialogState:()=>scene.snapshot(),fs:{appendFileSync(_file,message){diagnostic.push(message);}},path:{join:(...parts)=>parts.join('/')},dataDir:'fixture'};
 vm.runInNewContext(source.slice(start,end),context);
 assert.doesNotThrow(()=>scene.show('quota',{animate:false}));assert.equal(menuState.collapsed,false);
 now+=6000;assert.doesNotThrow(()=>scene.tick());assert.equal(menuState.collapsed,true);assert.ok(rendered>=2);assert.ok(diagnostic.some(line=>line.includes('injected settings write failure')));
 context.fs.appendFileSync=()=>{throw Error('log also unavailable');};assert.doesNotThrow(()=>scene.show('quote'));
 failed=false;assert.doesNotThrow(()=>scene.hide());assert.equal(menuState.collapsed,true);
});
