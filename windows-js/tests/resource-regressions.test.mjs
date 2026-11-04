import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import vm from 'node:vm';
import {normalizeSettings} from '../src/core/settings.mjs';import {layout,placement,resizeAnchors} from '../src/core/layout.mjs';import {FrameStats} from '../ui/frame-stats.mjs';

test('host process cache expires retired process IDs and stays bounded during window churn',()=>{
 const source=fs.readFileSync(new URL('../src/windows/native.mjs',import.meta.url),'utf8'),start=source.indexOf('  isCodex(h) {'),end=source.indexOf('  findCodex()',start);assert.ok(start>=0&&end>start);
 let now=0,opened=0,closed=0;const context={process:{pid:999999},Date:{now:()=>now},Buffer,readText:fn=>fn(),u:{long:(_h,index)=>index===-20?0x40000:0x10000,cls:()=> 'Chrome_WidgetWin_1',session:(_pid,output)=>output[0]=1,open(){opened++;return 1;},image:(_p,_flags,bytes,size)=>{const text='C:\\Apps\\OpenAI\\Codex\\Codex.exe';bytes.write(text,'utf16le');size[0]=text.length;return true;},close(){closed++;}}};
 vm.runInNewContext('globalThis.Probe=class { constructor(){this.session=1;this.processCache=new Map();}valid(){return true;}pid(h){return h;}title(){return "test";}'+source.slice(start,end)+'}',context);
 const probe=new context.Probe();assert.equal(probe.isCodex(1),true);probe.isCodex(1);assert.equal(opened,1,'live cache still avoids duplicate process handles');
 for(let pid=2;pid<=10000;pid++)probe.isCodex(pid);
 assert.ok(probe.processCache.size<=256,'process IDs must not accumulate for the full app lifetime');
 now=3000;probe.isCodex(20000);assert.equal(probe.processCache.size,1,'expired process IDs must be retired');assert.equal(opened,closed,'every temporary process handle closes');
 now=-100;probe.isCodex(20000);assert.equal(probe.processCache.size,1,'clock reversal must not retain an immortal entry');
});

test('DPI and host-size round trips cannot multiply saved character or bubble scale',()=>{
 const settings=normalizeSettings({layoutVersion:2,scale:0.6,bubbleScale:0.7,anchor:'free',side:'right',left:869.6,right:25.8,bottom:133}),baseline=structuredClone(settings);
 const full={left:0,top:0,right:1920,bottom:1080},small={left:0,top:0,right:640,bottom:480},original=placement(full,settings,1);
 for(let pass=0;pass<1000;pass++)for(const dpi of [1,1.25,1.5,2,1.5,1.25,1]){
  for(const frame of [small,full]){const position=placement(frame,settings,dpi);assert.equal(position.size,Math.round(378*0.7*dpi));assert.ok(Math.abs(layout(settings).girl.width*layout(settings).display-208*0.6)<1e-9);}
  assert.deepEqual(resizeAnchors(settings,{...settings}),baseline);
 }
 assert.deepEqual(settings,baseline);assert.deepEqual(placement(full,settings,1),original);
});

test('animation timing storage stays bounded across one million frames and idle gaps',()=>{
 const stats=new FrameStats();let now=0;
 for(let frame=0;frame<1000000;frame++){now+=1000/240;stats.sample(now,true);}
 assert.ok(stats.samples.length<=2402);assert.ok(stats.read().samples<=2402);
 stats.sample(now+60000,false);stats.sample(now+60001,true);stats.sample(now+60006,true);
 assert.ok(stats.samples.length<=2,'old samples expire after a long idle gap');
});

test('repeated native hit-region probes release every GDI object',{skip:process.platform!=='win32'},async()=>{
 const {default:koffi}=await import('koffi'),kernel=koffi.load('kernel32.dll'),user=koffi.load('user32.dll');
 const current=kernel.func('intptr_t __stdcall GetCurrentProcess()'),count=user.func('uint32_t __stdcall GetGuiResources(intptr_t process,uint32_t flags)'),{probeTransformedRegion}=await import('../src/windows/shape.mjs');
 const source={width:40,height:50,rects:[[2,3,12,10],[2,10,35,30],[15,30,29,46]]};probeTransformedRegion(source,[1,0,0,1,0,0],[[0,0]]);
 const before=count(current(),0);
 for(let n=0;n<5000;n++){const scale=[1,1.25,1.5,2][n%4];probeTransformedRegion(source,[(n%2?-1:1)*scale,0,0,scale,100,14],[[0,0],[100,30]]);}
 assert.equal(count(current(),0),before);
});
