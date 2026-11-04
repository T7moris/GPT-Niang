import fs from 'node:fs';import path from 'node:path';import {createHash} from 'node:crypto';
import {runUpdateIO} from '../../src/core/update-io.mjs';import {zipFixture,packageFiles} from './zip-fixture.mjs';
const dir=process.argv[2],files=packageFiles(),rawName='node_modules/electron/dist/resources/default_app.asar',raw=Buffer.from('ordinary file, not an archive');
delete files['integrity.json'];files[rawName]=raw;
const hash=b=>createHash('sha256').update(b).digest('hex');files['integrity.json']=Buffer.from(JSON.stringify({version:1,files:Object.fromEntries(Object.entries(files).map(([name,value])=>[name,hash(value)]))}));
const bytes=zipFixture(files),sums=Buffer.from(hash(bytes)+'  fixture.zip\n'),staged=await runUpdateIO({kind:'stage',bytes,sums,asset:{name:'fixture.zip'},version:'1.3.6',dataDir:dir});
// The parent process still has Electron's ASAR patch; inspect the file as raw bytes.
process.noAsar=true;fs.writeFileSync(path.join(dir,'result.txt'),fs.readFileSync(path.join(staged.directory,rawName)));
