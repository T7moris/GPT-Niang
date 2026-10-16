// Original character micro-voice. Generated from the standalone experiment; no browser dependency.

import { encodeWav, noiseGenerator } from './voice-wave.mjs';

export const BLIP_DEFAULTS = { speed: 0.85, pitch: 0, variation: 14, length: 82, volume: 45, mood: 'normal' };

const clamp = (v , lo , hi ) => Math.max(lo, Math.min(hi, v));
const moodSettings = { normal: [0,1], happy: [1.2,1.08], curious: [0.5,.93], sad: [-1.5,.8], surprised: [1.8,1.04], thoughtful: [-.5,.84] };

// A small, stable character voice. Text drives rhythm, not phonetic vowel selection.
export function planBlips(tokens , options ) {
  const events = []; let time = .045, position = 0, walk = 0;
  const random = noiseGenerator(tokens.reduce((seed,t) => Math.imul(seed,31)+(t.source.codePointAt(0)??0),41));
  const [moodPitch, pace] = moodSettings[options.mood];
  const speed = clamp(options.speed,.5,1.4)*pace;
  for(let i=0;i<tokens.length;i++) {
    const token=tokens[i];
    if(token.kind==='pause') { time += Math.min(650,token.pauseMs)/1000/Math.sqrt(speed); position=0; walk*=.3; continue; }
    if(token.kind!=='vowel') continue;
    const next=tokens[i+1]; const last=!next || next.kind==='pause';
    walk=walk*.8+random()*.2;
    const question=last && /[?？]/.test(next?.source??'');
    const contour = question || options.mood==='curious' ? (last?1.1:0) : last?-.55:0;
    const pitch=clamp(options.pitch,-8,8)+moodPitch+contour+walk*clamp(options.variation,0,100)/100*2;
    const duration=clamp(options.length,40,95)/1000*(last?1.08:1);
    // English stays in word-sized syllable groups rather than reading every letter.
    const step=Math.max(duration+.025,.122/speed)*(token.english?.stress===1?1.1:1);
    events.push({start:time,duration,pitch,variant:position%5===3?1:position%7===6?2:0,tokenIndex:i,gain:position%3===0?1:.91});
    time+=step; position++;
  }
  return {events,duration:time+.08};
}

// Original glottal/formant micro-voice, no game sound assets.
// Soft harmonic roll-off and a rounded envelope give a lighter character voice;
// pitch alone is not used to create the new timbre. Three subtle takes
// share the same identity; no bit crushing or repeated buffer hard cuts.
export function renderBlip(event , sampleRate )               {
  const pcm=new Float32Array(Math.ceil(event.duration*sampleRate));
  const random=noiseGenerator(117+event.variant); const f0=398*Math.pow(2,event.pitch/12);
  const formants=event.variant===1?[760,2250,3570]:event.variant===2?[710,2140,3470]:[735,2200,3520];
  const weights=Array.from({length:Math.min(24,Math.floor(sampleRate*.45/f0))},(_,h)=> {
    const hz=(h+1)*f0;
    return (0.10+1.35*Math.exp(-.5*((hz-formants[0])/235)**2)+.65*Math.exp(-.5*((hz-formants[1])/340)**2)+.12*Math.exp(-.5*((hz-formants[2])/430)**2))/(Math.pow(h+1,1.65)*(1+(hz/2800)**4));
  });
  let phase=0, breath=0, filtered=0, peak=0;
  const lowpass=1-Math.exp(-2*Math.PI*2600/sampleRate);
  for(let i=0;i<pcm.length;i++) {
    const t=i/sampleRate,p=t/event.duration;
    // Tiny downward settling rather than a cartoon whistle glide.
    phase+=2*Math.PI*f0*(1+.006*Math.sin(p*Math.PI*2))/sampleRate;
    let voiced=0;for(let h=0;h<weights.length;h++)voiced+=weights[h]*Math.sin(phase*(h+1)+h*.19);
    const noise=random();
    breath=breath*.85+noise*.15;
    // Rounded whole-note envelope removes the tiny flat-topped grain sensation.
    // Keep the final release after filtering so no filter tail bridges the gap.
    const envelope=Math.sin(Math.PI*Math.min(1,p))**1.25;
    filtered+=(voiced+.018*breath-filtered)*lowpass;
    pcm[i]=filtered*envelope*(1-.12*p);peak=Math.max(peak,Math.abs(pcm[i]));
  }
  for(let i=0;i<pcm.length;i++)pcm[i]=pcm[i]/Math.max(.01,peak)*.44*event.gain;
  return pcm;
}
export function renderBlipWav(tokens , options )       {
  const plan=planBlips(tokens,options);
  if(!plan.events.length)throw Error('请先输入可以发声的文字。');
  if(plan.events.length>400)throw Error('下载请控制在400个音节以内；长文本仍可播放。');
  const rate=44100,pcm=new Float32Array(Math.ceil(plan.duration*rate));
  for(const event of plan.events) {const samples=renderBlip(event,rate),offset=Math.round(event.start*rate);for(let i=0;i<samples.length;i++)pcm[offset+i]+=samples[i]*clamp(options.volume,0,100)/100;}
  return new Blob([encodeWav(pcm,rate)],{type:'audio/wav'});
}
