import { app, BrowserWindow } from 'electron';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import koffi from 'koffi';
import { NativeWindows } from '../../src/windows/native.mjs';
import { encodeRegion } from '../../src/windows/shape.mjs';
app.whenReady().then(async()=>{
const user=koffi.load('user32.dll'),gdi=koffi.load('gdi32.dll'),kernel=koffi.load('kernel32.dll');
const Transform=koffi.struct('NoopTestTransform',{a:'float',b:'float',c:'float',d:'float',x:'float',y:'float'});
const create=gdi.func('intptr_t __stdcall CreateRectRgn(int left,int top,int right,int bottom)'),
  extended=gdi.func('intptr_t __stdcall ExtCreateRegion(NoopTestTransform *matrix,uint32_t count,void *data)'),
  get=user.func('int __stdcall GetWindowRgn(intptr_t window,intptr_t region)'),
  equal=gdi.func('bool __stdcall EqualRgn(intptr_t first,intptr_t second)'),
  combine=gdi.func('int __stdcall CombineRgn(intptr_t result,intptr_t first,intptr_t second,int mode)'),
  remove=gdi.func('bool __stdcall DeleteObject(intptr_t object)'),
  currentProcess=kernel.func('intptr_t __stdcall GetCurrentProcess()'),
  resources=user.func('uint32_t __stdcall GetGuiResources(intptr_t process,uint32_t flags)');
const win=new BrowserWindow({show:false,width:320,height:320,frame:false,transparent:true});
const native=new NativeWindows(),h=native.handle(win),result={};
try{
  await win.loadURL('data:text/html,<title>Isolated native region test</title>');
  console.log('native-test: move');
  const r=native.rect(h),size={width:r.right-r.left,height:r.bottom-r.top};
  assert.equal(native.move(h,{x:r.left+.1,y:r.top-.1,width:size.width+.1,height:size.height-.1}),false,'subpixel move with identical rounded bounds must be a no-op');
  assert.equal(native.move(h,{x:r.left+2.1,y:r.top+3.1,...size}),true);
  assert.equal(native.rect(h).left,r.left+2);assert.equal(native.rect(h).top,r.top+3);
  const resource={width:40,height:50,rects:[[2,3,12,10],[2,10,35,30],[15,30,29,46]]},bytes=encodeRegion(resource);
  const matrices=[[1,0,0,1,10.01,14.01],[1,0,0,1,10.02,14.02]];
  for(const mirror of [-1,1])for(const dpi of [.75,1,1.25,1.5,2])for(const squash of [.6,.88,1,1.16])matrices.push([mirror*dpi,0,0,dpi*squash,mirror<0?120.25:10.25,14.4]);
  let compared=0;
  const frame=native.rect(h);
  for(const clip of [null,{left:frame.left+5,top:frame.top+6,right:frame.left+90,bottom:frame.top+70}]){
    native.clip(h,clip);
    for(const m of matrices){
      assert.equal(native.updateShape(h,{resources:compared===0?{girl:resource}:null,matrices:{girl:m}}),true);
      const expected=extended({a:m[0],b:m[1],c:m[2],d:m[3],x:m[4],y:m[5]},bytes.length,bytes),actual=create(0,0,0,0);
      assert.ok(expected&&actual);
      try{
        if(clip){const p=native.rect(h),c=create(Math.max(0,clip.left-p.left),Math.max(0,clip.top-p.top),Math.min(size.width,clip.right-p.left),Math.min(size.height,clip.bottom-p.top));
          try{assert.notEqual(combine(expected,expected,c,1),0);}finally{remove(c);}}
        assert.notEqual(get(h,actual),0);assert.equal(equal(actual,expected),true,'installed region must match the original GDI transform exactly');compared++;
      }finally{remove(expected);remove(actual);}
    }
  }
  result.compared=compared;result.shape=native.shapeStatus(h);
  assert.ok(result.shape.equivalentUpdates>0,'equivalent final regions must skip the expensive redraw');
  const before=resources(currentProcess(),0);
  for(let n=0;n<1000;n++)native.updateShape(h,{matrices:{girl:[1,0,0,1,10+(n%2)*.01,14+(n%2)*.01]}});
  const after=resources(currentProcess(),0);
  assert.ok(after<=before+2,`GDI objects grew from ${before} to ${after}`);
  result.gdiObjects={before,after};
  fs.writeFileSync(path.join(process.argv[2],'native-noop-result.json'),JSON.stringify(result));
}catch(error){console.error(error.stack);process.exitCode=1;}
finally{native.close();win.destroy();app.exit(process.exitCode??0);}
});
