import fs from 'node:fs';
import path from 'node:path';
import {randomInt} from 'node:crypto';
import {pathToFileURL} from 'node:url';
import {defaultCodexHome,listRolloutFiles,readSessionHeader} from './completion-monitor.mjs';

const endings = new Set(['task_complete', 'turn_complete', 'turn_aborted', 'turn_cancelled', 'turn_failed']);
const boundaries = new Set(['task_started', 'turn_started', ...endings]);
const maxIdle = 60 * 60 * 1000;
const chunkSize = 256 * 1024;
const maxLine = 2 * 1024 * 1024;

function titleFrom(text) {
  if (typeof text !== 'string') return '';
  text = text.trim();
  const marker = /^#*\s*My request\s*:/im.exec(text);
  if (marker) text = text.slice(marker.index + marker[0].length).trim();
  if (!text || text.startsWith('<') || text.startsWith('# Files mentioned')) return '';
  const line = text.split(/\r?\n/).find(x => x.trim()) || '';
  return Array.from(line.replace(/[\u0000-\u001f]/g, ' ').trim()).slice(0, 60).join('');
}

export function applyRecord(state, record) {
  const p = record.payload || {};
  const at = Date.parse(record.timestamp) || Date.now();
  if (record.type === 'event_msg' && boundaries.has(p.type)) {
    if (endings.has(p.type)) {
      if (!state.active || !p.turn_id || !state.turn || p.turn_id === state.turn) {
        const duration = Number.isFinite(p.duration_ms) ? p.duration_ms :
          Math.max(0, at - (state.started || (p.started_at ? p.started_at*1000 : at)));
        const success = ['task_complete','turn_complete'].includes(p.type) && !p.error &&
          !['failed','cancelled','canceled','aborted','interrupted'].includes(p.status);
        state.ending = {id:p.turn_id || state.turn, at, duration, success, title:state.title || ''};
        state.active = false;
      }
    } else {
      Object.assign(state, {active:true, turn:p.turn_id, title:'', phase:'正在处理', started:at, phaseSince:at});
    }
    return;
  }
  if (!state.active) return;
  const previousPhase=state.phase;
  if (p.type === 'message' && p.role === 'user') {
    const text = (p.content || []).filter(x => x.type === 'input_text').map(x => titleFrom(x.text)).find(Boolean);
    if (text && !state.title) state.title = text;
  } else if (p.type === 'user_message' && !state.title) {
    state.title = titleFrom(p.message);
  } else if (['custom_tool_call','function_call'].includes(p.type)) {
    const name = (p.name || '').toLowerCase();
    state.phase = /request_user_input/.test(name) ? '等你回复' :
      /search|browse|web/.test(name) ? '正在查资料' :
      /patch|edit/.test(name) ? '正在修改' : '正在使用工具';
  } else if (['custom_tool_call_output','function_call_output','reasoning'].includes(p.type)) {
    state.phase = '正在处理';
  } else if (p.type === 'message' && p.role === 'assistant' && p.phase === 'final_answer') {
    state.phase = '正在回复';
  }
  if (state.phase !== previousPhase) state.phaseSince=at;
}

function parse(line) {
  if (line.length > maxLine) return null;
  try { return JSON.parse(line.toString('utf8')); } catch { return null; }
}

// Find the last lifecycle event without loading a whole conversation or a large attachment.
function turnOffset(fd, end, since) {
  let pos = end, suffix = Buffer.alloc(0);
  while (pos > 0) {
    const start = Math.max(0, pos - chunkSize);
    const block = Buffer.alloc(pos - start);
    fs.readSync(fd, block, 0, block.length, start);
    const data = Buffer.concat([block, suffix]);
    let stop = data.length;
    for (let i = data.length - 1; i >= 0; i--) {
      if (data[i] !== 10) continue;
      const line = data.subarray(i + 1, stop);
      if (line.includes('"event_msg"')) {
        const r = parse(line);
        if (r?.type === 'event_msg' && boundaries.has(r.payload?.type)) {
          // A short turn can finish between discovery scans. Include its start
          // and user message so the finish bubble can still show the task title.
          if (!endings.has(r.payload.type) || Date.parse(r.timestamp)<since) return start+i+1;
        }
      }
      stop = i;
    }
    suffix = data.subarray(0, Math.min(stop, maxLine + 1));
    pos = start;
  }
  return 0;
}

