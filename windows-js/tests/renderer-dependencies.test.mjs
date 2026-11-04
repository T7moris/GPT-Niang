import test from 'node:test';
import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
test('renderer entry points and shared modules have only browser-loadable relative imports',()=>{
  const root=fileURLToPath(new URL('../',import.meta.url));
  const script=`import fs from 'node:fs';import path from 'node:path';import vm from 'node:vm';import assert from 'node:assert/strict';
  const root=${JSON.stringify(root)},seen=new Set();
  function inspect(file) {
    if(seen.has(file))return;seen.add(file);
    const module=new vm.SourceTextModule(fs.readFileSync(file,'utf8'),{identifier:file});
    for(const name of module.dependencySpecifiers){assert.ok(name.startsWith('./')||name.startsWith('../'),path.relative(root,file)+' imports '+name);inspect(path.resolve(path.dirname(file),name));}
  }
  for(const name of fs.readdirSync(path.join(root,'ui')).filter(name=>name.endsWith('.mjs')))inspect(path.join(root,'ui',name));
  assert.ok(seen.has(path.join(root,'src/core/quote-values.mjs')));
  process.stdout.write(String(seen.size));`;
  const result=spawnSync(process.execPath,['--experimental-vm-modules','--input-type=module','-e',script],{windowsHide:true,encoding:'utf8',timeout:10000});
  assert.equal(result.status,0,result.stderr);assert.ok(Number(result.stdout)>10);
});
