import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import * as legacy from './update-legacy.mjs';
import {runLegacyBridge} from './javascript-migration/migration/legacy-bridge.mjs';
export * from './update-legacy.mjs';
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  if(process.argv[2]==='--validate-package')legacy.validateExtractedPackage(...process.argv.slice(3,7));
  else {
    const file=path.resolve(process.argv[2]),config=JSON.parse(fs.readFileSync(file,'utf8').replace(/^\uFEFF/,''));
    if(process.platform!=='win32'||!config.dataDir||!legacy.versionParts(config.version)||path.resolve(config.appDir)!==path.dirname(file))throw Error('Invalid updater configuration');
    const agentDir=config.updateAgent??path.join(process.env.LOCALAPPDATA,'GPTNiangUsage','update-agent');
    const binding=JSON.parse(fs.readFileSync(path.join(agentDir,'binding.json'),'utf8').replace(/^\uFEFF/,''));
    if(path.resolve(binding.appDir)!==path.resolve(config.appDir)||path.resolve(binding.dataDir)!==path.resolve(config.dataDir))throw Error('Updater installation binding mismatch');
    await runLegacyBridge(config,{legacy,mode:['automatic','automatic-enabled','cleanup'].includes(process.argv[3])?process.argv[3]:'manual'});
  }
}
