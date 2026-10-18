import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {atomicJson} from '../../gpt-niang-usage/runtime/usage.mjs';

export function dataDirectory(env=process.env) {
  return path.resolve(env.GPT_NIANG_DATA_DIR || path.join(env.XDG_STATE_HOME || path.join(env.HOME || os.homedir(), '.local/state'), 'gpt-niang-usage'));
}

export const defaults = Object.freeze({
  version: 1, mode: 'desktop', scale: 1, alwaysOnTop: false,
  sound: true, volume: 0.35, clickCycles: false, bubbleSeconds: 5,
  desktop: {x: null, y: null}, follow: {edge: 'right', bottom: 16},
  customQuotes: null,
});

const clamp=(n,lo,hi,fallback)=>typeof n==='number' && Number.isFinite(n)?Math.max(lo,Math.min(hi,n)):fallback;
export function normalizeSettings(raw={}) {
  const position=raw.desktop || {}, follow=raw.follow || {};
  return {
    ...defaults, mode: raw.mode==='follow'?'follow':'desktop',
    scale: clamp(raw.scale,0.6,2.5,1), alwaysOnTop: raw.alwaysOnTop===true,
    sound: raw.sound!==false, volume: clamp(raw.volume,0,1,0.35),
    clickCycles: raw.clickCycles===true, bubbleSeconds: clamp(raw.bubbleSeconds,3,60,5),
    desktop: {x: Number.isFinite(position.x)?Math.round(position.x):null, y:Number.isFinite(position.y)?Math.round(position.y):null},
    follow: {edge:follow.edge==='left'?'left':'right', bottom:clamp(follow.bottom,0,10000,16)},
    customQuotes: Array.isArray(raw.customQuotes)?raw.customQuotes.filter(q=>typeof q==='string' && q.trim()).map(q=>q.trim().slice(0,300)).slice(0,200):null,
  };
}

export function loadSettings(dir) {
  try {return normalizeSettings(JSON.parse(fs.readFileSync(path.join(dir,'kde-settings.json'),'utf8')));}
  catch {return normalizeSettings();}
}

export function saveSettings(dir,settings) {
  fs.mkdirSync(dir,{recursive:true,mode:0o700});
  atomicJson(path.join(dir,'kde-settings.json'),normalizeSettings(settings));
}

export function displayWindows(snapshot,now=Date.now()) {
  return (snapshot?.windows || []).map(w=>({
    ...w,
    value: !Number.isFinite(w.remaining) || (w.resetsAt && w.resetsAt*1000<=now)?'—':String(Math.round(w.remaining))+'%',
    expired: !!(w.resetsAt && w.resetsAt*1000<=now),
    stale: !snapshot.queryOk || now-(snapshot.observedAt || 0)>180000,
    resetLabel: w.resetsAt?new Date(w.resetsAt*1000).toLocaleString('zh-CN',{month:'numeric',day:'numeric',hour:'2-digit',minute:'2-digit',hour12:false}):'未提供重置时间',
  }));
}
