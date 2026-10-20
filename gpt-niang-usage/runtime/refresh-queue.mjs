import fs from 'node:fs';

// Only explicit requests made during a query schedule another query. A failed
// query or write never retries itself; the next request/heartbeat may retry it.
export function createRefreshQueue(run,{now=Date.now,onError=()=>{}}={}) {
  let busy=false,pending=false,lastRefresh=0,inFlight=null;
  async function drain() {
    busy=true;
    try {
      do {
        pending=false;lastRefresh=now();
        try{await run();}
        catch(error){try{onError(error);}catch{}}
      } while(pending);
    } finally {busy=false;}
  }
  return {
    request(){pending=true;if(!busy)inFlight=drain();return inFlight;},
    get busy(){return busy;},
    get pending(){return pending;},
    get lastRefresh(){return lastRefresh;}
  };
}

export function mergeUsageSnapshot(previous,next,now=Date.now()) {
  if(next.queryOk && previous?.ok && next.accountKey && next.accountKey===previous.accountKey && next.observedAt<previous.observedAt)return previous;
  if(!next.ok && !next.clearPrevious && previous?.ok && next.accountKey && next.accountKey===previous.accountKey) {
    return {...previous,queryOk:false,error:next.error,checkedAt:now};
  }
  return {...next,checkedAt:now};
}

// The flag's contents are a request token, not just a filesystem timestamp.
// Different requests sharing the same mtime still cause a refresh.
export function readRefreshRequest(file) {
  try {
    const stat=fs.statSync(file,{bigint:true});
    if(stat.size<=0n || stat.size>4096n)return null;
    return stat.mtimeNs.toString()+':'+fs.readFileSync(file,'utf8');
  } catch {return null;}
}
