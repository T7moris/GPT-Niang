import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {readUsage,stopUsageQueries} from '../runtime/usage.mjs';
import {ClipPlayer} from '../ui/clip-player.mjs';

function service(mode){return `const readline=require('node:readline');const lines=readline.createInterface({input:process.stdin});
const keep=setInterval(()=>{},1000);process.on('SIGTERM',()=>{});
lines.on('line',line=>{const m=JSON.parse(line);if(!m.id||${JSON.stringify(mode)}==='timeout')return;
const result=m.id===1?{}:m.id===2?{account:{type:'chatgpt',id:'fixture-account'}}:{rateLimits:{primary:{windowDurationMins:300,usedPercent:12,resetsAt:2000000000}}};
const response=${JSON.stringify(mode)}==='account-error'&&m.id===2?{error:{code:-1}}:{result};process.stdout.write(JSON.stringify({id:m.id,...response})+'\\n');});
lines.on('close',()=>{if(${JSON.stringify(mode)}!=='ignore-eof'){clearInterval(keep);setTimeout(()=>process.exit(0),20);}});`;}
for(const mode of ['success','account-error','timeout','ignore-eof'])test('quota child cleanup waits for close: '+mode,async t=>{
 let child,closed=false,kills=0;
 t.after(async()=>{if(child?.exitCode===null&&child?.signalCode===null){const done=once(child,'close');child.kill('SIGKILL');await done;}});
 const result=await readUsage('fixture',{timeoutMs:mode==='timeout'?150:3000,shutdownGraceMs:80,spawnProcess:(_file,args)=>{
   assert.deepEqual(args,['app-server','--stdio','-c','features.plugins=false']);
   child=spawn(process.execPath,['-e',service(mode)],{windowsHide:true,stdio:'pipe'});child.once('close',()=>closed=true);
   const kill=child.kill.bind(child);child.kill=(...args)=>{kills++;return kill(...args);};return child;
 }});
 assert.equal(closed,true,'result must not race an unreaped child');
 assert.equal(result.queryOk,mode==='success'||mode==='ignore-eof');
 assert.equal(result.errorCode==='APP_SERVER_CLEANUP_TIMEOUT',false);
 if(mode==='ignore-eof')assert.ok(kills>=1);else assert.equal(kills,0);
});
test('worker shutdown cancels an active query and reaps its child',async()=>{
 let child,closed=false;
 const query=readUsage('fixture',{timeoutMs:10000,shutdownGraceMs:80,spawnProcess:()=>{child=spawn(process.execPath,['-e',service('timeout')],{windowsHide:true,stdio:'pipe'});child.once('close',()=>closed=true);return child;}});
 await once(child,'spawn');await stopUsageQueries();
 assert.equal((await query).errorCode,'CANCELLED');assert.equal(closed,true);
});
test('successful repeated reads do not retain process exit listeners',async()=>{
 const before=process.listenerCount('exit');
 for(let n=0;n<8;n++)assert.equal((await readUsage('fixture',{shutdownGraceMs:80,spawnProcess:()=>spawn(process.execPath,['-e',service('success')],{windowsHide:true,stdio:'pipe'})})).queryOk,true);
 assert.equal(process.listenerCount('exit'),before);
});
function audioFixture(){
 const nodes=[],timers=new Map();let counter=0;
 const context={state:'running',currentTime:1,destination:{},createBufferSource(){const node={started:false,stopped:[],disconnected:0,connect(gain){return gain;},start(){this.started=true;},stop(at){this.stopped.push(at);},disconnect(){this.disconnected++;}};nodes.push(node);return node;},createGain(){return {gain:{value:0,events:[],cancelScheduledValues(at){this.events.push(['cancel',at]);},setValueAtTime(value,at){this.events.push(['set',value,at]);},linearRampToValueAtTime(value,at){this.events.push(['ramp',value,at]);}},connect(){return this;},disconnect(){this.disconnected=true;}};}};
 const player=new ClipPlayer({context:()=>context,schedule:fn=>{const id=++counter;timers.set(id,fn);return id;},cancel:id=>timers.delete(id)});
 return {context,player,nodes,timers};
}
test('new audio starts immediately while the previous source fades independently',()=>{
 const {context,player,nodes,timers}=audioFixture();player.play({},0.7);const first=player.active;
 context.currentTime=2;player.play({},0.4);
 assert.equal(nodes[1].started,true);assert.deepEqual(nodes[0].stopped,[2.008]);assert.equal(nodes[0].disconnected,0);
 assert.deepEqual(first.gain.gain.events,[['cancel',2],['set',0.7,2],['ramp',0,2.008]]);
 assert.equal(player.active.gain.gain.value,0.4);nodes[0].onended();assert.equal(nodes[0].disconnected,1);assert.equal(timers.size,0);player.close();
});
test('extreme retriggering stays bounded and immediate stop releases all audio nodes',()=>{
 const {player,nodes,timers}=audioFixture();
 for(let n=0;n<1000;n++){player.play({},0.9);assert.ok(player.tails.size<=2);assert.ok(timers.size<=2);}
 assert.equal(nodes.filter(node=>node.disconnected===0).length,3);
 player.stop({immediate:true});assert.equal(timers.size,0);assert.equal(player.tails.size,0);assert.equal(player.active,null);assert.ok(nodes.every(node=>node.disconnected===1));
 player.close();player.play({},1);assert.equal(nodes.length,1000);
});
test('suspended contexts and missing ended events still release old sounds',()=>{
 const {player,context,nodes,timers}=audioFixture();player.play({},1);player.stop();
 for(const fn of [...timers.values()])fn();assert.equal(nodes[0].disconnected,1);assert.equal(timers.size,0);
 player.play({},1);context.state='suspended';player.stop();assert.equal(nodes[1].disconnected,1);assert.equal(player.tails.size,0);
});
