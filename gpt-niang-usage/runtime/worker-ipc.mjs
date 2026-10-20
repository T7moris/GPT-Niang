import net from 'node:net';
import {randomUUID} from 'node:crypto';
import {workerEndpoint} from './worker-state.mjs';

// The pipe crosses per-process filesystem views while keeping a single writer.
// It offers only a fresh read-only usage request, never arbitrary commands.
export function requestPipeRefresh(dataDir,{timeoutMs=45000,connectTimeoutMs=300}={}){
  // macOS retains its kernel lock and filesystem queue; there is no pipe server.
  if(process.platform==='darwin')return Promise.resolve(null);
  return new Promise(resolve=>{
    const id=randomUUID(),deadline=Date.now()+timeoutMs;let finished=false,buffer='',timer;
    const socket=net.createConnection(workerEndpoint(dataDir));
    socket.setEncoding('utf8');
    const finish=value=>{if(finished)return;finished=true;clearTimeout(timer);socket.destroy();resolve(value);};
    timer=setTimeout(()=>finish(null),Math.min(connectTimeoutMs,timeoutMs));
    socket.on('error',()=>finish(null));socket.on('close',()=>finish(null));
    socket.on('connect',()=>{
      clearTimeout(timer);timer=setTimeout(()=>finish(null),Math.max(0,deadline-Date.now()));
      socket.write(JSON.stringify({id,method:'refresh'})+'\n');
    });
    socket.on('data',chunk=>{
      buffer+=chunk.toString('utf8');if(buffer.length>2*1024*1024)return finish(null);
      const end=buffer.indexOf('\n');if(end<0)return;
      try{const result=JSON.parse(buffer.slice(0,end));finish(result.requestId===id&&result.snapshot&&typeof result.snapshot==='object'?result.snapshot:null);}catch{finish(null);}
    });
  });
}

export function createPipeRefreshHandler(enqueue){
  const pending=new Map();
  return {
    onConnection(socket){
      let buffer='',accepted=false,id;
      socket.setEncoding('utf8');
      socket.on('error',()=>{});socket.setTimeout(50000,()=>socket.destroy());
      socket.on('close',()=>{if(id&&pending.get(id)===socket)pending.delete(id);});
      socket.on('data',chunk=>{
        if(accepted)return;
        buffer+=chunk.toString('utf8');if(buffer.length>4096){socket.destroy();return;}
        const end=buffer.indexOf('\n');if(end<0)return;
        let request;try{request=JSON.parse(buffer.slice(0,end));}catch{socket.destroy();return;}
        if(request?.method!=='refresh'||typeof request.id!=='string'||!/^[0-9a-f-]{36}$/i.test(request.id)||pending.size>=64||pending.has(request.id)){socket.destroy();return;}
        accepted=true;id=request.id;pending.set(id,socket);enqueue();
      });
    },
    takeBatch(){const batch=[...pending];pending.clear();return batch;},
    complete(batch,snapshot){for(const [id,socket] of batch)if(!socket.destroyed)socket.end(JSON.stringify({requestId:id,snapshot})+'\n');},
    // Release claimed clients too: they are no longer in the pending map.
    // An empty disconnect makes the client use its filesystem fallback.
    fail(batch){for(const [,socket] of batch)if(!socket.destroyed&&!socket.writableEnded)socket.destroy();},
    get pendingCount(){return pending.size;}
  };
}
