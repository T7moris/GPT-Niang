import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {StringDecoder} from 'node:string_decoder';
import {fileURLToPath} from 'node:url';

const NORMAL_ENDINGS=new Set(['task_complete','turn_complete']);
const MAX_READ_BYTES=4*1024*1024,MAX_LINE_CHARACTERS=1024*1024,MAX_SEEN_TURNS=4096;
const RESUME_GRACE_MS=5000,RESUME_STATE_MAX_AGE_MS=5*60*1000;
const MISSING_SESSION_GRACE_MS=30000,MAX_MISSING_SESSIONS=256,MAX_CHECKPOINTS=4096,BOUNDARY_BYTES=64;

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

function fileIdentity(stat){return `${stat.dev}:${stat.ino}`;}

export class CompletionRolloutTail {
  constructor(file,{sessionId=path.basename(file),baseline=false,since=0}={}) {
    this.file=file;this.sessionId=sessionId;this.since=since;this.offset=0;
    this.pending='';this.discardingLongLine=false;this.decoder=new StringDecoder('utf8');this.seenTurns=new Set();
    const stat=fs.statSync(file);this.identity=fileIdentity(stat);
    if(baseline)this.offset=stat.size;
    this.lineStartOffset=this.offset;this.lastKnownSize=stat.size;this.boundaryBytes=Buffer.alloc(0);this.boundaryProof=null;
  }
  update() {
    let stat;try{stat=fs.statSync(this.file);}catch{return [];}
    this.lastKnownSize=stat.size;
    const identity=fileIdentity(stat);
    if(identity!==this.identity || stat.size<this.offset){
      // Retain dedupe and the time boundary when a log rotates or is truncated.
      this.identity=identity;this.offset=0;this.lineStartOffset=0;this.boundaryBytes=Buffer.alloc(0);this.boundaryProof=null;this.pending='';this.discardingLongLine=false;this.decoder=new StringDecoder('utf8');
    }
    const remaining=Math.min(stat.size-this.offset,MAX_READ_BYTES);
    if(remaining<=0)return [];
    const buffer=Buffer.alloc(remaining);let count=0,fd;
    try{fd=fs.openSync(this.file,'r');count=fs.readSync(fd,buffer,0,remaining,this.offset);}catch{return [];}
    finally{if(fd!==undefined)fs.closeSync(fd);}
    if(!count)return [];
    const bytes=buffer.subarray(0,count),lastNewline=bytes.lastIndexOf(10);
    if(lastNewline>=0)this.lineStartOffset=this.offset+lastNewline+1;
    this.offset+=count;
    this.boundaryBytes=count>=BOUNDARY_BYTES?Buffer.from(bytes.subarray(-BOUNDARY_BYTES)):Buffer.concat([this.boundaryBytes,bytes]).subarray(-BOUNDARY_BYTES);
    this.boundaryProof=null;
    const lines=(this.pending+this.decoder.write(buffer.subarray(0,count))).split('\n');this.pending=lines.pop();
    const notifications=[];
    for(const raw of lines){
      if(this.discardingLongLine){this.discardingLongLine=false;continue;}
      const line=raw.endsWith('\r')?raw.slice(0,-1):raw;
      if(line.length>MAX_LINE_CHARACTERS || !line.includes('"event_msg"'))continue;
      try{const event=parseCompletionRecord(JSON.parse(line),{sessionId:this.sessionId,seenTurns:this.seenTurns,since:this.since});if(event)notifications.push(event);}catch{}
    }
    if(this.pending.length>MAX_LINE_CHARACTERS){this.pending='';this.discardingLongLine=true;}
    return notifications;
  }
}

