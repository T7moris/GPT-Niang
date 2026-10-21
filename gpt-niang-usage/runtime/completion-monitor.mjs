import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {StringDecoder} from 'node:string_decoder';
import {fileURLToPath} from 'node:url';
import {startDesktopWorkSource} from './desktop-work-state.mjs';

const NORMAL_ENDINGS=new Set(['task_complete','turn_complete']);
const MAX_READ_BYTES=4*1024*1024,MAX_LINE_CHARACTERS=1024*1024,MAX_SEEN_TURNS=4096;
const ACTIVE_TURN_STALE_MS=120000,RESUME_GRACE_MS=5000,RESUME_STATE_MAX_AGE_MS=5*60*1000;

// A crash can happen between a turn finishing and the monitor reading it.
// Remembering the last scan time (and the newest emitted completion) lets the
// next process re-read the short window before it instead of baselining those
// records away, without re-notifying a turn that was already shown.
function loadMonitorState(file){
  try{
    const value=JSON.parse(fs.readFileSync(file,'utf8'));
    if(value && Number.isFinite(value.at) && Date.now()-value.at<RESUME_STATE_MAX_AGE_MS){
      return {at:value.at,lastEnded:Number.isFinite(value.lastEnded)?value.lastEnded:0};
    }
  }catch{}
  return null;
}
function saveMonitorState(file,at,lastEnded){
  try{fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,JSON.stringify({at,lastEnded}));}catch{}
}

export function parseCompletionRecord(record,{sessionId='',seenTurns=null,since=0}={}) {
  if(record?.type!=='event_msg' || !NORMAL_ENDINGS.has(record.payload?.type))return null;
  const payload=record.payload;
  if(payload.error || ['failed','cancelled','canceled','aborted','interrupted'].includes(payload.status))return null;
  const turnId=payload.turn_id??record.turn_id;
  if(typeof turnId!=='string' || !turnId || turnId.length>256)return null;
  const endedAt=typeof record.timestamp==='number'?record.timestamp:Date.parse(record.timestamp);
  if(since && (!Number.isFinite(endedAt) || endedAt<since))return null;
  const key=sessionId+'\0'+turnId;
  if(seenTurns?.has(key))return null;
  if(seenTurns){seenTurns.add(key);if(seenTurns.size>MAX_SEEN_TURNS)seenTurns.delete(seenTurns.values().next().value);}
  return {type:'completion',sessionId,turnId,endedAt:Number.isFinite(endedAt)?endedAt:null};
}

export function completionMessage(payload, eventType, maxCharacters = 28) {
  if (eventType === 'turn_aborted' || payload?.error) return '本轮已结束';

  const cleaned = cleanMessage(payload?.last_agent_message);
  if (!cleaned) return 'Codex 本轮已完成';

  const characters = Array.from(cleaned);
  const excerpt = characters.length > maxCharacters
    ? characters.slice(0, Math.max(0, maxCharacters - 1)).join('') + '…'
    : cleaned;
  return `Codex 已完成：${excerpt}`;
}

export function cleanMessage(value) {
  if (typeof value !== 'string') return '';
  return value
    .replace(/```[^\r\n]*\r?\n?([\s\S]*?)```/g, '$1')
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/^\s{0,3}#{1,6}\s+/gm, '')
    .replace(/^\s*>\s?/gm, '')
    .replace(/^\s*[-*+]\s+/gm, '')
    .replace(/\*\*(.+?)\*\*/g, '$1')
    .replace(/__(.+?)__/g, '$1')
    .replace(/\*(.+?)\*/g, '$1')
    .replace(/_(.+?)_/g, '$1')
    .replace(/`([^`]+)`/g, '$1')
    .replace(/`+/g, '')
    .replace(/[\r\n\t]+/g, ' ')
    .replace(/\s{2,}/g, ' ')
    .trim();
}


