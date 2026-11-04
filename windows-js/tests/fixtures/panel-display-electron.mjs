import {app,BrowserWindow,ipcMain,nativeTheme} from 'electron';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import {defaults} from '../../src/core/settings.mjs';

const source=fileURLToPath(new URL('../../',import.meta.url)),root=process.argv[2]??source;
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const checks=[],commands=[],rendererErrors=[];
const rasterScale=Number(process.env.PANEL_TEST_SCALE??1);
let window,phase='ready',state,failSettings=false;
const fatal=error=>{console.error(error?.stack??error);app.exit(1);};
process.on('uncaughtException',fatal);process.on('unhandledRejection',fatal);
const deadline=setTimeout(()=>fatal(Error('display fixture timed out: '+phase)),35000);
const record=(name,passed,details)=>checks.push({name,passed:!!passed,...(!passed?{details}:{})});
const debug=message=>{if(process.env.PANEL_DISPLAY_DEBUG)console.error(message);};
const evaluate=script=>window.webContents.executeJavaScript(script);
ipcMain.handle('fixture-ready',()=>state);
ipcMain.handle('fixture-command',(_event,name,value)=>{
  commands.push({name,value});
  if(name==='settings'){
    if(failSettings){failSettings=false;return {ok:false,error:'设置保存失败：测试长错误提示，请重试并检查配置目录是否可以写入。'};}
    Object.assign(state.settings,value);
  }
  return {ok:true};
});
async function load(kind,width=880,height=650,placement={}){
  phase=kind+' '+width+'x'+height;
  debug('load '+phase);
  window.setContentSize(width,height);
  state={kind,settings:{...defaults},scene:{collapsed:true,mode:'quota'},music:false,version:'fixture',update:{automatic:true,status:'current',message:'当前已是最新版本'},lines:'测试语录',audio:{mode:'builtin',press:null,release:null,errors:{}},characters:[],removed:[],placement:{mainOffset:width>=650?350:0,rootWidth:Math.min(328,width),submenuWidth:Math.max(180,Math.min(300,width-Math.min(328,width)-4)),maxHeight:height,anchorY:height-50,direction:'left',...placement}};
  await window.loadFile(path.join(root,'ui/panel.html'));
  await window.webContents.debugger.sendCommand('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:rasterScale,mobile:false});
  for(let n=0;n<100;n++){
    if(await evaluate('document.querySelector("#panel").children.length>0'))break;
    await pause(10);
  }
  await evaluate('document.fonts.ready');
  await pause(210);
  debug('loaded '+phase);
}
async function geometry(){return evaluate(`(()=>{
  const rect=node=>{const r=node.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height,scrollWidth:node.scrollWidth,clientWidth:node.clientWidth};};
  const surfaces=Array.from(document.querySelectorAll('body.menu main,details[open]>.flyout')).map(rect);
  return {surfaces,width:innerWidth,height:innerHeight,overflow:surfaces.some(r=>r.x<-.5||r.y<-.5||r.x+r.width>innerWidth+.5||r.y+r.height>innerHeight+.5||r.scrollWidth>r.clientWidth+1)};
})()`);}
async function group(key){await evaluate(`Array.from(document.querySelectorAll('details')).find(node=>node.dataset.key===${JSON.stringify(key)}).querySelector('summary').click()`);await pause(190);}
async function main(){try{
  await app.whenReady();
  window=new BrowserWindow({show:false,width:880,height:650,frame:false,webPreferences:{offscreen:true,contextIsolation:true,backgroundThrottling:false,preload:path.join(source,'tests/fixtures/panel-interaction-preload.cjs')}});
  window.webContents.debugger.attach('1.3');
  window.webContents.on('console-message',(_event,...args)=>{const entry=typeof args[0]==='object'?args[0]:{level:args[0],message:args[1]};if(entry.level==='error'||entry.level===3)rendererErrors.push(entry.message);});
  const groups=['形象与大小','声音与点击','显示与位置','语录与提醒','版本与更新'];
  for(const [width,height,direction]of [[880,650,'left'],[956,730,'right'],[650,330,'left'],[380,330,'right'],[280,240,'left'],[180,160,'right']]){
    await load('menu',width,height,{direction,mainOffset:direction==='right'?0:width>=650?width-328:0});
    let bounds=await geometry();record(`root fits ${width}x${height} ${direction}`,!bounds.overflow,bounds);
    for(const key of groups){await group(key);bounds=await geometry();record(`${key} fits ${width}x${height} ${direction}`,!bounds.overflow,bounds);}
  }
  phase='animation setup';debug(phase);
  await window.webContents.debugger.sendCommand('Emulation.setEmulatedMedia',{features:[{name:'prefers-reduced-motion',value:'no-preference'}]});
  await load('menu');phase='animation';debug(phase);
  const animation=await evaluate(`(()=>{
    const group=document.querySelector('details');group.querySelector('summary').click();
    const flyout=group.querySelector('.flyout'),rect=node=>{const r=node.getBoundingClientRect();return [r.x,r.y,r.width,r.height];};
    const surfaces=[document.getElementById('panel'),flyout],initial=surfaces.map(rect),animations=document.getAnimations();
    animations.forEach(animation=>animation.pause());
    let stable=true,hits=true;
    for(const time of [0,20,60,100,140,180,240]){
      animations.forEach(animation=>animation.currentTime=time);
      stable&&=JSON.stringify(surfaces.map(rect))===JSON.stringify(initial);
      for(const button of flyout.querySelectorAll('button,input:not(:disabled)')){
        const r=button.getBoundingClientRect(),hit=document.elementFromPoint(r.x+r.width/2,r.y+r.height/2);
        hits&&=hit===button||button.contains(hit);
      }
    }
    return {stable,hits,animations:animations.length,reducedMotion:matchMedia('(prefers-reduced-motion:reduce)').matches,animationName:getComputedStyle(flyout).animationName};
  })()`);
  record('animation preserves native surface bounds and control hit areas',animation.stable&&animation.hits&&animation.animations>0,animation);
  phase='rapid switching';debug(phase);
  const rapid=await evaluate(`(async()=>{
    const groups=Array.from(document.querySelectorAll('details'));
    for(let n=0;n<30;n++)groups[n%groups.length].querySelector('summary').click();
    await new Promise(resolve=>setTimeout(resolve,250));
    return {open:document.querySelectorAll('details[open]').length,running:document.getAnimations().filter(animation=>animation.playState==='running').length};
  })()`);
  record('rapid submenu changes leave one menu and no running animation',rapid.open===1&&rapid.running===0,rapid);
  await load('menu');await group(groups[0]);
  phase='hover';
  debug(phase);
  const hover=await evaluate(`(async()=>{
    const wait=ms=>new Promise(r=>setTimeout(r,ms)),groups=Array.from(document.querySelectorAll('details'));
    groups[1].dispatchEvent(new MouseEvent('mouseenter'));await wait(45);
    const delayed=groups[0].open&&!groups[1].open;
    groups[1].dispatchEvent(new MouseEvent('mouseleave'));await wait(140);
    const cancelled=groups[0].open&&!groups[1].open;
    groups[1].dispatchEvent(new MouseEvent('mouseenter'));await wait(160);
    const switched=groups[1].open&&!groups[0].open;
    groups[2].dispatchEvent(new MouseEvent('mouseenter'));window.dispatchEvent(new Event('blur'));await wait(160);
    const blurCancelled=groups[1].open&&!groups[2].open;
    return {delayed,cancelled,switched,blurCancelled};
  })()`);
  for(const [name,passed]of Object.entries(hover))record('hover '+name,passed,hover);
  phase='feedback';failSettings=true;
  debug(phase);
  await evaluate(`document.querySelector('[data-focus-key="setting:soundOn"]').click()`);await pause(120);
  const feedback=await evaluate(`(()=>{const node=document.getElementById('feedback'),r=node.getBoundingClientRect(),panel=document.getElementById('panel'),p=panel.getBoundingClientRect();return {text:node.textContent,parent:node.parentElement.id,rect:{x:r.x,y:r.y,width:r.width,height:r.height},inside:node.textContent.length>0&&r.x>=p.x&&r.right<=p.right&&r.y>=p.y&&r.bottom<=p.bottom,scrollWidth:node.scrollWidth,clientWidth:node.clientWidth};})()`);
  record('menu error remains inside shaped surface',feedback.inside&&feedback.scrollWidth<=feedback.clientWidth+1,feedback);
  const framed=new BrowserWindow({show:false,width:440,height:330,frame:true,webPreferences:{offscreen:true}});
  const minimumClient=framed.getContentSize();framed.destroy();
  for(const kind of ['quotes','colors'])for(const [width,height]of [[540,480],[440,330],minimumClient]){
    await load(kind,width,height);
    const editor=await evaluate(`(()=>{const p=document.getElementById('panel'),textarea=document.querySelector('textarea'),buttons=Array.from(p.querySelectorAll('button')),inside=buttons.every(node=>{const r=node.getBoundingClientRect();return r.x>=0&&r.right<=innerWidth&&r.top>=0&&r.bottom<=innerHeight;});return {inside,height:innerHeight,textareaHeight:textarea.clientHeight,bodyHeight:document.documentElement.scrollHeight,lastButtonBottom:buttons.at(-1).getBoundingClientRect().bottom};})()`);
    record(`${kind} actions visible ${width}x${height}`,editor.inside&&editor.textareaHeight>=80,editor);
    await evaluate(`document.getElementById('feedback').textContent='保存失败：请检查内容后重试。'.repeat(3)`);await pause(40);
    const error=await evaluate(`(()=>{const node=document.getElementById('feedback'),r=node.getBoundingClientRect(),save=document.querySelector('[data-action$="-save"]').getBoundingClientRect();return {visible:r.top>=0&&r.bottom<=innerHeight&&save.bottom<=innerHeight,feedbackBottom:r.bottom,saveBottom:save.bottom,height:innerHeight};})()`);
    record(`${kind} error and save visible ${width}x${height}`,error.visible,error);
  }
  phase='accessibility media';
  debug(phase);
  await load('menu');
  await window.webContents.debugger.sendCommand('Emulation.setEmulatedMedia',{features:[{name:'prefers-reduced-motion',value:'reduce'},{name:'prefers-reduced-transparency',value:'reduce'}]});
  await group(groups[0]);
  const media=await evaluate(`(()=>({reducedMotion:matchMedia('(prefers-reduced-motion:reduce)').matches,reducedTransparency:matchMedia('(prefers-reduced-transparency:reduce)').matches,animations:document.getAnimations().filter(a=>a.playState==='running').length,backdrop:getComputedStyle(document.getElementById('panel'),'::before').backdropFilter,transition:getComputedStyle(document.querySelector('input[type=checkbox]')).transitionDuration}))()`);
  record('reduced motion and transparency honoured',media.reducedMotion&&media.reducedTransparency&&media.animations===0&&media.backdrop==='none'&&media.transition==='0s',media);
  await window.webContents.debugger.sendCommand('Emulation.setEmulatedMedia',{features:[]});
  nativeTheme.themeSource='dark';await load('menu');await group(groups[0]);
  const dark=await evaluate(`({dark:matchMedia('(prefers-color-scheme:dark)').matches,ink:getComputedStyle(document.body).color})`);record('dark theme switches text',dark.dark&&dark.ink==='rgb(238, 233, 245)',dark);
  record('no renderer errors',rendererErrors.length===0,rendererErrors);
  record('all windows stayed hidden',BrowserWindow.getAllWindows().every(w=>!w.isVisible()));
  console.log(JSON.stringify({dpi:await evaluate('devicePixelRatio'),checks}));
}catch(error){console.error(error.stack);process.exitCode=1;}
finally{clearTimeout(deadline);if(window&&!window.isDestroyed())window.destroy();app.quit();}}
void main();
