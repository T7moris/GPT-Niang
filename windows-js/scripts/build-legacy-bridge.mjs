import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
import {deflateRawSync} from 'node:zlib';
import {crc32,safePackagePath} from '../src/core/archive.mjs';
import {readJson,inside} from '../src/core/storage.mjs';
import {compareVersions,versionParts} from '../src/core/update-network.mjs';
const app=fileURLToPath(new URL('../',import.meta.url));
export function legacyBridgeFiles(baseline,version) {
  const pkg=readJson(path.join(baseline,'package.json'));
  if(!versionParts(version)||!pkg||compareVersions(version,pkg.version)<=0)throw Error('兼容更新版本必须高于旧版本');
  const required=readJson(path.join(baseline,'runtime/install-files.json'));
  if(!Array.isArray(required))throw Error('旧版安装文件清单缺失');
  const files={},add=(name,bytes)=>{safePackagePath(name);files['gpt-niang-usage/'+name]=Buffer.from(bytes);};
  for(const name of new Set(required))add(name,fs.readFileSync(inside(baseline,name)));
  for(const row of readJson(path.join(baseline,'assets/characters.json'))?.characters??[]) {
    if(typeof row.file==='string')add('assets/'+row.file,fs.readFileSync(inside(path.join(baseline,'assets'),row.file)));
  }
  const extras={
    'runtime/update-legacy.mjs':fs.readFileSync(path.join(baseline,'runtime/update.mjs')),
    'runtime/update.mjs':fs.readFileSync(path.join(app,'migration/update-wrapper.mjs')),
    'runtime/javascript-migration/migration/legacy-bridge.mjs':fs.readFileSync(path.join(app,'migration/legacy-bridge.mjs')),
  };
  for(const name of ['archive','storage','update-network','update-cleanup','install-recovery','plugin-registration','update-transaction','installation-health'])extras['runtime/javascript-migration/src/core/'+name+'.mjs']=fs.readFileSync(path.join(app,'src/core/'+name+'.mjs'));
  extras['runtime/javascript-migration/runtime/process-identity.mjs']=fs.readFileSync(path.join(app,'runtime/process-identity.mjs'));
  for(const [name,bytes]of Object.entries(extras))add(name,bytes);
  add('runtime/install-files.json',JSON.stringify([...new Set([...required,...Object.keys(extras)])],null,2)+'\n');
  add('package.json',JSON.stringify({...pkg,version,architecture:'powershell-wpf-bridge'},null,2)+'\n');
  add('.codex-plugin/plugin.json',JSON.stringify({...readJson(path.join(baseline,'.codex-plugin/plugin.json')),version},null,2)+'\n');
  files['.agents/plugins/marketplace.json']=Buffer.from(JSON.stringify({name:'gpt-niang-local',plugins:[{name:'gpt-niang-usage',source:'./gpt-niang-usage'}]},null,2)+'\n');
  for(const name of ['安装GPT娘.cmd','打开GPT娘.cmd','停用GPT娘.cmd','检测套餐.cmd','README.md','LICENSE','更新记录.md']) {
    const file=inside(path.dirname(baseline),name);
    if(fs.existsSync(file)&&fs.statSync(file).isFile())files[name]=fs.readFileSync(file);
  }
  if(Object.keys(files).some(name=>/\.(exe|dll)$/i.test(name)||/(^|\/)(installation|settings|update-preferences|update-transaction)\.json$/i.test(name)))throw Error('兼容包不能含运行二进制或个人设置');
  return files;
}
export function legacyBridgeZip(files,version) {
  const local=[],central=[];let offset=0;
  for(const [file,bytes]of Object.entries(files)) {
    const name=Buffer.from('GPTNiang-Windows-v'+version+'/'+file),packed=deflateRawSync(bytes),crc=crc32(bytes),header=Buffer.alloc(30),record=Buffer.alloc(46);
    header.writeUInt32LE(0x04034b50);header.writeUInt16LE(20,4);header.writeUInt16LE(0x800,6);header.writeUInt16LE(8,8);header.writeUInt32LE(crc,14);header.writeUInt32LE(packed.length,18);header.writeUInt32LE(bytes.length,22);header.writeUInt16LE(name.length,26);
    record.writeUInt32LE(0x02014b50);record.writeUInt16LE(20,4);record.writeUInt16LE(20,6);record.writeUInt16LE(0x800,8);record.writeUInt16LE(8,10);record.writeUInt32LE(crc,16);record.writeUInt32LE(packed.length,20);record.writeUInt32LE(bytes.length,24);record.writeUInt16LE(name.length,28);record.writeUInt32LE(offset,42);
    local.push(header,name,packed);central.push(record,name);offset+=header.length+name.length+packed.length;
  }
  const directory=Buffer.concat(central),end=Buffer.alloc(22),count=Object.keys(files).length;
  end.writeUInt32LE(0x06054b50);end.writeUInt16LE(count,8);end.writeUInt16LE(count,10);end.writeUInt32LE(directory.length,12);end.writeUInt32LE(offset,16);
  return Buffer.concat([...local,directory,end]);
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  const args=process.argv.slice(2),option=name=>args[args.indexOf(name)+1];
  if(!args.includes('--baseline')||!args.includes('--version')||!args.includes('--output'))throw Error('请指定 --baseline、--version 和新的 --output 目录；此命令只生成本地兼容包');
  const baseline=path.resolve(option('--baseline')),version=option('--version'),output=path.resolve(option('--output'));
  if(fs.existsSync(output)||output===path.dirname(output)||output.startsWith(baseline+path.sep))throw Error('请使用独立的新输出目录');
  const files=legacyBridgeFiles(baseline,version),bytes=legacyBridgeZip(files,version),name='gpt-niang-usage-widget-v'+version+'-windows.zip';
  // Validate with the unmodified old updater, including its 50 MiB/binary limits.
  const old=await import(pathToFileURL(path.join(baseline,'runtime/update.mjs')));
  old.validatePackage(old.inspectZip(bytes),version);
  fs.mkdirSync(output,{recursive:true});fs.writeFileSync(path.join(output,name),bytes,{flag:'wx'});
  const sha256=createHash('sha256').update(bytes).digest('hex');fs.writeFileSync(path.join(output,'SHA256SUMS.txt'),sha256+'  '+name+'\n');
  console.log(JSON.stringify({output,version,name,files:Object.keys(files).length,bytes:bytes.length,sha256,oldValidatorAccepted:true,published:false}));
}
