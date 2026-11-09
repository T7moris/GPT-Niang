const states=new WeakMap();
// Offscreen rendering does not prevent Electron's minimize/restore APIs from
// revealing a real OS placeholder. Hidden candidates must never call them.
export function keepTestWindowHidden(window){
  let state=states.get(window);
  if(!state){state={minimized:false,maximized:false,fullscreen:false,blocked:0};states.set(window,state);}
  for(const name of ['show','showInactive','focus','flashFrame','moveTop'])window[name]=()=>{state.blocked++;};
  window.minimize=()=>{state.blocked++;state.minimized=true;state.maximized=false;};
  window.restore=()=>{state.blocked++;state.minimized=false;state.maximized=false;};
  window.maximize=()=>{state.blocked++;state.minimized=false;state.maximized=true;};
  window.unmaximize=()=>{state.blocked++;state.maximized=false;};
  window.isMinimized=()=>state.minimized;
  window.isMaximized=()=>state.maximized;
  window.setFullScreen=value=>{state.blocked++;state.fullscreen=Boolean(value);};
  window.isFullScreen=()=>state.fullscreen;
  window.setKiosk=()=>{state.blocked++;};
  return window;
}
export const hiddenSurfaceState=window=>states.has(window)?{...states.get(window)}:null;
