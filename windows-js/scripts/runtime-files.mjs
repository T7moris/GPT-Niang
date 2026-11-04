import fs from 'node:fs';
import path from 'node:path';
import {inside, readJson} from '../src/core/storage.mjs';

// Follow the installed production dependency graph instead of shipping npm's
// development/download toolchain. Keep the runtime packages intact.
export function runtimeFiles(root, {platform=process.platform, arch=process.arch}={}) {
  root=path.resolve(root);
  const result=new Set(), visited=new Set();
  const relative=file=>path.relative(root,file).split(path.sep).join('/');
  function collect(directory) {
    for(const entry of fs.readdirSync(directory,{withFileTypes:true})) {
      if(['node_modules','.bin','.cache'].includes(entry.name)) continue;
      const file=inside(root,relative(path.join(directory,entry.name)));
      if(entry.isDirectory()) collect(file);
      else if(entry.isFile()) result.add(relative(file));
    }
  }
  function resolvePackage(name, from) {
    if(!/^(?:@[a-z0-9._-]+\/)?[a-z0-9._-]+$/i.test(name)) throw Error('Invalid dependency name');
    for(let directory=from;;directory=path.dirname(directory)) {
      const candidate=inside(root,relative(path.join(directory,'node_modules',...name.split('/'))));
      if(fs.existsSync(path.join(candidate,'package.json'))) return candidate;
      if(directory===root) return null;
    }
  }
  const matches=(rule,value)=>!Array.isArray(rule)||(!rule.includes('!'+value)&&
    (!rule.some(x=>!x.startsWith('!'))||rule.includes(value)));
  function visit(name, from, optional=false) {
    const directory=resolvePackage(name,from);
    if(!directory) {if(optional)return;throw Error('Missing runtime dependency: '+name);}
    const pkg=readJson(path.join(directory,'package.json'));
    if(!pkg) throw Error('Invalid runtime dependency: '+name);
    if(!matches(pkg.os,platform)||!matches(pkg.cpu,arch)) {
      if(optional)return;
      throw Error('Runtime dependency has wrong platform: '+name);
    }
    if(visited.has(directory))return;
    visited.add(directory);collect(directory);
    const optionalNames=new Set(Object.keys(pkg.optionalDependencies??{}));
    for(const dependency of Object.keys(pkg.dependencies??{}))
      if(!optionalNames.has(dependency))visit(dependency,directory);
    for(const dependency of optionalNames)visit(dependency,directory,true);
  }
  const pkg=readJson(path.join(root,'package.json'));
  for(const name of Object.keys(pkg.dependencies??{}))visit(name,root);
  const electron=inside(root,'node_modules/electron');
  collect(inside(root,'node_modules/electron/dist'));
  for(const name of ['package.json','index.js','path.txt','LICENSE']) {
    const file=inside(electron,name);
    if(!fs.statSync(file).isFile())throw Error('Incomplete Electron runtime');
    result.add(relative(file));
  }
  const executable=platform==='win32'?'electron.exe':'electron';
  if(!result.has('node_modules/electron/dist/'+executable))throw Error('Missing Electron executable');
  return [...result].sort();
}
