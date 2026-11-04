import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {updateFiles} from '../src/core/update-files.mjs';
import {acquireLock} from '../src/core/updater.mjs';
import {processIdentity} from '../runtime/process-identity.mjs';
import {zipFixture,packageFiles} from './fixtures/zip-fixture.mjs';
const app=fileURLToPath(new URL('../',import.meta.url));
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
function fixture(t){
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-preparation-failure-'));
  t.after(()=>{assert.equal(path.dirname(root),path.resolve(os.tmpdir()));fs.rmSync(root,{recursive:true,force:true});});
  return root;
}
test('failed package extraction retires only its own partial cache',async t=>{
  const dataDir=fixture(t),updates=path.join(dataDir,'updates'),other=path.join(updates,'keep-me');
  fs.mkdirSync(other,{recursive:true});fs.writeFileSync(path.join(other,'personal.txt'),'keep');
  const bytes=zipFixture(packageFiles()),name='gpt-niang-usage-widget-v1.3.6-windows-js.zip',original=fs.writeFileSync;
  let writes=0;
  fs.writeFileSync=function(file,...args){
    if(String(file).startsWith(updates+path.sep)&&!String(file).startsWith(other+path.sep)&&++writes===3)throw Object.assign(Error('injected disk full'),{code:'ENOSPC'});
    return original.call(this,file,...args);
  };
  try{await assert.rejects(updateFiles({kind:'stage',dataDir,bytes,sums:Buffer.from(hash(bytes)+'  '+name),asset:{name,digest:'sha256:'+hash(bytes)},version:'1.3.6'}),/injected disk full/);}
  finally{fs.writeFileSync=original;}
  assert.deepEqual(fs.readdirSync(updates),['keep-me']);
  assert.equal(fs.readFileSync(path.join(other,'personal.txt'),'utf8'),'keep');
});
test('failed helper preparation retires its partial helper and retains the verified package',async t=>{
  const dataDir=fixture(t),directory=path.join(dataDir,'updates','verified'),token='fixture-agent',bytes=zipFixture(packageFiles());
  fs.mkdirSync(directory,{recursive:true});
  for(const [name,content]of Object.entries(packageFiles())){const file=path.join(directory,name);fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,content);}
  fs.writeFileSync(path.join(directory,'verified-package.zip'),bytes);
  const original=fs.copyFileSync;let copies=0;
  fs.copyFileSync=function(...args){if(++copies===2)throw Error('injected helper copy');return original.apply(this,args);};
  try{await assert.rejects(updateFiles({kind:'prepare',root:app,dataDir,directory,version:'1.3.6',hash:hash(bytes),token,nodePath:process.execPath,parentPid:process.pid}),/injected helper copy/);}
  finally{fs.copyFileSync=original;}
  assert.equal(fs.existsSync(path.join(dataDir,'update-agent-js',token)),false);
  assert.deepEqual(fs.readFileSync(path.join(directory,'verified-package.zip')),bytes);
  assert.equal(fs.existsSync(path.join(dataDir,'javascript-update-journal.json')),false);
  const collision=path.join(dataDir,'update-agent-js',token);fs.mkdirSync(collision);fs.writeFileSync(path.join(collision,'keep.txt'),'existing helper');
  await assert.rejects(updateFiles({kind:'prepare',root:app,dataDir,directory,version:'1.3.6',hash:hash(bytes),token,nodePath:process.execPath,parentPid:process.pid}),{code:'EEXIST'});
  assert.equal(fs.readFileSync(path.join(collision,'keep.txt'),'utf8'),'existing helper');
});
test('update preparation ignores an external directory configured as Node',async t=>{
  const dataDir=fixture(t),directory=path.join(dataDir,'updates','verified'),files=packageFiles();
  files['node_modules/electron/dist/electron.exe']=Buffer.from('verified fixture runtime');
  files['integrity.json']=Buffer.from(JSON.stringify({version:1,files:Object.fromEntries(Object.entries(files).filter(([name])=>name!=='integrity.json').map(([name,bytes])=>[name,hash(bytes)]))}));
  const bytes=zipFixture(files);fs.mkdirSync(directory,{recursive:true});
  for(const [name,content]of Object.entries(files)){const file=path.join(directory,name);fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,content);}
  fs.writeFileSync(path.join(directory,'verified-package.zip'),bytes);
  const result=await updateFiles({kind:'prepare',root:app,dataDir,directory,version:'1.3.6',hash:hash(bytes),token:'directory-host',nodePath:dataDir,parentPid:process.pid});
  assert.equal(result.executable,path.join(directory,'node_modules/electron/dist/electron.exe'));
});
test('reused process id does not hold the update or supervisor lock forever',{skip:process.platform!=='win32'},t=>{
  const dataDir=fixture(t),directory=path.join(dataDir,'javascript-update.lock'),identity=processIdentity(process.pid);
  assert.ok(identity?.startedTicks);fs.mkdirSync(directory);
  fs.writeFileSync(path.join(directory,'owner.json'),JSON.stringify({pid:process.pid,startedTicks:(BigInt(identity.startedTicks)-1n).toString(),token:'old-process'}));
  const lock=acquireLock(dataDir);assert.ok(lock,'the recorded process has ended even though its PID is in use');
  try{
    assert.equal(JSON.parse(fs.readFileSync(path.join(directory,'owner.json'))).startedTicks,identity.startedTicks);
    assert.equal(acquireLock(dataDir),null,'the real owner must retain its lock');
    assert.deepEqual(fs.readdirSync(dataDir),['javascript-update.lock']);
  }finally{lock.release();}
});