export class Tail {
  constructor(since=Date.now()) { this.since=since; this.active = false; this.offset = null; this.pending = Buffer.alloc(0); }
  update(file, stat) {
    const fd = fs.openSync(file, 'r');
    try {
      if (this.offset === null || this.offset > stat.size || this.identity !== stat.ino) {
        this.active = false;
        this.turn = null;
        this.title = '';
        this.ending = null;
        this.offset = turnOffset(fd, stat.size, this.since);
        this.identity = stat.ino;
        this.pending = Buffer.alloc(0);
        this.skip = false;
      }
      const end = Math.min(this.offset + 4 * 1024 * 1024, stat.size);
      while (this.offset < end) {
        const buf = Buffer.alloc(Math.min(chunkSize, end - this.offset));
        const n = fs.readSync(fd, buf, 0, buf.length, this.offset);
        if (!n) break;
        this.offset += n;
        const data = Buffer.concat([this.pending, buf.subarray(0, n)]);
        let start = 0, stop;
        while ((stop = data.indexOf(10, start)) >= 0) {
          if (!this.skip) {
            const r = parse(data.subarray(start, stop));
            if (r) applyRecord(this, r);
          }
          this.skip = false;
          start = stop + 1;
        }
        if (data.length - start > maxLine) this.skip = true;
        this.pending = this.skip ? Buffer.alloc(0) : Buffer.from(data.subarray(start));
      }
    } finally { fs.closeSync(fd); }
  }
}

export function monitor(root) {
  const tails = new Map();
  const launched = Date.now();
  let files=[],nextDiscovery=0;
  return () => {
    const now=Date.now();
    // Discover new sessions less often than we poll sessions already visible.
    if(now>=nextDiscovery){
      files=listRolloutFiles(root,{includeArchived:false,modifiedSince:now-maxIdle});
      const present=new Set(files);
      for(const file of tails.keys())if(!present.has(file))tails.delete(file);
      nextDiscovery=now+5000;
    }
    const active = [], completed=[];
    for (const file of files) {
      try {
        const stat = fs.statSync(file);
        if (now - stat.mtimeMs > maxIdle) continue;
        let entry=tails.get(file);
        if(!entry || entry.inode!==stat.ino || stat.size<entry.size){
          const header=readSessionHeader(file);
          if(!header)continue;
          const userSession=!header.subagent && (!header.threadSource || header.threadSource==='user');
          entry={inode:stat.ino,size:0,tail:userSession?new Tail(launched):null};
          tails.set(file,entry);
        }
        entry.size=stat.size;
        const tail=entry.tail;
        if(!tail)continue;
        if (tail.offset !== stat.size || tail.identity !== stat.ino) tail.update(file,stat);
        const fallback = 'Codex 任务';
        if (tail.active && tail.offset === stat.size) active.push({
          title:tail.title || fallback, phase:tail.phase, at:stat.mtimeMs,
          id:tail.turn, started:tail.started, phaseSince:tail.phaseSince
        });
        if(tail.ending && tail.ending.at >= launched && Date.now()-tail.ending.at<30000){
          completed.push({...tail.ending,title:tail.ending.title || fallback});
        }
      } catch { /* Sessions can be moved to the archive between listing and reading. */ }
    }
    return {active:active.sort((a,b)=>b.at-a.at),completed:completed.sort((a,b)=>b.at-a.at)};
  };
}

const defaultsFile=new URL('../assets/task-dialogue.defaults.json',import.meta.url);
const defaults=JSON.parse(fs.readFileSync(defaultsFile,'utf8').replace(/^\uFEFF/,''));
const dialogue={...defaults};
let previousCustomStamp;

