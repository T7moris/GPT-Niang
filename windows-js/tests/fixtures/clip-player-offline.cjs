const {app,BrowserWindow}=require('electron'),path=require('node:path'),{pathToFileURL}=require('node:url');
const timer=setTimeout(()=>app.exit(1),15000);
app.whenReady().then(async()=>{
 let window,code=0;
 try{
  window=new BrowserWindow({show:false,webPreferences:{offscreen:true,sandbox:true}});
  await window.loadFile(path.join(__dirname,'offline-audio.html'));
  const url=pathToFileURL(path.resolve(__dirname,'../../ui/clip-player.mjs')).href;
  const result=await window.webContents.executeJavaScript(`(async()=>{
    const {ClipPlayer}=await import(${JSON.stringify(url)}),offline=new OfflineAudioContext(1,4800,48000),buffer=offline.createBuffer(1,2400,48000);buffer.getChannelData(0).fill(.8);
    const context={state:'running',get currentTime(){return offline.currentTime;},destination:offline.destination,createBufferSource:()=>offline.createBufferSource(),createGain:()=>offline.createGain()};
    const player=new ClipPlayer({context:()=>context,schedule:()=>0,cancel:()=>{}});player.play(buffer,1);player.stop();
    const rendered=await offline.startRendering(),samples=rendered.getChannelData(0);let maxStep=0;for(let n=1;n<600;n++)maxStep=Math.max(maxStep,Math.abs(samples[n]-samples[n-1]));
    player.close();return {start:samples[0],quarter:samples[96],threeQuarters:samples[288],afterTail:samples[480],maxStep,voices:player.tails.size};
  })()`);
  if(!(Math.abs(result.start-.8)<.01&&Math.abs(result.quarter-.6)<.02&&Math.abs(result.threeQuarters-.2)<.02&&result.afterTail===0&&result.maxStep<.01&&result.voices===0&&!window.isVisible()))throw Error(JSON.stringify(result));
  console.log(JSON.stringify({ok:true,actualOfflinePCM:true,visibleWindows:0,...result}));
 }catch(error){console.error(error.stack);code=1;}
 finally{clearTimeout(timer);window?.destroy();app.exit(code);}
});
