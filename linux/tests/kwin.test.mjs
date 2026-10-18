import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const source=fs.readFileSync(new URL('../kwin/follow.js',import.meta.url),'utf8');

function fixture({old=false,screenX=0}={}){
  const desktop={id:'desk1'};
  const screen={name:'test',geometry:{x:screenX,y:0,width:1920,height:1080}};
  const make=(id,overrides={})=>({internalId:id,normalWindow:true,resourceClass:'app',desktopFileName:'',caption:'app',frameGeometry:{x:screenX+50,y:50,width:1000,height:700},desktops:[desktop],activities:[],output:screen,...overrides});
  const target=make('target',{resourceClass:'codex',active:true});
  const pet=make('pet',{resourceClass:'org.quickshell',caption:'GPT娘 · KDE 挂件',frameGeometry:{x:0,y:0,width:280,height:362}});
  const constraints=[];const raised=[];
  const workspace={stackingOrder:[target,pet],activeWindow:target,currentDesktop:desktop,currentActivity:'a',screens:[screen],cursorPos:{x:500,y:500},clientArea:()=>screen.geometry,raiseWindow(w){raised.push(w);this.stackingOrder=this.stackingOrder.filter(x=>x!==w).concat(w);}};
  if(!old){workspace.constrain=(a,b)=>constraints.push([a,b]);workspace.unconstrain=(a,b)=>{const i=constraints.findIndex(x=>x[0]===a&&x[1]===b);if(i>=0)constraints.splice(i,1);};}
  let pending,last;
  vm.runInNewContext(source,{workspace,KWin:{PlacementArea:0},callDBus(service,p,iface,method,data,callback){last=JSON.parse(data);pending=callback;}});
  const settings={mode:'follow',scale:1,alwaysOnTop:false,desktop:{x:null,y:null},follow:{edge:'right',bottom:16}};
  return {workspace,target,pet,make,constraints,raised,settings,step(patch={}){const cb=pending;cb(JSON.stringify({settings,...patch}));return last;},get state(){return last;}};
}

test('follow positions in logical pixels and does not keep the widget above other apps',()=>{
  const f=fixture();const cover=f.make('cover');f.workspace.stackingOrder=[f.target,cover,f.pet];
  f.step();f.step();
  assert.equal(f.pet.frameGeometry.x,758);assert.equal(f.pet.frameGeometry.y,372);
  assert.equal(f.pet.keepAbove,false);assert.equal(f.pet.skipTaskbar,true);assert.equal(f.pet.noBorder,true);
  assert.ok(f.constraints.some(([a,b])=>a===f.target&&b===f.pet));
  assert.ok(f.constraints.some(([a,b])=>a===f.pet&&b===cover));
  assert.ok(f.workspace.stackingOrder.indexOf(f.pet)<f.workspace.stackingOrder.indexOf(cover));
});

test('minimization, desktops, activities and closure change visibility without stealing focus',()=>{
  const f=fixture();
  f.target.minimized=true;assert.equal(f.step().target.visible,false);
  f.target.minimized=false;f.target.desktops=[{id:'other'}];assert.equal(f.step().target.visible,false);
  f.target.desktops=[];f.target.activities=['other'];assert.equal(f.step().target.visible,false);
  f.target.activities=[];assert.equal(f.step().target.visible,true);
  f.workspace.stackingOrder=[f.pet];f.workspace.activeWindow=null;assert.equal(f.step().target,null);
  assert.equal(f.workspace.activeWindow,null);
});

test('a browser title is never treated as the app; Linux ChatGPT package is recognized',()=>{
  const f=fixture();f.target.resourceClass='google-chrome';f.target.caption='Codex - ChatGPT';
  f.workspace.stackingOrder=[f.target,f.pet];f.workspace.activeWindow=f.target;
  // Existing selection is retained; use a new mock context to test first discovery.
  const workspace={...f.workspace,stackingOrder:[f.target,f.pet]};let state;
  vm.runInNewContext(source,{workspace,KWin:{PlacementArea:0},callDBus(s,p,i,m,data){state=JSON.parse(data);}});
  assert.equal(state.target,null);
  f.target.resourceClass='Chatgpt';
  vm.runInNewContext(source,{workspace,KWin:{PlacementArea:0},callDBus(s,p,i,m,data){state=JSON.parse(data);}});
  assert.equal(state.target.id,'target');
});

test('negative monitor coordinates, left attachment and desktop position recovery work',()=>{
  const f=fixture({screenX:-1920});f.settings.follow.edge='left';f.step();
  assert.equal(f.pet.frameGeometry.x,-1858);
  f.settings.mode='desktop';f.settings.desktop={x:8000,y:8000};f.step();
  assert.equal(f.pet.frameGeometry.x,-280);assert.equal(f.pet.frameGeometry.y,718);
  assert.equal(f.constraints.length,0);assert.equal(f.pet.desktops.length,0);
});

test('Plasma 6 before stacking constraints restores the existing window order',()=>{
  const f=fixture({old:true});const cover=f.make('cover');f.workspace.stackingOrder=[f.target,cover,f.pet];
  f.step();f.step();
  assert.equal(f.state.stacking,'raise-order');
  assert.ok(f.workspace.stackingOrder.indexOf(f.target)<f.workspace.stackingOrder.indexOf(f.pet));
  assert.ok(f.workspace.stackingOrder.indexOf(f.pet)<f.workspace.stackingOrder.indexOf(cover));
  assert.ok(f.raised.length<=2);
});

test('drag follows the global pointer and switches back to saved follow placement',()=>{
  const f=fixture();f.step({drag:{x:20,y:40}});
  assert.equal(f.pet.frameGeometry.x,480);assert.equal(f.pet.frameGeometry.y,460);
  f.step();assert.equal(f.pet.frameGeometry.x,758);assert.equal(f.pet.frameGeometry.y,372);
});

test('a native widget destroyed during the asynchronous exchange is not dereferenced',()=>{
  const f=fixture();
  Object.defineProperty(f.pet,'noBorder',{set(){throw new Error('Use after window removal');}});
  f.workspace.stackingOrder=[f.target];
  assert.doesNotThrow(()=>f.step());
  assert.equal(f.state.widget,null);
});
