import {app,BrowserWindow,ipcMain} from 'electron';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import {defaults} from '../../src/core/settings.mjs';
const commands=[];
const fatal=error=>{console.error(error?.stack??error);app.exit(1);};
process.on('uncaughtException',fatal);process.on('unhandledRejection',fatal);
const uiRoot=process.argv[2]??fileURLToPath(new URL('../../',import.meta.url));
const state={kind:'menu',settings:{...defaults},scene:{collapsed:true,mode:'quota'},music:false,update:{automatic:true},version:'fixture',verificationSection:'形象与大小'};
let window;
let phase='ready';
ipcMain.handle('fixture-ready',()=>state);
ipcMain.handle('fixture-command',async(_event,name,value)=>{
  commands.push({name,value});
  if(name==='fixture-clear-section')state.verificationSection=null;
  if(name==='fixture-busy')window.webContents.send('fixture-busy',value);
  if(name==='settings'){
    Object.assign(state.settings,value);
    window.webContents.send('fixture-state',state);
    await new Promise(resolve=>setTimeout(resolve,25));
  }
  return {ok:true};
});
const timer=setTimeout(()=>{console.error('panel fixture timed out: '+phase);app.exit(1);},12000);
async function main(){
try{
  await app.whenReady();
  phase='window';
  window=new BrowserWindow({show:false,width:1100,height:800,webPreferences:{contextIsolation:true,backgroundThrottling:false,preload:fileURLToPath(new URL('./panel-interaction-preload.cjs',import.meta.url))}});
  window.webContents.on('console-message',(_event,level,message)=>{if(level>=3)console.error(message);});
  await window.loadFile(path.join(uiRoot,'ui','panel.html'));
  phase='keyboard';
  const keyboard=await window.webContents.executeJavaScript(`(async()=>{
    const wait=ms=>new Promise(r=>setTimeout(r,ms));
    for(let n=0;n<100&&!document.querySelector('input[type=range]');n++)await wait(10);
    let input=document.querySelector('input[type=range]');input.focus();
    input.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true}));
    input.value='1.1';input.dispatchEvent(new Event('input',{bubbles:true}));
    await wait(130);
    const during=document.activeElement===input&&input.isConnected;
    input.dispatchEvent(new KeyboardEvent('keyup',{key:'ArrowRight',bubbles:true}));
    await wait(100);
    return {during,after:document.activeElement===document.querySelector('input[type=range]'),value:document.querySelector('input[type=range]').value};
  })()`);
  const before=commands.length;
  phase='escape';
  const escape=await window.webContents.executeJavaScript(`(async()=>{
    const wait=ms=>new Promise(r=>setTimeout(r,ms)),input=document.querySelector('input[type=range]');
    input.dispatchEvent(new PointerEvent('pointerdown',{pointerId:1,bubbles:true}));
    input.value='1.2';input.dispatchEvent(new Event('input',{bubbles:true}));
    document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));
    await wait(150);
    return {opacity:document.body.style.opacity,value:document.querySelector('input[type=range]').value};
  })()`);
  const escapeCommands=commands.slice(before).filter(c=>['settings','size-preview','close-panel'].includes(c.name));
  phase='cancel-and-switch';
  const switching=await window.webContents.executeJavaScript(`(async()=>{
    const wait=ms=>new Promise(r=>setTimeout(r,ms)),scale=document.querySelector('input[data-setting=scale]'),bubble=document.querySelector('input[data-setting=bubbleScale]');
    scale.dispatchEvent(new PointerEvent('pointerdown',{pointerId:2,bubbles:true}));
    scale.value='1.3';scale.dispatchEvent(new Event('input',{bubbles:true}));
    scale.dispatchEvent(new PointerEvent('pointerup',{pointerId:2,bubbles:true}));
    bubble.dispatchEvent(new PointerEvent('pointerdown',{pointerId:3,bubbles:true}));
    bubble.value='1.4';bubble.dispatchEvent(new Event('input',{bubbles:true}));
    await wait(40);
    const keptPreview=document.body.style.opacity==='0.85'&&bubble.isConnected;
    bubble.dispatchEvent(new PointerEvent('pointercancel',{pointerId:3,bubbles:true}));
    await wait(150);
    return {keptPreview,opacity:document.body.style.opacity,scale:document.querySelector('input[data-setting=scale]').value,bubble:document.querySelector('input[data-setting=bubbleScale]').value};
  })()`);
  phase='gallery-keyboard';
  const gallery=await window.webContents.executeJavaScript(`(async()=>{
    const {buildGallery}=await import(new URL('./gallery.mjs',location.href).href),commands=[],container=document.createElement('div');document.body.append(container);
    const el=(tag,text,parent=container)=>{const node=document.createElement(tag);if(text!==undefined)node.textContent=text;parent.append(node);return node;};
    const command=(name,value)=>commands.push({name,value}),button=(text,name,value,parent)=>{const node=el('button',text,parent);node.onclick=()=>command(name,value);return node;};
    buildGallery({el,button,command},{selected:'custom',removed:[],characters:[{id:'custom',kind:'custom',name:'我的角色',url:'data:image/png;base64,'}]});
    const card=container.querySelector('.card'),remove=container.querySelector('.remove');
    remove.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));
    const nested=commands.slice();remove.click();card.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));
    return {nested,commands};
  })()`);
  phase='menu-keyboard';
  const navigation=await window.webContents.executeJavaScript(`(async()=>{
    const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));await window.gpt.command('fixture-clear-section');
    const key=(target,name)=>target.dispatchEvent(new KeyboardEvent('keydown',{key:name,bubbles:true,cancelable:true}));
    let summary=document.querySelector('summary');summary.focus();key(summary,'ArrowRight');
    const entered=document.activeElement.dataset.action==='characters';key(document.activeElement,'ArrowLeft');
    const left=!summary.closest('details').open&&document.activeElement===summary;
    key(summary,'ArrowRight');const checkbox=summary.closest('details').querySelector('input[type=checkbox]');checkbox.focus();checkbox.checked=true;checkbox.dispatchEvent(new Event('change',{bubbles:true}));await wait(100);
    const keptCheckbox=document.activeElement.dataset.focusKey==='setting:hideMenu'&&document.activeElement.checked;
    key(document.activeElement,'Escape');summary=document.activeElement;
    const escaped=!summary.closest('details').open;key(summary,'ArrowDown');
    return {entered,left,keptCheckbox,escaped,nextGroup:document.activeElement.textContent==='声音与点击'};
  })()`);
  state.kind='audio';state.audio={mode:'custom',press:{name:'fixture.wav'},release:null,errors:{release:'unavailable'}};phase='audio-busy';
  await window.loadFile(path.join(uiRoot,'ui/panel.html'));
  const busy=await window.webContents.executeJavaScript(`(async()=>{
    const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));for(let n=0;n<100&&!document.querySelector('[data-action=audio-import]');n++)await wait(10);
    await window.gpt.command('fixture-busy',true);await wait(20);
    const blocked=document.querySelector('[data-action=audio-import]').disabled&&!document.querySelector('[data-action=close-panel]').disabled;
    await window.gpt.command('fixture-busy',false);await wait(20);
    const previews=Array.from(document.querySelectorAll('[data-action=audio-preview]')).map(node=>node.disabled);
    return {blocked,restored:!document.querySelector('[data-action=audio-import]').disabled,previews};
  })()`);
  console.log(JSON.stringify({keyboard,escape,escapeCommands,switching,gallery,navigation,busy}));
}catch(error){console.error(error.stack);process.exitCode=1;}
finally{clearTimeout(timer);window?.destroy();app.quit();}
}
void main();
