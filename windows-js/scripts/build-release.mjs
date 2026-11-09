import fs from 'node:fs';import path from 'node:path';import {fileURLToPath} from 'node:url';import {execFileSync} from 'node:child_process';import {createHash} from 'node:crypto';import {deflateRawSync} from 'node:zlib';
import {runtimeFiles} from './runtime-files.mjs';import {compileNative} from './compile-native.mjs';import {crc32,inspectJavaScriptPackage} from '../src/core/archive.mjs';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..'),args=process.argv.slice(2),option=name=>{const n=args.indexOf(name);return n<0?null:args[n+1];};
const output=path.resolve(option('--output')??path.join(root,'..','dist','javascript-beta')),dependencies=path.resolve(option('--runtime-root')??root),program=path.join(output,'gpt-niang-usage'),pkg=JSON.parse(fs.readFileSync(path.join(root,'package.json')));
const sourcePkg=JSON.parse(fs.readFileSync(path.join(dependencies,'package.json')));
if(JSON.stringify(pkg.dependencies)!==JSON.stringify(sourcePkg.dependencies)||pkg.devDependencies.electron!==sourcePkg.devDependencies.electron)throw Error('Runtime dependency versions differ from source');
if(!/^\d+\.\d+\.\d+-beta\.\d+$/.test(pkg.version))throw Error('This builder is restricted to explicitly versioned Beta releases');
if(fs.existsSync(output))throw Error('Output already exists; choose a new output directory');
if(output===path.dirname(output)||output===root||root.startsWith(output+path.sep)||output.startsWith(root+path.sep))throw Error('Unsafe build output location');
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
const walk=directory=>fs.readdirSync(directory,{withFileTypes:true}).sort((a,b)=>a.name.localeCompare(b.name)).flatMap(entry=>{
 if(entry.isSymbolicLink())throw Error('Build source contains a directory link');
 const file=path.join(directory,entry.name);return entry.isDirectory()?walk(file):entry.isFile()?[file]:[];
});
fs.mkdirSync(program,{recursive:true});
const files=new Set();
const copy=(from,name)=>{const to=path.join(program,...name.split('/'));fs.mkdirSync(path.dirname(to),{recursive:true});fs.copyFileSync(from,to);files.add(name);};
for(const folder of ['src','ui','native','assets','runtime','.codex-plugin'])for(const file of walk(path.join(root,folder))){if(folder==='native'&&!/\.(cs|cpp|h|txt)$/i.test(file))continue;copy(file,path.relative(root,file).split(path.sep).join('/'));}
for(const name of ['package.json','package-lock.json','LICENSE','.mcp.json','README.md'])copy(path.join(root,name),name);
for(const name of runtimeFiles(dependencies,{platform:'win32',arch:'x64'}))copy(path.join(dependencies,...name.split('/')),name);
compileNative(root,path.join(program,'native'),{inputDll:option('--native-input')});
for(const name of ['GPTNiang.Native.exe','GPTNiang.Setup.exe','GPTNiang.Start.exe','GPTNiang.Input.dll'])files.add('native/'+name);
const commands={
 '重启GPT娘.cmd':'@echo off\r\nchcp 65001 >nul\r\nsetlocal DisableDelayedExpansion\r\nset ELECTRON_RUN_AS_NODE=1\r\n"%~dp0node_modules\\electron\\dist\\electron.exe" "%~dp0src\\setup-entry.mjs" --restart\r\nif errorlevel 1 pause\r\n',
 '安装GPT娘.cmd':'@echo off\r\nchcp 65001 >nul\r\nsetlocal DisableDelayedExpansion\r\nset ELECTRON_RUN_AS_NODE=1\r\n"%~dp0node_modules\\electron\\dist\\electron.exe" "%~dp0src\\setup-entry.mjs" %*\r\nset "result=%errorlevel%"\r\npause\r\nexit /b %result%\r\n',
 '打开GPT娘.cmd':'@echo off\r\nsetlocal DisableDelayedExpansion\r\nset ELECTRON_RUN_AS_NODE=1\r\n"%~dp0node_modules\\electron\\dist\\electron.exe" "%~dp0src\\setup-entry.mjs" --open\r\nif errorlevel 1 pause\r\n',
 '停用GPT娘.cmd':'@echo off\r\nchcp 65001 >nul\r\nsetlocal DisableDelayedExpansion\r\nset ELECTRON_RUN_AS_NODE=1\r\n"%~dp0node_modules\\electron\\dist\\electron.exe" "%~dp0src\\setup-entry.mjs" --disable\r\npause\r\n',
};
for(const [name,text]of Object.entries(commands)){fs.writeFileSync(path.join(program,name),text);files.add(name);}
let commit=option('--source-commit')??execFileSync('git',['rev-parse','HEAD'],{cwd:root,encoding:'utf8',windowsHide:true}).trim();
if(!/^[a-f0-9]{40}$/.test(commit))throw Error('Invalid source commit');
fs.writeFileSync(path.join(program,'BUILD-INFO.json'),JSON.stringify({version:pkg.version,architecture:'javascript-electron',channel:'beta',sourceCommit:commit,platform:'win32',arch:'x64'},null,2)+'\n');files.add('BUILD-INFO.json');
const manifest={version:1,architecture:'javascript-electron',files:Object.fromEntries([...files].sort().map(name=>[name,hash(fs.readFileSync(path.join(program,name)))]))};
fs.writeFileSync(path.join(program,'integrity.json'),JSON.stringify(manifest,null,2)+'\n');files.add('integrity.json');
const archive=path.join(output,`gpt-niang-usage-widget-v${pkg.version}-windows-js.zip`),fd=fs.openSync(archive,'wx'),central=[];let offset=0;
try{
 for(const name of [...files].sort()){
  const bytes=fs.readFileSync(path.join(program,name)),packed=deflateRawSync(bytes,{level:6}),raw=Buffer.from(name),crc=crc32(bytes),local=Buffer.alloc(30),directory=Buffer.alloc(46);
  local.writeUInt32LE(0x04034b50);local.writeUInt16LE(20,4);local.writeUInt16LE(0x800,6);local.writeUInt16LE(8,8);local.writeUInt16LE(0x21,12);local.writeUInt32LE(crc,14);local.writeUInt32LE(packed.length,18);local.writeUInt32LE(bytes.length,22);local.writeUInt16LE(raw.length,26);
  directory.writeUInt32LE(0x02014b50);directory.writeUInt16LE(20,4);directory.writeUInt16LE(20,6);directory.writeUInt16LE(0x800,8);directory.writeUInt16LE(8,10);directory.writeUInt16LE(0x21,14);directory.writeUInt32LE(crc,16);directory.writeUInt32LE(packed.length,20);directory.writeUInt32LE(bytes.length,24);directory.writeUInt16LE(raw.length,28);directory.writeUInt32LE(offset,42);
  fs.writeSync(fd,local);fs.writeSync(fd,raw);fs.writeSync(fd,packed);central.push(directory,raw);offset+=local.length+raw.length+packed.length;
 }
 const table=Buffer.concat(central),end=Buffer.alloc(22);end.writeUInt32LE(0x06054b50);end.writeUInt16LE(files.size,8);end.writeUInt16LE(files.size,10);end.writeUInt32LE(table.length,12);end.writeUInt32LE(offset,16);fs.writeSync(fd,table);fs.writeSync(fd,end);
}finally{fs.closeSync(fd);}
const archiveBytes=fs.readFileSync(archive),verified=inspectJavaScriptPackage(archiveBytes,pkg.version);
for(const file of verified)if(/(?:^|\/)(?:installation\.json|settings\.json|auth\.json|runtime\.json|presence\.json|candidate-state|bench-state|electron-profile)(?:\/|$)/i.test(file.name)||/\.bak$/.test(file.name))throw Error('Private state was included in the release');
const sum=hash(archiveBytes);fs.writeFileSync(path.join(output,'SHA256SUMS.txt'),sum+'  '+path.basename(archive)+'\n');
const result={ok:true,version:pkg.version,channel:'beta',sourceCommit:commit,files:files.size,bytes:archiveBytes.length,sha256:sum,archive,program,privateStateIncluded:false};fs.writeFileSync(path.join(output,'package-verification.json'),JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify(result));
