import {app,BrowserWindow,ipcMain} from 'electron';
import path from 'node:path';import fs from 'node:fs';import {fileURLToPath} from 'node:url';
import {defaults} from '../../src/core/settings.mjs';
const source=fileURLToPath(new URL('../../',import.meta.url)),root=process.argv[2]??source,pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
let window,phase='ready',failSettings=false;const commands=[],state={kind:'menu',settings:{...defaults,soundOn:false},scene:{collapsed:true,mode:'quota'},music:false,version:'fixture',update:{automatic:true,status:'idle'}};
const fatal=error=>{console.error(error?.stack??error);app.exit(1);};process.on('uncaughtException',fatal);process.on('unhandledRejection',fatal);
const timer=setTimeout(()=>fatal(Error('functional panel timeout: '+phase)),18000);
ipcMain.handle('fixture-ready',()=>state);
ipcMain.handle('fixture-command',async(_event,name,value)=>{
 commands.push({name,value});
 if(name==='fixture-fail-settings'){failSettings=true;return {ok:true};}
 if(name==='settings'&&failSettings){failSettings=false;return {ok:false,error:'无法保存测试'};}
 if(name==='settings')Object.assign(state.settings,value);
 if(name==='update-automatic')state.update.automatic=value;
 if(name==='update-check'){state.update.status='checking';state.update.message='正在检查';}
 if(name==='quotes-save'||name==='colors-save'){
  const snapshot={...state,lines:String(value).trim(),error:null};await pause(80);state.lines=snapshot.lines;state.error=null;return {ok:true,state:snapshot};
 }
 if(name==='quotes-reset'){state.lines='内置语录';state.error=null;return {ok:true,state:{...state}};}
 if(name==='character-remove'){
  const row=state.characters.find(row=>row.id===value);state.characters=state.characters.filter(row=>row.id!==value);state.removed=[{...row,removedAt:new Date().toISOString()}];return {ok:true,state:{...state}};
 }
 return {ok:true};
});
async function load(kind){phase='load-'+kind;state.kind=kind;await window.loadFile(path.join(root,'ui/panel.html'));for(let n=0;n<100;n++){if(await window.webContents.executeJavaScript('document.querySelector("#panel").children.length>0'))return;await pause(10);}throw Error('panel did not load: '+kind);}
async function main(){try{
 await app.whenReady();window=new BrowserWindow({show:false,width:1100,height:800,webPreferences:{contextIsolation:true,backgroundThrottling:false,preload:path.join(source,'tests/fixtures/panel-interaction-preload.cjs')}});
 await load('menu');
 phase='menu-inputs';
 const menu=await window.webContents.executeJavaScript(`(async()=>{
  const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms)),group=text=>Array.from(document.querySelectorAll('details')).find(node=>node.dataset.key===text),label=text=>Array.from(document.querySelectorAll('label')).find(node=>node.textContent.trim()===text);
  const firstSlider=document.querySelector('[data-setting=soundVolume]'),soundDisabled=firstSlider.disabled;
  const size=document.querySelector('[data-setting=scale]');size.value='1.4';size.dispatchEvent(new Event('input'));size.dispatchEvent(new Event('change'));size.dispatchEvent(new Event('blur'));await wait(80);
  const updatedSize=document.querySelector('[data-setting=scale]'),sliderAccessible=updatedSize.getAttribute('aria-label')==='人物大小'&&updatedSize.getAttribute('aria-valuenow')==='1.4'&&updatedSize.getAttribute('aria-valuetext')==='140%';
  await window.gpt.command('fixture-fail-settings');document.querySelector('[data-focus-key="setting:hideMenu"]').click();await wait(40);
  const failedSettingReverted=!document.querySelector('[data-focus-key="setting:hideMenu"]').checked&&document.getElementById('feedback').textContent.includes('无法保存');
  group('版本与更新').open=true;
  const automatic=label('自动更新').querySelector('input');automatic.focus();automatic.click();await wait(40);
  const automaticFocus=document.activeElement===label('自动更新').querySelector('input')&&!document.activeElement.checked;
  const stableMenuNodes=firstSlider===document.querySelector('[data-setting=soundVolume]');
  const versions=group('版本与更新');versions.querySelector('summary').focus();versions.querySelector('summary').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true,cancelable:true}));
  group('形象与大小').dispatchEvent(new MouseEvent('mouseenter',{clientX:0,clientY:0}));const keyboardKeepsGroup=versions.open;
  const position=group('显示与位置');position.querySelector('summary').dispatchEvent(new Event('mouseenter'));position.open=true;
  const radio=position.querySelector('input[type=radio]');radio.focus();const left=new KeyboardEvent('keydown',{key:'ArrowLeft',bubbles:true,cancelable:true});radio.dispatchEvent(left);
  const radioArrows=position.open&&!left.defaultPrevented;
  const exit=document.querySelector('[data-action=exit]');exit.focus();exit.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowUp',bubbles:true,cancelable:true}));
  const rootNavigation=document.activeElement.textContent==='版本与更新';
  document.querySelector('[data-action=update-check]').click();await wait(40);
  const updateBusy=document.querySelector('[data-action=update-check]').disabled;
  return {soundDisabled,sliderAccessible,failedSettingReverted,automaticFocus,stableMenuNodes,keyboardKeepsGroup,radioArrows,rootNavigation,updateBusy};
 })()`);
 menu.updateStaysOpen=!commands.some(row=>row.name==='close-panel');
 const image='data:image/png;base64,'+fs.readFileSync(path.join(source,'assets/gpt-dragon-niang-bust.png')).toString('base64');
 Object.assign(state,{selected:'custom',notice:'上次使用的图片无法读取，已恢复龙娘1。',characters:[{id:'custom',name:'角色1',kind:'custom',url:image},{id:'other',name:'角色2',kind:'built-in',url:image}],removed:[]});await load('characters');
 const notice=await window.webContents.executeJavaScript('document.body.innerText.includes("上次使用的图片无法读取")');
 phase='gallery-inputs';
 window.webContents.send('fixture-busy',true);await pause(20);
 const busyCard=await window.webContents.executeJavaScript('document.querySelector(".card").getAttribute("aria-disabled")==="true"&&document.querySelector(".card").tabIndex===-1');
 window.webContents.send('fixture-busy',false);await pause(20);
 const galleryFocus=await window.webContents.executeJavaScript(`(async()=>{const remove=document.querySelector('.remove');remove.focus();remove.click();await new Promise(resolve=>setTimeout(resolve,40));return document.activeElement.dataset.action==='character-restore'||document.activeElement.classList.contains('card');})()`);
 Object.assign(state,{lines:'原语录',error:'旧配置读取失败'});await load('quotes');
 phase='editor-inputs';
 const editor=await window.webContents.executeJavaScript(`(async()=>{
  const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));let lines=document.querySelector('textarea');lines.focus();lines.value='首次保存';lines.dispatchEvent(new Event('input',{bubbles:true}));
  const save=Array.from(document.querySelectorAll('button')).find(node=>node.textContent==='保存');save.click();save.click();await wait(10);
  lines.value='首次保存\u005cn保存期间新增';lines.dispatchEvent(new Event('input',{bubbles:true}));lines.setSelectionRange(3,3);await wait(140);
  const retainedDraft=document.querySelector('textarea').value==='首次保存\u005cn保存期间新增',retainedFocus=document.activeElement===document.querySelector('textarea')&&document.activeElement.selectionStart===3;
  const dirtyNotice=document.getElementById('feedback').textContent.includes('未保存');
  Array.from(document.querySelectorAll('button')).find(node=>node.textContent==='恢复内置').click();await wait(40);
  const resetClearsError=!document.getElementById('feedback').textContent.includes('失败')&&document.querySelector('textarea').value==='内置语录';
  return {retainedDraft,retainedFocus,dirtyNotice,resetClearsError};
 })()`);
 editor.singleSave=commands.filter(row=>row.name==='quotes-save').length===1;
 console.log(JSON.stringify({menu,gallery:{notice,busyCard,galleryFocus},editor}));
}catch(error){console.error(error.stack);process.exitCode=1;}finally{clearTimeout(timer);window?.destroy();app.quit();}}
void main();