function isWithin(root,file){const relative=path.relative(root,file);return relative!=='' && relative!=='..' && !relative.startsWith('..'+path.sep) && !path.isAbsolute(relative);}
function readSessionHeader(file,{withBoundary=false}={}) {
  let fd;
  try{
    fd=fs.openSync(file,'r');const buffer=Buffer.alloc(64*1024),count=fs.readSync(fd,buffer,0,buffer.length,0);
    const contents=buffer.subarray(0,count).toString('utf8'),newline=contents.indexOf('\n');
    if(newline<0)return null;
    const record=JSON.parse(contents.slice(0,newline).replace(/^\uFEFF/,''));
    if(record?.type!=='session_meta')return null;
    const source=record.payload?.source;
    let baselineBoundary=null;
    if(withBoundary){
      try{
        const size=count<buffer.length?count:fs.fstatSync(fd).size,length=Math.min(size,BOUNDARY_BYTES),bytes=Buffer.alloc(length);
        if(size<=count)buffer.copy(bytes,0,size-length,size);
        if(size<=count || fs.readSync(fd,bytes,0,length,size-length)===length)baselineBoundary={offset:size,bytes,proof:{length,sha256:createHash('sha256').update(bytes).digest('hex')}};
      }catch{}
    }
    return {subagent:source==='subagent' || Boolean(source && typeof source==='object' && Object.hasOwn(source,'subagent')),baselineBoundary};
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

function checkpointMatches(file,tail,checkpoint){
  if(tail.lastKnownSize<checkpoint.offset)return {matches:false};
  if(checkpoint.offset===0)return {matches:true,boundary:Buffer.alloc(0)};
  // Without a saved boundary, an inode can have been truncated and rewritten
  // beyond the old offset while it was missing; reread rather than skip data.
  if(!checkpoint.proof)return {matches:false};
  let fd;
  try{
    fd=fs.openSync(file,'r');const bytes=Buffer.alloc(checkpoint.proof.length);
    if(fs.readSync(fd,bytes,0,bytes.length,checkpoint.offset-bytes.length)!==bytes.length)return null;
    if(createHash('sha256').update(bytes).digest('hex')!==checkpoint.proof.sha256)return {matches:false};
    const length=Math.min(checkpoint.resumeOffset,BOUNDARY_BYTES);
    let boundary=bytes;
    if(checkpoint.resumeOffset!==checkpoint.offset || bytes.length!==length){
      boundary=Buffer.alloc(length);
      if(fs.readSync(fd,boundary,0,length,checkpoint.resumeOffset-length)!==length)return null;
    }
    return {matches:true,boundary};
  }catch{return null;}finally{if(fd!==undefined)fs.closeSync(fd);}
}

export class CompletionMonitor {
  constructor({codexHome=defaultCodexHome(),intervalMs=1000,onNotification=()=>{},since=Date.now(),stateFile=null}={}){
    this.codexHome=codexHome;this.intervalMs=intervalMs;this.onNotification=onNotification;this.since=since;
    this.stateFile=stateFile;this.resume=false;this.lastStateSave=0;this.lastEnded=0;
    this.tails=new Map();this.subagentSessions=new Map();this.seenTurns=new Set();this.checkpoints=new Map();this.timer=null;
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
  scan(baseline=false,now=Date.now()){
    const files=listRolloutFiles(this.codexHome),present=new Set();
    for(const file of files){
      const sessionId=path.basename(file);present.add(sessionId);
      const subagent=this.subagentSessions.get(sessionId);
      if(subagent){subagent.lastSeenAt=now;continue;}
      let tail=this.tails.get(sessionId);
      if(!tail){
        const header=readSessionHeader(file,{withBoundary:baseline});if(header===null)continue;
        if(header.subagent){this.subagentSessions.set(sessionId,{lastSeenAt:now});continue;}
        // During crash recovery, files touched inside the grace window are read
        // from their start and filtered by `since` instead of being skipped.
        let fileBaseline=baseline;
        if(fileBaseline && this.resume){try{if(fs.statSync(file).mtimeMs>=this.since)fileBaseline=false;}catch{}}
        try{tail=new CompletionRolloutTail(file,{sessionId,baseline:fileBaseline,since:this.since});}catch{continue;}
        if(fileBaseline && header.baselineBoundary?.offset===tail.offset){tail.boundaryBytes=header.baselineBoundary.bytes;tail.boundaryProof=header.baselineBoundary.proof;}
        const checkpoint=this.checkpoints.get(sessionId);
        if(checkpoint){
          const sameContent=checkpointMatches(file,tail,checkpoint);
          // A transient access failure is not evidence that the file changed.
          if(sameContent===null)continue;
          if(sameContent.matches){
            tail.offset=checkpoint.resumeOffset;tail.lineStartOffset=checkpoint.resumeOffset;
            tail.discardingLongLine=checkpoint.discardingLongLine;tail.since=checkpoint.since;
            tail.boundaryBytes=sameContent.boundary;
            if(checkpoint.resumeOffset===checkpoint.offset)tail.boundaryProof=checkpoint.proof;
          }else{
            // With unread data or an unfinished line, timestamps may precede
            // the outage even though the completion was not read yet.
            const mustReadBacklog=checkpoint.hadUnread || checkpoint.partial || !checkpoint.proof || now<checkpoint.lastSeenAt;
            tail.since=mustReadBacklog?checkpoint.since:Math.max(checkpoint.since,checkpoint.lastSeenAt-RESUME_GRACE_MS);
            tail.offset=0;tail.lineStartOffset=0;
          }
          this.checkpoints.delete(sessionId);fileBaseline=false;
        }
        tail.lastSeenAt=now;this.tails.set(sessionId,tail);if(fileBaseline)continue;
      }else{tail.file=file;}
      tail.lastSeenAt=now;
      for(const event of tail.update()){
        const key=event.sessionId+'\0'+event.turnId;
        if(this.seenTurns.has(key))continue;
        this.seenTurns.add(key);if(this.seenTurns.size>MAX_SEEN_TURNS)this.seenTurns.delete(this.seenTurns.values().next().value);
        if(Number.isFinite(event.endedAt) && event.endedAt>this.lastEnded)this.lastEnded=event.endedAt;
        try{this.onNotification(event);}catch{}
      }
    }
    this.pruneSessions(present,now);
    this.persistState();
  }
  pruneSessions(present,now){
    const missing=[];
    const retire=(cache,id,entry)=>{if(cache===this.tails)this.rememberCheckpoint(id,entry);cache.delete(id);};
    for(const cache of [this.tails,this.subagentSessions])for(const [id,entry] of cache){
      if(!present.has(id)){
        if(now-entry.lastSeenAt>=MISSING_SESSION_GRACE_MS)retire(cache,id,entry);
        else missing.push({cache,id,entry,at:entry.lastSeenAt});
      }
    }
    // Allow an archive move or a brief directory outage, without retaining an
    // unbounded number of deleted sessions even during that grace period.
    missing.sort((a,b)=>a.at-b.at);
    for(let i=0;i<missing.length-MAX_MISSING_SESSIONS;i++)retire(missing[i].cache,missing[i].id,missing[i].entry);
  }
  rememberCheckpoint(id,tail){
    const incomplete=tail.decoder.lastNeed?tail.decoder.lastTotal-tail.decoder.lastNeed:0;
    const proofBytes=tail.boundaryBytes;
    // A tiny suffix after a large baseline is not a reliable continuity proof.
    const proof=proofBytes.length>=16 || tail.offset===proofBytes.length?
      {length:proofBytes.length,sha256:createHash('sha256').update(proofBytes).digest('hex')}:tail.boundaryProof;
    const resumeOffset=tail.discardingLongLine?tail.offset-incomplete:tail.lineStartOffset;
    const checkpoint={identity:tail.identity,offset:tail.offset,resumeOffset,proof,discardingLongLine:tail.discardingLongLine,
      hadUnread:tail.offset<tail.lastKnownSize,partial:Boolean(tail.pending || incomplete || tail.discardingLongLine),since:tail.since,lastSeenAt:tail.lastSeenAt};
    this.checkpoints.delete(id);this.checkpoints.set(id,checkpoint);
    if(this.checkpoints.size>MAX_CHECKPOINTS)this.checkpoints.delete(this.checkpoints.keys().next().value);
  }
  stop(){if(this.timer)clearInterval(this.timer);this.timer=null;this.tails.clear();this.subagentSessions.clear();this.seenTurns.clear();this.checkpoints.clear();}
}

function run(){
  const stateFile=process.argv[2]||null;
  const monitor=new CompletionMonitor({onNotification:event=>process.stdout.write(JSON.stringify(event)+'\n'),stateFile});
  monitor.start();process.stdin.resume();
  process.stdin.on('end',()=>{monitor.stop();process.exit(0);});
  process.on('SIGTERM',()=>{monitor.stop();process.exit(0);});
}
if(process.argv[1] && fileURLToPath(import.meta.url)===path.resolve(process.argv[1]))run();
