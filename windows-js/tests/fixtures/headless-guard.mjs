import childProcess from 'node:child_process';
import {syncBuiltinESMExports} from 'node:module';

// Preload only for the explicit headless test list. Refuse external processes
// before any test module loads, including in file-processing worker threads.
for(const name of ['spawn','spawnSync','exec','execSync','execFile','execFileSync','fork']){
  childProcess[name]=()=>{
    throw Object.assign(Error('无界面检查禁止启动外部进程。'),{code:'HEADLESS_PROCESS_BLOCKED'});
  };
}
syncBuiltinESMExports();
globalThis[Symbol.for('gpt-niang.headless-guard')]=true;
