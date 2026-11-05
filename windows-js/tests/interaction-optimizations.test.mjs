import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import vm from 'node:vm';
import {fileURLToPath} from 'node:url';
import sharp from 'sharp';
import {alphaBounds} from '../ui/shape.mjs';
import {defaults,SettingsStore} from '../src/core/settings.mjs';
import {Characters} from '../src/core/characters.mjs';
import {QuoteStore} from '../src/core/quotes.mjs';
const app=fileURLToPath(new URL('../',import.meta.url));
function temporary(t){const dir=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-interaction-opt-'));t.after(()=>{assert.equal(path.dirname(dir),path.resolve(os.tmpdir()));fs.rmSync(dir,{recursive:true,force:true});});return dir;}
test('unchanged settings keep their file and original backup through repeated clicks',t=>{
  const dir=temporary(t),file=path.join(dir,'settings.json'),original=JSON.stringify({...defaults,unknownPersonal:{keep:true}});
  fs.writeFileSync(file,original);fs.writeFileSync(file+'.bak','preserve previous backup');fs.utimesSync(file,new Date(2020,0,1),new Date(2020,0,1));
  const before=fs.statSync(file).mtimeMs,store=new SettingsStore(file);
  for(let n=0;n<500;n++)store.save({});
  assert.equal(fs.statSync(file).mtimeMs,before);assert.equal(fs.readFileSync(file+'.bak','utf8'),'preserve previous backup');
  store.save({scale:1.2});const changed=fs.statSync(file).mtimeMs;
  for(let n=0;n<500;n++)store.save({scale:1.2});
  assert.equal(fs.statSync(file).mtimeMs,changed);assert.equal(fs.readFileSync(file+'.bak','utf8'),original);
  assert.deepEqual(JSON.parse(fs.readFileSync(file)).unknownPersonal,{keep:true});
});
test('opaque bounds match the full pixel scan and valid faint characters keep positive geometry',()=>{
  let seed=42;const next=()=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed;};
  for(let sample=0;sample<100;sample++){
    const w=13,h=29,bytes=new Uint8Array(w*h*4);
    for(let n=3;n<bytes.length;n+=4)bytes[n]=next()%5===0?(sample%3?255:11):0;
    const brute=threshold=>{const points=[];for(let y=0;y<h;y++)for(let x=0;x<w;x++)if(bytes[(y*w+x)*4+3]>threshold)points.push([x,y]);if(!points.length)return null;const left=Math.min(...points.map(p=>p[0])),top=Math.min(...points.map(p=>p[1])),right=Math.max(...points.map(p=>p[0])),bottom=Math.max(...points.map(p=>p[1]))+1;return {left,top,width:right-left+1,height:bottom-top,bottom};};
    assert.deepEqual(alphaBounds(bytes,w,h),brute(12)??brute(10));
  }
  const bytes=new Uint8Array(8*32*4).fill(11);assert.deepEqual(alphaBounds(bytes,8,32),{left:0,top:0,width:8,height:32,bottom:32});
  assert.equal(alphaBounds(new Uint8Array(64),4,4),null);
});
test('large opaque character bounds inspect only the two edges of each row',()=>{
  const size=2048,bytes=new Uint8Array(size*size*4).fill(255);let reads=0;
  const pixels=new Proxy(bytes,{get:(target,name)=>{if(/^\d+$/.test(String(name)))reads++;return target[name];}});
  assert.deepEqual(alphaBounds(pixels,size,size),{left:0,top:0,width:size,height:size,bottom:size});assert.equal(reads,size*2);
});
test('character display shares concurrent decodes and invalidates the cache after an edit',async t=>{
  const dir=temporary(t),file=path.join(dir,'sample.png'),characters=new Characters(app,dir),row={id:'fixture',name:'我的形象',path:file};
  const image=background=>sharp({create:{width:32,height:48,channels:4,background}}).png().toBuffer();
  fs.writeFileSync(file,await image('#aa99bb'));const read=fs.readFileSync;let reads=0;
  fs.readFileSync=function(name,...args){if(path.resolve(String(name))===file)reads++;return read.call(this,name,...args);};
  try{
    const [a,b]=await Promise.all([characters.display(row),characters.display(row)]);await characters.display(row);assert.equal(reads,1);assert.equal(a.url,b.url);
    fs.writeFileSync(file,await image('#7799aa'));const changed=await characters.display({...row,name:'重命名'});assert.equal(reads,2);assert.notEqual(changed.url,a.url);assert.equal(changed.name,'重命名');
  }finally{fs.readFileSync=read;}
});
test('concurrent character and audio actions open one file dialog and release the busy gate',async()=>{
  const code=fs.readFileSync(path.join(app,'src/main.mjs'),'utf8'),start=code.indexOf('  ipcMain.handle("command",'),end=code.indexOf('  native.listen(',start);let handler,resolvePick,dialogs=0,imports=0;
  const c={ipcMain:{handle:(_name,callback)=>handler=callback},trusted:()=>true,editorBusy:false,editor:null,bench:null,win:{},URL,
    dialog:{showOpenDialog:()=>{dialogs++;return new Promise(resolve=>resolvePick=resolve);}},runIo:async()=>{imports++;return {id:'custom'};},characters:{display:async()=>({id:'custom',url:'fixture'})},activeImage:{id:'old'},lastImage:'',settings:{},setMusic(){},save(){}};
  c.galleryImages=new Map();
  vm.createContext(c);vm.runInContext(code.slice(start,end),c);const event={sender:{id:1}};
  const first=handler(event,'character-import');const second=await handler(event,'audio-import','press');
  assert.equal(dialogs,1);assert.equal(second.ok,false);assert.match(second.error,/上一个文件/);
  resolvePick({canceled:false,filePaths:['sample.png']});assert.equal((await first).ok,true);assert.equal(imports,1);assert.equal(c.editorBusy,false);
  const canceled=handler(event,'character-import');resolvePick({canceled:true});assert.equal((await canceled).ok,true);assert.equal(c.editorBusy,false);
});
test('gallery preparation cannot create duplicate editors and failure releases the blocked state',async()=>{
  const code=fs.readFileSync(path.join(app,'src/main.mjs'),'utf8'),start=code.indexOf('  async function openEditor(kind)'),end=code.indexOf('  function trusted(',start);
  let finish,prepared=0,created=0;
  class Window{constructor(){created++;}on(){}async loadFile(){}show(){}isDestroyed(){return false;}focus(){}}
  const c={candidate:false,args:[],stopping:false,openingEditor:false,editor:null,menu:null,blocked:false,resetSchedule(){},send(){},prepareGallery:()=>{prepared++;return new Promise(resolve=>finish=resolve);},BrowserWindow:Window,path,root:app,verifySuite:false};
  c.unblock=()=>{c.blocked=!!c.editor;};vm.createContext(c);vm.runInContext(code.slice(start,end),c);
  const first=c.openEditor('characters');await c.openEditor('characters');assert.equal(prepared,1);assert.equal(created,0);finish();await first;assert.equal(created,1);assert.equal(c.openingEditor,false);
  c.editor=null;c.prepareGallery=async()=>{throw Error('injected gallery failure');};await assert.rejects(c.openEditor('characters'),/gallery failure/);assert.equal(c.blocked,false);assert.equal(c.openingEditor,false);
});
test('quote selection reuses parsed content without hiding external edits or leaking mutable rows',t=>{
  const dir=temporary(t),file=path.join(dir,'quotes.json'),store=new QuoteStore(dir,path.join(app,'assets'),()=>0);
  fs.writeFileSync(file,JSON.stringify({quotes:['a','b']}));const read=fs.readFileSync;let reads=0;
  fs.readFileSync=function(name,...args){if(path.resolve(String(name))===file)reads++;return read.call(this,name,...args);};
  try{
    for(let n=0;n<100;n++)assert.equal(store.next(),n%2?'b':'a');assert.equal(reads,1);
    store.list().quotes[0].text='mutated';assert.equal(store.list().quotes[0].text,'a');
    fs.writeFileSync(file,JSON.stringify({quotes:['changed']}));assert.equal(store.next(),'changed');assert.equal(reads,2);
  }finally{fs.readFileSync=read;}
});
test('oversized quote edits preserve the prior custom file and backup',t=>{
  const dir=temporary(t),file=path.join(dir,'quotes.json'),store=new QuoteStore(dir,path.join(app,'assets'));
  store.save(['keep this']);fs.writeFileSync(file+'.bak','keep backup');const before=fs.readFileSync(file);
  assert.throws(()=>store.save(Array.from({length:5001},(_,n)=>'台词 '+n)),/5000/);
  assert.throws(()=>store.save(Array.from({length:2500},(_,n)=>n+'：'+'自'.repeat(180))),/1 MB/);
  assert.deepEqual(fs.readFileSync(file),before);assert.equal(fs.readFileSync(file+'.bak','utf8'),'keep backup');
});

