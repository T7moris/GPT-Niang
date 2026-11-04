import path from 'node:path';
import {recoverInstall} from './core/install-recovery.mjs';
if(process.versions.electron)process.noAsar=true;
const dataDir=path.resolve(process.argv[2]),token=process.argv[3];
try{const result=await recoverInstall(dataDir,{token});console.log(JSON.stringify(result));if(result.busy)process.exitCode=2;}
catch(error){console.error(error.stack);process.exitCode=1;}
