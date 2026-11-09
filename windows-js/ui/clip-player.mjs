// Retrigger immediately; only the outgoing voice gets a short, bounded tail.
export class ClipPlayer {
  constructor({context,fadeSeconds=0.008,maxTails=2,schedule=setTimeout,cancel=clearTimeout}) {
    Object.assign(this,{context,fadeSeconds,maxTails,schedule,cancel});
    this.active=null;this.tails=new Set();this.closed=false;
  }
  release(voice,stop=false) {
    if(!voice||voice.released)return;
    voice.released=true;
    if(voice.timer!==null)this.cancel(voice.timer);
    voice.timer=null;voice.source.onended=null;
    if(stop)try{voice.source.stop();}catch{}
    try{voice.source.disconnect();}catch{}
    try{voice.gain.disconnect();}catch{}
    this.tails.delete(voice);
    if(this.active===voice)this.active=null;
  }
  play(buffer,volume) {
    if(this.closed||!buffer)return;
    this.stop();
    const context=this.context();if(!context)return;
    let voice;
    try {
      if(context.state==='suspended')void context.resume().catch(()=>{});
      voice={source:context.createBufferSource(),gain:context.createGain(),timer:null,released:false};
      voice.source.buffer=buffer;voice.gain.gain.value=volume;
      voice.source.connect(voice.gain).connect(context.destination);
      voice.source.onended=()=>this.release(voice);
      this.active=voice;voice.source.start();
    } catch {this.release(voice,true);}
  }
  stop({immediate=false}={}) {
    const voice=this.active;this.active=null;
    if(immediate){this.release(voice,true);for(const tail of [...this.tails])this.release(tail,true);return;}
    if(!voice)return;
    const context=this.context();
    if(!context||context.state!=='running'){this.release(voice,true);return;}
    try {
      const at=context.currentTime,end=at+this.fadeSeconds,param=voice.gain.gain;
      param.cancelScheduledValues(at);param.setValueAtTime(param.value,at);param.linearRampToValueAtTime(0,end);
      this.tails.add(voice);voice.source.stop(end);
      // Audio-context suspension must not retain old sources or gain nodes.
      voice.timer=this.schedule(()=>this.release(voice,true),this.fadeSeconds*1000+80);
      for(const oldest of this.tails){if(this.tails.size<=this.maxTails)break;this.release(oldest,true);}
    } catch {this.release(voice,true);}
  }
  close() {this.closed=true;this.stop({immediate:true});}
}
