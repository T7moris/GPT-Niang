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

const dialogue = {
  work:[
    "Ciallo～\n这单我接啦！",
    "先挑一小块下手。\n大的待会儿再说。",
    "工位借半张？\n尾巴得有地方放嘛～",
    "爪子热好了……\n开工！",
    "来活了？\n那我把宝箱合上。",
    "今天的第一步，\n就从你这句开始。",
    "好，我来！\n别按住我的尾巴呀～",
    "让我看看，\n今天要养个\n什么小问题。"
  ],
  tool:[
    "我翻翻工具箱……\n咦，在最底下！",
    "先试一下。\n猜错了也比嘴硬强。",
    "借我个扳手。……\n工具栏里那个。",
    "我看一眼实际结果，\n再回来发言。",
    "让我戳一下？\n轻轻的，有分寸～",
    "工具我来拿，\n你帮我看着宝箱。",
    "能让工具动手的事，\n何必用角顶？",
    "先跑一步看看。\n尾巴暂时不用上场。"
  ],
  think:[
    "唔……又绕回来了？\n换个小例子试试。",
    "我没卡……\n是思路在等红灯。",
    "反例呢？我总觉得\n它躲在桌子底下。",
    "这个我好像懂了。\n等我试着讲明白。",
    "角都想热了……\n先把条件捋顺。",
    "给我一小会儿，\n刚才那条线头找着了。",
    "先别塞 token！\n我这口还没嚼完……",
    "这段逻辑，\n是不是咬住\n自己的尾巴了？"
  ],
  long:[
    "盯着我能加速吗？\n……好像有一点。",
    "工时又涨啦……\n地球 online，\n我的金币呢？",
    "这么小的任务，\n怎么养这么大了？\n先养着吧～",
    "别数秒啦，去喝口水。\n这儿有我。",
    "要是摇尾巴也能结账，\n我早发财啦 (￣▽￣)",
    "尾巴坐麻了……\n往旁边挪半格，\n接着干！",
    "你看额度，我看进度。\n各忙各的。",
    "长任务是一条龙服务。\n嗯，只有我一条龙。"
  ],
  wait:[
    "分岔口到了～\n走哪边？我跟着。",
    "这一步归你拍板。\n爪印我就不代签啦。",
    "耳朵竖好啦！\n你说 (・ω・)",
    "给个准话？\n我好把尾巴转过去。",
    "轮到你啦～\n我趴这儿等会儿。",
    "你的主意呢？\n我想听原版。",
    "先不乱猜。\n猜错要花 token……\n这笔谁赔？",
    "你点头我就走。\n点我的角可不算。"
  ],
  reply:[
    "等我把话理顺，\n省你再读一遍。",
    "刚才那一大团思路，\n正在叠成几句话。",
    "结论写前面。\n我的碎碎念往后排。",
    "这句也太绕了吧？\n我给它剪短点。",
    "我把重点圈给你。\n爪印就免了。",
    "让我找个好懂的说法。\n别急着翻页。",
    "字要一个个排队，\n尾巴不能插队。",
    "等一下……\n这个逗号\n有自己的想法？"
  ],
  fast:[
    "看见了吗？没看见？\n已经好啦！",
    "尾巴才摇半下……\n收工啦～",
    "高性能↑\n这回没画反！",
    "这题手感好，\n连角都没用上。",
    "我刚坐下……\n又能站起来了？！",
    "这么快？！\n快夸我 (￣▽￣)",
    "叮。结果比我的\n开场白先到了。",
    "这单按工时收费？\n亏了呀……"
  ],
  done:[
    "给。你看结果，\n我靠一会儿。",
    "这件归你。\n功劳归……我们俩！",
    "今天这点小胜利，\n记你名下啦～",
    "结果在聊天里。\n翻它，别翻我尾巴。",
    "嗯，是我干的！\n角还是不许摸～",
    "先验货。满意的话，\n夸龙一句。",
    "今天又多会了一点！\n这点经验收好～",
    "收工！奖励我\n趴三秒 (－ω－)"
  ],
  longDone:[
    "久等啦～\n尾巴都坐扁了……",
    "这单终于交差。\n我的水都凉啦。",
    "金币没挖着，\n结果给你挖回来了。",
    "高性能↓？哼！\n这趟比的是耐力。",
    "这单我记住了。\n下回带个坐垫。",
    "大活收尾，该轮到\n龙伸个懒腰了。",
    "你等了好久，\n我也忙了好久……\n来看吧！",
    "花的是 token，\n练出来的是耐心。"
  ],
  stopped:[
    "收到，收爪～",
    "先停这儿。\n想接着走的时候叫我。",
    "尾巴打个结，\n记住停在哪儿。",
    "这回先歇一歇，\n宝藏又不会长腿。",
    "好～我把工位\n让出来一会儿。",
    "爪子离开键盘！\n你看，两只都在～",
    "这页先夹张书签。",
    "休息一下？正好，\n我的角也要散热。"
  ]
};

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
export function runningScene(t,now=Date.now()){
  const age=Math.max(0,now-t.started), quiet=Math.max(0,now-t.phaseSince);
  let kind='work', heading=t.phase;
  if(t.phase==='等你回复')kind='wait';
  else if(t.phase==='正在回复')kind='reply';
  else if(age>=90000){kind='long';heading='还在忙';}
  else if(t.phase==='正在处理' && quiet>=20000){kind='think';heading='再想一想';}
  else if(t.phase!=='正在处理')kind='tool';
  return {kind,heading,line:pick(kind,t.id,Math.floor(age/45000)),title:t.title};
}
export function endScene(e){
  const kind=!e.success?'stopped':e.duration<=15000?'fast':e.duration>=90000?'longDone':'done';
  return {id:e.id,at:e.at,kind,heading:e.success?'任务完成':'任务已停止',line:pick(kind,e.id),title:e.title};
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const read = monitor(defaultCodexHome());
  let previous;
  function tick() {
    try {
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
