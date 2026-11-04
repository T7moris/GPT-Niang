const {app,BrowserWindow}=require('electron');
const fs=require('node:fs'),path=require('node:path');
const root=path.resolve(__dirname,'../..'),data=process.argv[2];
app.setAppPath(root);
process.argv=[process.execPath,__filename,'--candidate','--preview','--data-dir',data];
const fail=error=>{console.error(error.stack??error);app.exit(7);};
process.on('uncaughtException',fail);process.on('unhandledRejection',fail);
const timeout=setTimeout(()=>fail(Error('renderer crash was not handled')),12000);
app.on('before-quit',()=>clearTimeout(timeout));
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
void(async()=>{
 await import(require('node:url').pathToFileURL(path.join(root,'src/main.mjs')));
 for(let n=0;n<200;n++){
  const window=BrowserWindow.getAllWindows().find(w=>w.webContents.getURL().endsWith('/ui/index.html'));
  if(window&&await window.webContents.executeJavaScript('Boolean(window.widgetVerification?.().ok)')){
   const marker=path.join(data,'runtime.json');
   if(fs.existsSync(marker)&&JSON.parse(fs.readFileSync(marker)).rendererReady===true){
    fs.writeFileSync(path.join(data,'crash-requested.json'),JSON.stringify({pid:process.pid,loadedImage:true,rendererReady:true}));
    window.webContents.forcefullyCrashRenderer();return;
   }
  }
  await pause(30);
 }
 throw Error('renderer did not become ready');
})().catch(fail);
