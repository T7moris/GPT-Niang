import fs from 'node:fs';import path from 'node:path';import {execFileSync} from 'node:child_process';import {fileURLToPath} from 'node:url';
export function compileNative(root,output=path.join(root,'native'),{inputDll=null}={}){
 if(process.platform!=='win32')throw Error('Native helpers must be built on Windows');
 fs.mkdirSync(output,{recursive:true});
 const framework=path.join(process.env.WINDIR,'Microsoft.NET','Framework64','v4.0.30319'),compiler=path.join(framework,'csc.exe'),wpf=path.join(framework,'WPF');
 const compile=(name,args,files)=>execFileSync(compiler,['/nologo','/optimize+','/out:'+path.join(output,name),...args,...files.map(file=>path.join(root,'native',file))],{windowsHide:true,stdio:'pipe'});
 compile('GPTNiang.Native.exe',['/target:exe','/reference:System.Web.Extensions.dll','/reference:System.Xaml.dll',...['UIAutomationClient.dll','UIAutomationTypes.dll','WindowsBase.dll','PresentationCore.dll'].map(file=>'/reference:'+path.join(wpf,file))],['Bridge.cs','music-audio.cs']);
 compile('GPTNiang.Setup.exe',['/target:exe','/r:Microsoft.CSharp.dll','/r:System.Web.Extensions.dll'],['Setup.cs']);
 compile('GPTNiang.Start.exe',['/target:winexe','/reference:System.Web.Extensions.dll'],['Start.cs']);
 if(inputDll)fs.copyFileSync(inputDll,path.join(output,'GPTNiang.Input.dll'));
 else{
  const vswhere=path.join(process.env['ProgramFiles(x86)']??'C:\\Program Files (x86)','Microsoft Visual Studio','Installer','vswhere.exe');
  if(!fs.existsSync(vswhere))throw Error('MSVC Build Tools are required to compile the native input helper');
  const visualStudio=execFileSync(vswhere,['-latest','-products','*','-requires','Microsoft.VisualStudio.Component.VC.Tools.x86.x64','-property','installationPath'],{encoding:'utf8',windowsHide:true}).trim();
  const environment=path.join(visualStudio,'VC','Auxiliary','Build','vcvars64.bat');if(!fs.existsSync(environment))throw Error('MSVC x64 compiler is not available');
  if(/["\r\n]/.test(environment))throw Error('Invalid compiler path');
  if(path.resolve(root,'native')!==path.resolve(output))fs.copyFileSync(path.join(root,'native','mouse-activation.cpp'),path.join(output,'mouse-activation.cpp'));
  execFileSync(path.join(process.env.WINDIR,'System32','cmd.exe'),['/d','/s','/c',`call "${environment}" >nul && cl.exe /nologo /LD /O2 /MT /EHsc mouse-activation.cpp /link /OUT:GPTNiang.Input.dll comctl32.lib user32.lib`],{cwd:output,windowsHide:true,windowsVerbatimArguments:true,stdio:'pipe'});
  for(const suffix of ['obj','lib','exp','pdb'])for(const base of ['mouse-activation','GPTNiang.Input']){const file=path.join(output,base+'.'+suffix);if(fs.existsSync(file))fs.unlinkSync(file);}
 }
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){compileNative(path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..'));console.log('Native helpers compiled.');}
