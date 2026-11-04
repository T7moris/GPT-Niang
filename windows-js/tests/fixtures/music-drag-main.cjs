const {app,BrowserWindow,ipcMain}=require('electron'),fs=require('node:fs'),path=require('node:path'),{pathToFileURL}=require('node:url');
const fatal=error=>{console.error(error?.stack??error);app.exit(1);};
process.on('uncaughtException',fatal);process.on('unhandledRejection',fatal);
const root=path.resolve(process.argv[2]),data=path.resolve(process.argv[3]);
fs.mkdirSync(data,{recursive:true});fs.writeFileSync(path.join(data,'settings.json'),JSON.stringify({layoutVersion:2,scale:1,bubbleScale:1,followHost:true,soundOn:false,colorMode:'original',taskCompletionBubble:false}));
const config=path.join(data,'test-config.json');fs.writeFileSync(config,JSON.stringify({candidate:true,architecture:'javascript-electron',appDir:root,dataDir:data,nodePath:process.execPath}));
process.argv=[process.argv[0],process.argv[1],'--candidate','--bench','--data-dir',data,'--config',config];app.setPath('userData',path.join(data,'electron-profile'));
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms)),timer=setTimeout(()=>{console.error('music drag fixture timeout');app.exit(1);},12000);
(async()=>{try{
  // Keep real native geometry and page input, without exposing test windows.
  BrowserWindow.prototype.show=function(){};BrowserWindow.prototype.showInactive=function(){};
  const {NativeWindows}=await import(pathToFileURL(path.join(root,'src/windows/native.mjs'))),visible=NativeWindows.prototype.visible;
  NativeWindows.prototype.visible=function(h){return this.pid(h)===process.pid?this.valid(h):visible.call(this,h);};
  const {WindowsBridge}=await import(pathToFileURL(path.join(root,'src/windows/bridge.mjs')));WindowsBridge.prototype.capture=()=>{};
  await import(pathToFileURL(path.join(root,'src/main.mjs')));
  let widget,bench;
  for(let n=0;n<150;n++){
    widget=BrowserWindow.getAllWindows().find(w=>w.webContents.getURL().endsWith('/ui/index.html'));bench=BrowserWindow.getAllWindows().find(w=>w.webContents.getURL().endsWith('/ui/bench.html'));
    if(widget&&bench&&await widget.webContents.executeJavaScript('!!window.widgetVerification?.().ok'))break;await pause(30);
  }
  if(!widget||!bench)throw Error('fixture windows missing');
  const status=await bench.webContents.executeJavaScript('window.gpt.command("bench-status")');if(!status.data.visible)throw Error('native widget is hidden');
  const enabled=await widget.webContents.executeJavaScript('window.gpt.command("music",true)');if(!enabled.ok)throw Error(enabled.error);await pause(100);
  const before=widget.getBounds();
  const point=await widget.webContents.executeJavaScript(`(()=>{
    const girl=document.getElementById('girl'),r=girl.getBoundingClientRect(),canvas=document.createElement('canvas');canvas.width=canvas.height=64;const dc=canvas.getContext('2d');dc.drawImage(girl,0,0,64,64);const bytes=dc.getImageData(0,0,64,64).data;
    let best=null;for(let y=0;y<64;y++)for(let x=0;x<64;x++)if(bytes[(y*64+x)*4+3]>100&&(!best||(x-32)**2+(y-32)**2<best.distance))best={x,y,distance:(x-32)**2+(y-32)**2};
    const fit=Math.min(girl.clientWidth/girl.naturalWidth,girl.clientHeight/girl.naturalHeight),w=girl.naturalWidth*fit,h=girl.naturalHeight*fit;
    const x=r.left+((girl.clientWidth-w)/2+(best.x+.5)*w/64)*r.width/girl.clientWidth,y=r.top+((girl.clientHeight-h)/2+(best.y+.5)*h/64)*r.height/girl.clientHeight;
    Element.prototype.setPointerCapture=()=>{};Element.prototype.releasePointerCapture=()=>{};return {x,y};
  })()`);
  const emit=(type,delta=0)=>widget.webContents.executeJavaScript(`document.getElementById('girl').dispatchEvent(new PointerEvent(${JSON.stringify(type)},{bubbles:true,pointerId:1,button:0,clientX:${point.x},clientY:${point.y},screenX:${before.x+point.x+delta},screenY:${before.y+point.y}}))`);
  await emit('pointerdown');await pause(60);const held=widget.getBounds();await emit('pointermove',-80);await pause(100);const moved=widget.getBounds();await emit('pointercancel');
  console.log(JSON.stringify({ok:true,before,held,moved,dx:moved.x-held.x,noNativeAudio:true}));
  const sender=widget.webContents;
  widget.on('closed',()=>{for(const channel of ['hit','shape','drag','frame-timing','music-position'])ipcMain.emit(channel,{sender},{x:0,y:0,op:'arm'});});
  widget.destroy();
}catch(error){console.error(error.stack);process.exitCode=1;}finally{clearTimeout(timer);app.quit();}})();