export function reloadTaskDialogue(file) {
  if (!file) return;
  let preferences={}, stamp;
  try {
    let stat;
    try {stat=fs.statSync(file);} catch(e) {if(e.code!=='ENOENT')throw e;}
    stamp=stat ? [stat.ino,stat.mtimeMs,stat.size].join(':') : 'defaults';
    if(stamp===previousCustomStamp)return;
    if(stat){
      if(stat.size>2*1024*1024) return;
      const saved=JSON.parse(fs.readFileSync(file,'utf8').replace(/^\uFEFF/,''));
      if(saved.version!==1 || !saved.groups || typeof saved.groups!=='object' || Array.isArray(saved.groups))return;
      preferences=saved.groups;
    }
    const next={};
    for(const kind of Object.keys(defaults)){
      if(!Object.hasOwn(preferences,kind)){next[kind]=defaults[kind];continue;}
      const rows=preferences[kind];
      if(!Array.isArray(rows)||!rows.length||rows.length>200||rows.some(s=>typeof s!=='string'||!s.trim()||s.length>512||s.split('\n').length>3))return;
      next[kind]=[...new Set(rows)];
    }
    for(const kind of Object.keys(next)){
      if(JSON.stringify(dialogue[kind])===JSON.stringify(next[kind]))continue;
      dialogue[kind]=next[kind];
      decks.delete(kind);
      if(runningCard?.kind===kind)runningCard=null;
      for(const key of choices.keys())if(JSON.parse(key)[0]===kind)choices.delete(key);
    }
    previousCustomStamp=stamp;
  }catch { /* Keep the working list if the file is being replaced or is unreadable. */ }
}


// Each category gets its own shuffled deck. Keep the chosen line for a
// display interval because the widget polls repeatedly and tasks can overlap.
const decks = new Map();
const choices = new Map();
function pick(kind,id,round=0){
  const key=JSON.stringify([kind,id,round]);
  if(choices.has(key))return choices.get(key);
  if(!decks.has(kind))decks.set(kind,{remaining:[],last:null});
  const deck=decks.get(kind);
  if(!deck.remaining.length){
    const lines=[...dialogue[kind]];
    for(let i=lines.length-1;i>0;i--){
      const j=randomInt(i+1);
      [lines[i],lines[j]]=[lines[j],lines[i]];
    }
    const next=lines.length-1;
    if(next>0 && lines[next]===deck.last){
      const j=randomInt(next);
      [lines[next],lines[j]]=[lines[j],lines[next]];
    }
    deck.remaining=lines;
  }
  deck.last=deck.remaining.pop();
  choices.set(key,deck.last);
  if(choices.size>512)choices.delete(choices.keys().next().value);
  return deck.last;
}
const runningLineMs=20_000;
let runningCard=null;
let runningDraw=0;

function runningLine(kind,id,now){
  const urgent=kind==='wait'||kind==='reply';
  const leavingUrgent=runningCard && (runningCard.kind==='wait'||runningCard.kind==='reply');
  if(!runningCard || runningCard.id!==id || now<runningCard.from ||
     now-runningCard.from>=runningLineMs || ((urgent||leavingUrgent) && runningCard.kind!==kind)){
    runningCard={id,kind,from:now,line:pick(kind,id,++runningDraw)};
  }
  return runningCard;
}

export function runningScene(t,now=Date.now()){
  const age=Math.max(0,now-t.started), quiet=Math.max(0,now-t.phaseSince);
  let kind='work', heading=t.phase;
  if(t.phase==='等你回复')kind='wait';
  else if(t.phase==='正在回复')kind='reply';
  else if(age>=90000){kind='long';heading='还在忙';}
  else if(t.phase==='正在处理' && quiet>=20000){kind='think';heading='再想一想';}
  else if(t.phase!=='正在处理')kind='tool';
  const card=runningLine(kind,t.id,now);
  return {kind:card.kind,heading,line:card.line,title:t.title};
}
export function endScene(e){
  const kind=!e.success?'stopped':e.duration<=15000?'fast':e.duration>=90000?'longDone':'done';
  return {id:e.id,at:e.at,kind,heading:e.success?'任务完成':'任务已停止',line:pick(kind,e.id),title:e.title};
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const read = monitor(defaultCodexHome());
  const at=process.argv.indexOf('--phrases-file');
  const phrasesFile=at<0?null:process.argv[at+1];
  let previous;
  function tick() {
    try {
      reloadTaskDialogue(phrasesFile);
      const {active,completed} = read();
      const next = JSON.stringify({count:active.length,task:active.length?runningScene(active[0]):null,ends:completed.slice(0,8).map(endScene)});
      if (next !== previous) { process.stdout.write(next+'\n'); previous=next; }
    } catch { process.exit(1); }
  }
  tick();
  if (!process.argv.includes('--once')) {
    process.stdin.resume();
    process.stdin.once('end',()=>process.exit());
    setInterval(tick, 1000);
  }
}
