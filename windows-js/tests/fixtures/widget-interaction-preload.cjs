const {contextBridge,ipcRenderer}=require('electron');
let state,geometry,audio,pointer;
let masks=0;
const events=[];
contextBridge.exposeInMainWorld('gpt',{
  ready:()=>ipcRenderer.invoke('fixture-ready'),
  onState:callback=>state=callback,onGeometry:callback=>geometry=callback,onAudio:callback=>audio=callback,
  onPointer:callback=>pointer=callback,
  hit:value=>events.push({type:'hit',value}),shape:value=>{if(value.resources)masks++;},performance:()=>{},music:()=>{},
  drag:value=>events.push({type:'drag',value}),command:(name,value)=>{events.push({type:'command',name,value});return Promise.resolve({ok:true});},
  pointer:()=>Promise.resolve({cursor:{x:245,y:245}}),
  fixture:{state:value=>state(value),audio:value=>audio(value),pointer:value=>pointer(value),masks:()=>masks,events:()=>events.slice(),clear:()=>events.splice(0),
    geometryBurst:count=>{for(let n=0;n<count;n++)geometry({position:{left:n,top:n}});}},
});
