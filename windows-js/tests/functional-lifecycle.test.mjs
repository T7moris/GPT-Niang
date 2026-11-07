import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import path from 'node:path';import vm from 'node:vm';import {EventEmitter} from 'node:events';import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url)),code=fs.readFileSync(path.join(root,'src/main.mjs'),'utf8');
test('failure while preparing an editor keeps the menu available to show the error',async()=>{
 const start=code.indexOf('  async function openEditor(kind)'),end=code.indexOf('  function trusted(',start);let closed=false;
 const c={stopping:false,menu:{close(){closed=true;c.menu=null;}},editor:null,openingEditor:false,blocked:false,resetSchedule(){},send(){},prepareGallery:async()=>{throw Error('gallery failure');},unblock(){c.blocked=!!c.menu;}};
 vm.createContext(c);vm.runInContext(code.slice(start,end),c);await assert.rejects(c.openEditor('characters'),/gallery failure/);assert.equal(closed,false);assert.ok(c.menu);assert.equal(c.blocked,true);assert.equal(c.openingEditor,false);
});
test('failed color-list persistence keeps the active custom triggers unchanged',async()=>{
 const start=code.indexOf('} else if (name === "colors-save") {'),end=code.indexOf('} else if (name === "character-select") {',start),c={colors:{triggers:['原触发词']},normalizeQuotes:rows=>rows.map(text=>({text})),path,dataDir:'unused',writeJson(){throw Error('disk unavailable');},send(){}};
 vm.createContext(c);vm.runInContext('async function command(name,value){if(false){'+code.slice(start,end)+'}}',c);await assert.rejects(c.command('colors-save','新的触发词'),/disk unavailable/);assert.deepEqual(c.colors.triggers,['原触发词']);
});
test('a usage window creation failure stops accounting and preserves the menu for retry',async()=>{
 const start=code.indexOf('  async function openEditor(kind)'),end=code.indexOf('  function trusted(',start);let started=0,closed=0;
 const menu={close(){throw Error('menu must remain available');}};
 const c={stopping:false,menu,editor:null,openingEditor:false,blocked:false,resetSchedule(){},send(){},unblock(){c.blocked=!!c.menu;},
  usageService:{start(){started++;},close(){closed++;}},path,root,candidate:false,
  BrowserWindow:class{constructor(){throw Error('window creation failed');}}};
 vm.createContext(c);vm.runInContext(code.slice(start,end),c);
 await assert.rejects(c.openEditor('usage'),/window creation failed/);
 assert.equal(started,1);assert.equal(closed,1);assert.equal(c.editor,null);assert.equal(c.menu,menu);assert.equal(c.openingEditor,false);
});
test('a file worker exiting cleanly without a result releases the pending operation',async()=>{
 const start=code.indexOf('  function runIo(kind, value)'),end=code.indexOf('  const quoteLayouts =',start);
 class Worker extends EventEmitter{constructor(){super();queueMicrotask(()=>this.emit('exit',0));}}
 const c={Worker,path,root,dataDir:'unused',ioWorkers:new Set(),setTimeout,clearTimeout};vm.createContext(c);vm.runInContext(code.slice(start,end),c);
 const result=await Promise.race([c.runIo('character',{}).then(()=>({ok:true}),error=>({error:error.message})),new Promise(resolve=>setTimeout(()=>resolve({timedOut:true}),80))]);
 assert.equal(result.timedOut,undefined);assert.match(result.error,/文件处理未完成/);assert.equal(c.ioWorkers.size,0);
});
test('an invalid file-worker reply reports failure without crashing the main window',async()=>{
 const start=code.indexOf('  function runIo(kind, value)'),end=code.indexOf('  const quoteLayouts =',start);let worker;
 class Worker extends EventEmitter{constructor(){super();worker=this;}}
 const c={Worker,path,root,dataDir:'unused',ioWorkers:new Set(),setTimeout,clearTimeout};vm.createContext(c);vm.runInContext(code.slice(start,end),c);
 const result=c.runIo('character',{});assert.doesNotThrow(()=>worker.emit('message',undefined));await assert.rejects(result,/文件处理未完成/);assert.equal(c.ioWorkers.size,0);
});
