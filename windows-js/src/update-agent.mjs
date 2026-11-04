import {runUpdate} from "./core/update-transaction.mjs";
if(process.versions.electron)process.noAsar=true;
const args=process.argv.slice(3),resume=args.indexOf("--launcher-resume");
try{await runUpdate(process.argv[2],{recover:args.includes("--recover"),launcherResume:resume>=0?args.slice(resume+1):null});}
catch(error){console.error(error.message);process.exitCode=1;}