const TERMINAL_EVENTS=new Set(['task_complete','turn_complete','turn_completed','turn_aborted','task_aborted','turn_cancelled','turn_failed','task_failed']);
const START_EVENTS=new Set(['task_started','turn_started']);
export function parseTerminalRecord(record,{sessionId='',seenTurns=null,since=0}={}) {
  if(record?.type!=='event_msg' || !TERMINAL_EVENTS.has(record.payload?.type))return null;
  const payload=record.payload,turnId=payload.turn_id??payload.task_id??record.turn_id;
  if(typeof turnId!=='string' || !turnId || turnId.length>256)return null;
  const endedAt=typeof record.timestamp==='number'?record.timestamp:Date.parse(record.timestamp);
  if(since && (!Number.isFinite(endedAt) || endedAt<since))return null;
  const key=sessionId+'\0'+turnId;
  if(seenTurns?.has(key))return null;
  if(seenTurns){seenTurns.add(key);if(seenTurns.size>MAX_SEEN_TURNS)seenTurns.delete(seenTurns.values().next().value);}
  const success=['task_complete','turn_complete','turn_completed'].includes(payload.type) && !payload.error && !['failed','cancelled','canceled','aborted','interrupted'].includes(payload.status);
  return {type:success?'completion':'work_end',sessionId,turnId,endedAt:Number.isFinite(endedAt)?endedAt:null,eventType:payload.type,success,message:success?completionMessage(payload,payload.type):'本轮已结束'};
}

export function parseWorkStartRecord(record, {seenStarts = null, seenTurns = null, sessionId = ''} = {}) {
  if (record?.type !== 'event_msg' || !START_EVENTS.has(record.payload?.type)) return null;
  const turnId = record.payload.turn_id ?? record.payload.task_id ?? record.turn_id;
  if (typeof turnId !== 'string' || !turnId.trim()) return null;
  const key = `${sessionId}\0${turnId}`;
  if (seenStarts?.has(key) || seenTurns?.has(key)) return null;
  seenStarts?.add(key);
  if (seenStarts?.size > MAX_SEEN_TURNS) seenStarts.delete(seenStarts.values().next().value);
  return {eventType: record.payload.type, turnId, started: true};
}

// Recover only the latest activity in a recently written parent conversation.
// Old interrupted conversations and historical completions are never replayed.
export function recoverWorkingTurn(file, stat = fs.statSync(file), now = Date.now()) {
  if (now - stat.mtimeMs > ACTIVE_TURN_STALE_MS || file.split(path.sep).includes('archived_sessions')) return null;
  const count = Math.min(stat.size, MAX_READ_BYTES), start = stat.size - count;
  const buffer = Buffer.alloc(count); let fd;
  try {
    fd = fs.openSync(file, 'r'); fs.readSync(fd, buffer, 0, count, start);
    const lines = buffer.toString('utf8').split('\n');
    if (start) lines.shift();
    for (let i = lines.length - 1; i >= 0; i--) {
      if (lines[i].length > MAX_LINE_CHARACTERS || !lines[i].includes('"event_msg"')) continue;
      try {
        const record = JSON.parse(lines[i]);
        if (record?.type !== 'event_msg') continue;
        if (TERMINAL_EVENTS.has(record.payload?.type)) return null;
        const activity = parseWorkStartRecord(record);
        if (activity) return activity;
      } catch {}
    }
  } finally { if (fd !== undefined) fs.closeSync(fd); }
  return null;
}


function fileIdentity(stat){return `${stat.dev}:${stat.ino}`;}

export class CompletionRolloutTail {
  constructor(file,{sessionId=path.basename(file),baseline=false,since=0,includeStarts=false}={}) {
    this.file=file;this.sessionId=sessionId;this.since=since;this.offset=0;this.includeStarts=includeStarts;this.seenStarts=new Set();this.resetCount=0;
    this.pending='';this.discardingLongLine=false;this.decoder=new StringDecoder('utf8');this.seenTurns=new Set();
    const stat=fs.statSync(file);this.identity=fileIdentity(stat);
    if(baseline)this.offset=stat.size;
  }
  update() {
    let stat;try{stat=fs.statSync(this.file);}catch{return [];}
    const identity=fileIdentity(stat);
    if(identity!==this.identity || stat.size<this.offset){
      // Retain dedupe and the time boundary when a log rotates or is truncated.
      this.resetCount++;this.identity=identity;this.offset=0;this.pending='';this.discardingLongLine=false;this.decoder=new StringDecoder('utf8');
    }
    const remaining=Math.min(stat.size-this.offset,MAX_READ_BYTES);
    if(remaining<=0)return [];
    const buffer=Buffer.alloc(remaining);let count=0,fd;
    try{fd=fs.openSync(this.file,'r');count=fs.readSync(fd,buffer,0,remaining,this.offset);}catch{return [];}
    finally{if(fd!==undefined)fs.closeSync(fd);}
    if(!count)return [];
    this.offset+=count;
    const lines=(this.pending+this.decoder.write(buffer.subarray(0,count))).split('\n');this.pending=lines.pop();
    const notifications=[];
    for(const raw of lines){
      if(this.discardingLongLine){this.discardingLongLine=false;continue;}
      const line=raw.endsWith('\r')?raw.slice(0,-1):raw;
      if(line.length>MAX_LINE_CHARACTERS || !line.includes('"event_msg"'))continue;
      try{const record=JSON.parse(line);const event=parseTerminalRecord(record,{sessionId:this.sessionId,seenTurns:this.seenTurns,since:this.since});if(event)notifications.push(event);else if(this.includeStarts){const started=parseWorkStartRecord(record,{sessionId:this.sessionId,seenStarts:this.seenStarts,seenTurns:this.seenTurns});if(started)notifications.push(started);}}catch{}
    }
    if(this.pending.length>MAX_LINE_CHARACTERS){this.pending='';this.discardingLongLine=true;}
    return notifications;
  }
}

