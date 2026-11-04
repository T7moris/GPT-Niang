import koffi from 'koffi';import {fileURLToPath} from 'node:url';
let api;
function inputApi(){
 if(!api){
  const library=koffi.load(fileURLToPath(new URL('../../native/GPTNiang.Input.dll',import.meta.url)));
  api={library,attach:library.func('int __stdcall AttachMouseActivation(intptr_t window)'),detach:library.func('int __stdcall DetachMouseActivation(intptr_t window)')};
 }
 return api;
}
// Keep the window procedure in native code: a closing window may invoke its
// procedure while Electron is unwinding JavaScript and emitting before-quit.
export class MouseActivation {
 constructor(){this.callbacks=new Set();this.pending=new Set();}
 attach(window){if(this.callbacks.has(window))return true;if(!inputApi().attach(window))return false;this.callbacks.add(window);return true;}
 detach(window){if(!this.callbacks.has(window))return true;if(!inputApi().detach(window))return false;this.callbacks.delete(window);return true;}
 close(){for(const window of this.callbacks)this.detach(window);return this.callbacks.size===0;}
}
