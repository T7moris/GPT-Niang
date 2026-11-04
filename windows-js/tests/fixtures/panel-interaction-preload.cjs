const {contextBridge,ipcRenderer}=require('electron');
contextBridge.exposeInMainWorld('gpt',{
  ready:()=>ipcRenderer.invoke('fixture-ready'),
  command:(name,value)=>ipcRenderer.invoke('fixture-command',name,value),
  onState:callback=>ipcRenderer.on('fixture-state',(_event,value)=>callback(value)),
  onBusy:callback=>ipcRenderer.on('fixture-busy',(_event,value)=>callback(value)),
});