function isWithin(root,file){const relative=path.relative(root,file);return relative!=='' && relative!=='..' && !relative.startsWith('..'+path.sep) && !path.isAbsolute(relative);}
function readSessionHeader(file) {
  let fd;
  try{
    fd=fs.openSync(file,'r');const buffer=Buffer.alloc(64*1024),count=fs.readSync(fd,buffer,0,buffer.length,0);
    const contents=buffer.subarray(0,count).toString('utf8'),newline=contents.indexOf('\n');
    if(newline<0)return null;
    const record=JSON.parse(contents.slice(0,newline).replace(/^\uFEFF/,''));
    if(record?.type!=='session_meta')return null;
    const source=record.payload?.source;
    return {subagent:source==='subagent' || Boolean(source && typeof source==='object' && Object.hasOwn(source,'subagent'))};
  }catch{return null;}finally{if(fd!==undefined)fs.closeSync(fd);}
}

export function listRolloutFiles(codexHome) {
  const files=[];
  for(const name of ['sessions','archived_sessions']){
    let root;try{root=fs.realpathSync(path.join(codexHome,name));}catch{continue;}
    const pending=[root];
    while(pending.length){
      const current=pending.pop();let entries;try{entries=fs.readdirSync(current,{withFileTypes:true});}catch{continue;}
      for(const entry of entries){
        const candidate=path.join(current,entry.name);
        if(entry.isDirectory()){pending.push(candidate);continue;}
        if(!entry.isFile() || !entry.name.endsWith('.jsonl'))continue;
        try{const real=fs.realpathSync(candidate);if(isWithin(root,real))files.push(real);}catch{}
      }
    }
  }
  return [...new Set(files)];
}
export function defaultCodexHome(env=process.env){return path.resolve(env.CODEX_HOME || path.join(env.USERPROFILE || env.HOME || os.homedir(),'.codex'));}

