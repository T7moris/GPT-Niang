import {parentPort,workerData} from 'node:worker_threads';
import {updateFiles} from './core/update-files.mjs';
// Update archives contain Electron's own .asar files; treat them as files.
if(process.versions.electron)process.noAsar=true;
try{parentPort.postMessage({ok:true,result:await updateFiles(workerData)});}
catch(error){parentPort.postMessage({ok:false,error:error.message});}