test('late renderer messages cannot access a destroyed widget or run after shutdown starts',()=>{
  const code=fs.readFileSync(path.join(app,'src/main.mjs'),'utf8'),start=code.indexOf('  function widgetEvent('),end=code.indexOf('  ipcMain.handle("command",',start);
  assert.ok(start>=0&&end>start);
  const listeners=new Map(),handles=new Map(),contents={id:42};let destroyed=false,accesses=0,cursorReads=0;
  const win={isDestroyed:()=>destroyed,get webContents(){accesses++;if(destroyed)throw TypeError('Object has been destroyed');return contents;}};
  const c={ipcMain:{on:(name,fn)=>listeners.set(name,fn),handle:(name,fn)=>handles.set(name,fn)},win,stopping:false,
    native:{cursor:()=>{cursorReads++;return {x:1,y:2};},rect:()=>({left:0,top:0})},handle:7};
  vm.createContext(c);vm.runInContext(code.slice(start,end),c);
  const live={sender:contents};assert.equal(handles.get('pointer')(live).cursor.x,1);assert.equal(cursorReads,1);
  listeners.get('frame-timing')(live,{frames:10});assert.equal(vm.runInContext('frameTiming.frames',c),10);
  for(const closing of ['destroyed','stopping']){
    destroyed=closing==='destroyed';c.stopping=closing==='stopping';const before=accesses;
    for(const [name,fn]of listeners)assert.doesNotThrow(()=>fn(live,{op:'arm',x:0,y:0}),name+' '+closing);
    assert.equal(handles.get('pointer')(live),null);assert.equal(accesses,before);assert.equal(cursorReads,1);
    assert.equal(vm.runInContext('frameTiming.frames',c),10);
  }
  c.stopping=false;destroyed=false;
  for(const [name,fn]of listeners)assert.doesNotThrow(()=>fn({sender:{id:42}},{op:'arm',x:0,y:0}),name+' foreign sender');
});
