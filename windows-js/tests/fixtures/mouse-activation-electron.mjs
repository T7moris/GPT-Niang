import {app,BrowserWindow} from 'electron';
import koffi from 'koffi';
import {pathToFileURL} from 'node:url';import path from 'node:path';
const user=koffi.load('user32.dll'),send=user.func('intptr_t __stdcall SendMessageW(intptr_t h,uint32_t msg,uintptr_t w,intptr_t l)'),foreground=user.func('intptr_t __stdcall GetForegroundWindow()');
const query=(h,msg,w,l)=>new Promise((resolve,reject)=>send.async(h,msg,w,l,(error,value)=>error?reject(error):resolve(Number(value))));
let window,guard;
const debug=message=>{if(process.env.GPT_MOUSE_DEBUG)console.error(message);};
async function main(){try{
 debug('ready');
 await app.whenReady();
 const module=await import(process.argv[2]?pathToFileURL(path.join(process.argv[2],'src/windows/mouse-activation.mjs')).href:new URL('../../src/windows/mouse-activation.mjs',import.meta.url).href);
 guard=new module.MouseActivation();window=new BrowserWindow({show:false,frame:false,focusable:false,webPreferences:{offscreen:true}});
 debug('created');
 const handle=Number(window.getNativeWindowHandle().readBigUInt64LE()),before=await query(handle,0x21,0,(0x201<<16)|1),ordinaryBefore=await query(handle,0x84,0,0),active=Number(foreground());
 const attached=guard.attach(handle),same=guard.attach(handle),after=[];
 debug('attached');
 for(let n=0;n<250;n++)after.push(await query(handle,0x21,0,((n%2?0x204:0x201)<<16)|1));
 debug('queried');
 const noFocusChange=Number(foreground())===active,oneCallback=guard.callbacks.size===1,ordinary=await query(handle,0x84,0,0),hidden=!window.isVisible();
 const closed=guard.close(),restored=await query(handle,0x21,0,(0x201<<16)|1),empty=guard.callbacks.size===0;
 debug('closed');
 guard.attach(handle);window.once('closed',()=>guard.close());window.destroy();
 await new Promise(resolve=>setImmediate(resolve));
 const destroyedCleanup=guard.close()&&guard.callbacks.size===0&&guard.pending.size===0;
 debug('destroyed');
 console.log(JSON.stringify({before,attached,same,after:[...new Set(after)],noFocusChange,oneCallback,ordinary,ordinaryBefore,hidden,closed,restored,empty,destroyedCleanup}));
}catch(error){console.error(error.stack);process.exitCode=1;}
finally{guard?.close();if(window&&!window.isDestroyed())window.destroy();app.quit();}}
void main();