export class CompletionMonitor {
  constructor({codexHome=defaultCodexHome(),intervalMs=1000,onNotification=()=>{},onWorkState=()=>{},since=Date.now(),stateFile=null}={}){
    this.onWorkState=onWorkState;this.activeTurns=new Set();this.activeLastSeen=new Map();this.sessionMtimes=new Map();this.desktopActiveCount=0;this.desktopStatus={status:'starting'};this.lastWorkSignature=null;this.codexHome=codexHome;this.intervalMs=intervalMs;this.onNotification=onNotification;this.since=since;
    this.stateFile=stateFile;this.resume=false;this.lastStateSave=0;this.lastEnded=0;
    this.tails=new Map();this.subagentSessions=new Set();this.timer=null;
  }
  start(){
    if(this.timer)return;
    if(this.stateFile){
      const saved=loadMonitorState(this.stateFile);
      if(saved!==null){
        this.lastEnded=saved.lastEnded;
        this.since=Math.max(0,Math.max(saved.at-RESUME_GRACE_MS,saved.lastEnded+1));
        this.resume=true;
      }
    }
    this.scan(!this.resume);
    this.persistState(true);
    this.timer=setInterval(()=>this.scan(false),this.intervalMs);this.timer.unref?.();
  }
  persistState(force=false){
    if(!this.stateFile)return;
    const now=Date.now();
    if(!force && now-this.lastStateSave<5000)return;
    this.lastStateSave=now;saveMonitorState(this.stateFile,now,this.lastEnded);
  }
  scan(baseline=false){
    const files=listRolloutFiles(this.codexHome),present=new Set(),now=Date.now();
    for(const file of files){
      const sessionId=path.basename(file);present.add(sessionId);if(this.subagentSessions.has(sessionId))continue;
      let stat;try{stat=fs.statSync(file);}catch{continue;}
      const previousMtime=this.sessionMtimes.get(sessionId);
      if(previousMtime===undefined||previousMtime!==stat.mtimeMs){
        this.sessionMtimes.set(sessionId,stat.mtimeMs);
        const activityAt=Math.min(now,stat.mtimeMs);
        for(const key of this.activeTurns)if(key.startsWith(sessionId+'\0'))this.activeLastSeen.set(key,activityAt);
      }
      let tail=this.tails.get(sessionId);
      if(!tail){
        const header=readSessionHeader(file);if(header===null)continue;
        if(header.subagent){this.subagentSessions.add(sessionId);continue;}
        // During crash recovery, files touched inside the grace window are read
        // from their start and filtered by `since` instead of being skipped.
        let fileBaseline=baseline;
        if(fileBaseline && this.resume && stat.mtimeMs>=this.since)fileBaseline=false;
        try{tail=new CompletionRolloutTail(file,{sessionId,baseline:fileBaseline,since:this.since,includeStarts:true});}catch{continue;}
        this.tails.set(sessionId,tail);if(fileBaseline){try{const started=recoverWorkingTurn(file,stat,now);if(started)this.markTurnStarted(sessionId+'\0'+started.turnId,stat.mtimeMs,now);}catch{}continue;}
      }else{tail.file=file;}
      const resets=tail.resetCount,events=tail.update();if(tail.resetCount!==resets)this.clearSession(sessionId);
      for(const event of events){
        const key=sessionId+'\0'+event.turnId;
        if(event.started){this.markTurnStarted(key,stat.mtimeMs,now);continue;}
        this.activeTurns.delete(key);this.activeLastSeen.delete(key);
        if(Number.isFinite(event.endedAt) && event.endedAt>this.lastEnded)this.lastEnded=event.endedAt;
        try{this.onNotification(event);}catch{}
      }
    }
    for(const sessionId of this.tails.keys())if(!present.has(sessionId)){this.clearSession(sessionId);this.tails.delete(sessionId);this.sessionMtimes.delete(sessionId);}
    this.expireStaleTurns(now);
    this.publishWorkState();this.persistState();
  }
  markTurnStarted(key,mtimeMs,now){this.activeTurns.add(key);this.activeLastSeen.set(key,Math.min(now,mtimeMs));}
  expireStaleTurns(now=Date.now()){
    for(const key of this.activeTurns){
      const lastSeen=this.activeLastSeen.get(key);
      if(!Number.isFinite(lastSeen)||now-lastSeen>=ACTIVE_TURN_STALE_MS){this.activeTurns.delete(key);this.activeLastSeen.delete(key);}
    }
  }
  clearSession(sessionId){for(const key of this.activeTurns)if(key.startsWith(sessionId+'\0')){this.activeTurns.delete(key);this.activeLastSeen.delete(key);}}
  setDesktopWorkState(state){this.desktopStatus=state||{};this.desktopActiveCount=Number.isSafeInteger(state?.activeCount)&&state.activeCount>=0?state.activeCount:0;this.publishWorkState();}
  publishWorkState(){
    const count=this.activeTurns.size+this.desktopActiveCount;
    const state={eventType:'work_state',working:count>0,activeTurns:count,localActiveTurns:this.activeTurns.size,cloudActiveTasks:this.desktopActiveCount,sourceStatus:this.desktopStatus.status||'starting',sourceError:this.desktopStatus.lastError||null};
    const signature=JSON.stringify(state);if(signature===this.lastWorkSignature)return;this.lastWorkSignature=signature;
    try{this.onWorkState(state);}catch{}
  }
  stop(){if(this.timer)clearInterval(this.timer);this.timer=null;this.activeTurns.clear();this.activeLastSeen.clear();this.sessionMtimes.clear();this.desktopActiveCount=0;this.publishWorkState();}

}

function run(){
  const stateFile=process.argv[2]||null;
  const monitor=new CompletionMonitor({onNotification:event=>{const {message,...status}=event;process.stdout.write(JSON.stringify(status)+'\n');},onWorkState:state=>process.stdout.write(JSON.stringify(state)+'\n'),stateFile});
  monitor.start();const desktop=startDesktopWorkSource({root:path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..'),codexHome:monitor.codexHome,onState:state=>monitor.setDesktopWorkState(state)});process.stdin.resume();
  process.stdin.on('end',()=>{desktop?.stop();monitor.stop();process.exit(0);});
  process.on('SIGTERM',()=>{desktop?.stop();monitor.stop();process.exit(0);});
}
if(process.argv[1] && fileURLToPath(import.meta.url)===path.resolve(process.argv[1]))run();
