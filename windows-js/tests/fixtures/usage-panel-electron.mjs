import {app,BrowserWindow,ipcMain} from 'electron';
import assert from 'node:assert/strict';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const root=fileURLToPath(new URL('../../',import.meta.url));
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const tokens=input=>({input,output:0,cached:0});
const threads=[{id:'a',title:'First',model:'fixture',provider:'openai'},{id:'b',title:'Second',model:'fixture',provider:'relay'}];
const snapshot={home:'fixture',sourceFiles:2,provider:'*',providers:['openai','relay'],selectedId:'a',threads,
  selected:{total:tokens(100),turnUsage:tokens(10)},today:tokens(100),all:tokens(100)};
const state={kind:'usage',usage:{snapshot,preferences:{codexHome:null,rules:[]}}};
let window;
const commands=[],checks={};
const fatal=error=>{console.error(error?.stack??error);app.exit(1);};
process.on('uncaughtException',fatal);process.on('unhandledRejection',fatal);
const timer=setTimeout(()=>fatal(Error('usage panel test timed out')),18000);
ipcMain.handle('fixture-ready',()=>state);
ipcMain.handle('fixture-command',(_event,name,value)=>{
  commands.push({name,value});
  if(name==='usage-select'){
    snapshot.provider=value.provider;snapshot.selectedId=value.id;
    snapshot.threads=threads.filter(row=>value.provider==='*'||row.provider===value.provider);
    return {ok:true,state};
  }
  return {ok:true};
});
const evaluate=code=>window.webContents.executeJavaScript(code);
async function refresh(input){
  snapshot.all=tokens(input);window.webContents.send('fixture-state',state);
  for(let n=0;n<100;n++){
    if(await evaluate(`document.querySelector('.usage-cards section:last-child strong').textContent===${JSON.stringify(input+' tokens')}`))return;
    await pause(10);
  }
  throw Error('usage totals stopped refreshing');
}
async function main(){try{
  await app.whenReady();
  window=new BrowserWindow({show:false,width:1100,height:800,webPreferences:{contextIsolation:true,backgroundThrottling:false,preload:path.join(root,'tests/fixtures/panel-interaction-preload.cjs')}});
  await window.loadFile(path.join(root,'ui/panel.html'));
  for(let n=0;n<100&&!await evaluate('!!document.querySelector(".usage-filters")');n++)await pause(10);
  await evaluate(`window.fixture={filters:document.querySelector('.usage-filters'),provider:document.querySelector('[data-focus-key="usage:provider"]'),thread:document.querySelector('[data-focus-key="usage:thread"]')};fixture.provider.focus();fixture.option=fixture.provider.options[0];`);
  snapshot.providers.push('new-provider');
  for(const input of [101,102,103])await refresh(input);
  Object.assign(checks,await evaluate(`({providerAttached:fixture.provider===document.querySelector('[data-focus-key="usage:provider"]')&&fixture.filters===document.querySelector('.usage-filters'),providerFocused:document.activeElement===fixture.provider,activeOptionsUntouched:fixture.option===fixture.provider.options[0]&&fixture.provider.options.length===3,inactiveSelectionPreserved:fixture.thread.value==='a',liveTotals:document.querySelector('.usage-cards section:last-child strong').textContent==='103 tokens'})`));
  await evaluate(`fixture.provider.value='relay';fixture.provider.dispatchEvent(new Event('change',{bubbles:true}));`);
  for(let n=0;n<100&&commands.length<1;n++)await pause(10);
  await pause(40);
  checks.providerCommand=commands[0]?.name==='usage-select'&&commands[0].value.provider==='relay'&&commands[0].value.id==='';
  Object.assign(checks,await evaluate(`({inactiveThreadReset:fixture.thread.value===''&&Array.from(fixture.thread.options).map(o=>o.value).join(',')===',b',providerStillFocused:document.activeElement===fixture.provider})`));
  await evaluate(`fixture.thread.focus();fixture.option=fixture.thread.options[0];fixture.thread.value='b';fixture.thread.dispatchEvent(new Event('change',{bubbles:true}));`);
  for(let n=0;n<100&&commands.length<2;n++)await pause(10);
  await pause(40);
  checks.threadCommand=commands[1]?.name==='usage-select'&&commands[1].value.id==='b'&&commands[1].value.provider==='relay';
  snapshot.threads=[...snapshot.threads,{id:'c',title:'Third',model:'fixture',provider:'relay'}];
  await refresh(104);
  Object.assign(checks,await evaluate(`({threadAttached:fixture.thread===document.querySelector('[data-focus-key="usage:thread"]')&&document.activeElement===fixture.thread,threadOptionsUntouched:fixture.option===fixture.thread.options[0]&&fixture.thread.options.length===2,inactiveProviderRefreshed:fixture.provider.options.length===4&&fixture.provider.value==='relay'})`));
  // A hidden BrowserWindow does not reliably dispatch native focusout. Send the
  // DOM event after moving focus to exercise the same deferred flush handler.
  await evaluate(`const outside=document.querySelector('[data-action="close-panel"]');outside.focus();fixture.thread.dispatchEvent(new FocusEvent('focusout',{bubbles:true,relatedTarget:outside}));`);
  await pause(40);
  checks.optionsFlushedOnBlur=await evaluate(`Array.from(document.querySelector('[data-focus-key="usage:thread"]').options).map(o=>o.value).join(',')===',b,c'&&document.querySelector('[data-focus-key="usage:thread"]').value==='b'`);
  console.log(JSON.stringify(checks));
  for(const [name,passed] of Object.entries(checks))assert.equal(passed,true,name);
}catch(error){console.error(error.stack);process.exitCode=1;}finally{clearTimeout(timer);window?.destroy();app.quit();}}
void main();
