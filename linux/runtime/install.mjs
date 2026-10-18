import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {resolveCodexExecutable} from '../../gpt-niang-usage/runtime/usage.mjs';

const home=()=>process.env.HOME || os.homedir();
const configHome=()=>process.env.XDG_CONFIG_HOME || path.join(home(),'.config');
const dataHome=()=>process.env.XDG_DATA_HOME || path.join(home(),'.local/share');
export const autostartPath=()=>path.join(configHome(),'autostart/org.gptniang.KDE.desktop');
export const autostartEnabled=()=>fs.existsSync(autostartPath());
export function desktopQuote(value) {
  return '"'+String(value).replace(/[%\\"`$]/g,c=>c==='%'?'%%':'\\'+c)+'"';
}
const shellQuote=value=>"'"+String(value).replace(/'/g,"'\\''")+"'";
function entry(root) {
  return '[Desktop Entry]\nType=Application\nName=GPT娘\nComment=Codex 额度与桌面陪伴\nExec='+desktopQuote(path.join(root,'linux/gpt-niang'))+' start\nIcon='+path.join(root,'gpt-niang-usage/assets/gpt-dragon-niang-bust.png')+'\nTerminal=false\nCategories=Utility;\nStartupNotify=false\nX-KDE-autostart-after=panel\n';
}
function write(file,value,mode=0o644) {
  fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,value,{mode});
}
export function setAutostart(enabled,root) {
  if(enabled)write(autostartPath(),entry(root));
  else fs.rmSync(autostartPath(),{force:true});
}
export function install(root,{autostart=false}={}) {
  // Register this checkout/package in place. Updates keep the same directory;
  // no desktop-shell files or system-wide packages are replaced.
  const launcher=path.join(home(),'.local/bin/gpt-niang');
  const manifest=path.join(dataHome(),'gpt-niang-kde/installation.json');
  if(fs.existsSync(launcher)){
    let previous;try{previous=JSON.parse(fs.readFileSync(manifest,'utf8'));}catch{}
    if(!previous?.root)throw new Error('~/.local/bin/gpt-niang 已存在且不属于本安装，请先检查该文件');
  }
  const script='#!/bin/sh\n# Managed by GPT-Niang KDE.\nexec '+shellQuote(path.join(root,'linux/gpt-niang'))+' "$@"\n';
  write(launcher,script,0o755);fs.chmodSync(launcher,0o755);
  write(path.join(dataHome(),'applications/org.gptniang.KDE.desktop'),entry(root));
  const runtime={node:process.execPath,codexPath:resolveCodexExecutable(process.env.GPT_NIANG_CODEX_PATH)};
  write(manifest,JSON.stringify({root,...runtime},null,2)+'\n',0o600);
  // Store the runtime location without requiring an interactive shell PATH.
  write(path.join(root,'linux/.runtime-paths.json'),JSON.stringify(runtime)+'\n',0o600);
  if(autostart)setAutostart(true,root);
  return launcher;
}
export function uninstall(root) {
  const manifest=path.join(dataHome(),'gpt-niang-kde/installation.json');
  let previous;try{previous=JSON.parse(fs.readFileSync(manifest,'utf8'));}catch{}
  if(previous?.root!==root)throw new Error('安装记录不属于此目录，未删除其他安装');
  setAutostart(false,root);
  for(const file of [path.join(home(),'.local/bin/gpt-niang'),path.join(dataHome(),'applications/org.gptniang.KDE.desktop'),manifest])fs.rmSync(file,{force:true});
}
