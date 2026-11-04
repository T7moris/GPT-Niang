const {app,BrowserWindow}=require('electron');const fs=require('node:fs'),path=require('node:path');
const root=process.env.GPT_NIANG_AUDIT_APP,out=process.env.GPT_NIANG_AUDIT_OUTPUT;app.setPath('userData',process.env.GPT_NIANG_AUDIT_PROFILE);
app.whenReady().then(async()=>{
  let win;try{
    win=new BrowserWindow({show:false,width:64,height:64,webPreferences:{preload:path.join(__dirname,'lamp-csp-preload.cjs'),contextIsolation:true,nodeIntegration:false,sandbox:true,backgroundThrottling:false}});
    await win.loadFile(path.join(root,'ui','lamp.html'));
    const image='data:image/png;base64,'+fs.readFileSync(path.join(root,'assets','gpt-dragon-niang-bust.png')).toString('base64');
    const expression=`(async()=>{const violations=[];document.addEventListener('securitypolicyviolation',e=>violations.push(e.effectiveDirective));const img=new Image();img.src=${JSON.stringify(image)};await img.decode();const {drawHalo}=await import('./halo.mjs');const canvas=document.getElementById('lamp');drawHalo(canvas,{frame:{width:64,height:64},part:{width:48,height:48,matrix:[1,0,0,1,8,8]},dpi:1,display:1,palette:['#ff0000','#0000ff'],windowOffset:{x:0,y:0},phase:0,paused:true},img);await new Promise(r=>setTimeout(r,100));const bytes=canvas.getContext('2d').getImageData(0,0,canvas.width,canvas.height).data;let opaque=0;for(let n=3;n<bytes.length;n+=4)if(bytes[n])opaque++;return {width:img.naturalWidth,opaque,violations};})()`;
    fs.writeFileSync(out,JSON.stringify(await win.webContents.executeJavaScript(expression)));
  }catch(error){fs.writeFileSync(out,JSON.stringify({error:error.stack}));}finally{win?.destroy();app.quit();}
}).catch(error=>{fs.writeFileSync(out,JSON.stringify({error:error.stack}));app.quit();});
