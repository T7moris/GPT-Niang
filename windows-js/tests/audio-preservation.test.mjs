import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {AudioStore} from '../src/core/audio.mjs';
const app=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
function fixture(t){const dir=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-audio-preserve-'));t.after(()=>{assert.equal(path.dirname(path.resolve(dir)),path.resolve(os.tmpdir()));fs.rmSync(dir,{recursive:true,force:true});});fs.mkdirSync(path.join(dir,'sounds'));return dir;}
const make=(n)=>n.repeat(32)+'.wav';
const prefs=file=>({version:1,mode:'custom',press:{file,name:'fixture.wav'},release:null});
const put=(f,v)=>fs.writeFileSync(f,JSON.stringify(v));
test('save retains the current backup and unrelated sounds, retiring only a superseded backup',t=>{
  const dir=fixture(t),sounds=path.join(dir,'sounds'),file=path.join(dir,'audio-preferences.json'),current=make('a'),oldBackup=make('b'),next=make('c'),unrelated=make('d');
  for(const name of [current,oldBackup,next,unrelated])fs.writeFileSync(path.join(sounds,name),'fixture');
  put(file,prefs(current));put(file+'.bak',prefs(oldBackup));const store=new AudioStore(app,dir);store.save(prefs(next));
  assert.equal(JSON.parse(fs.readFileSync(file+'.bak','utf8')).press.file,current);
  assert.ok(fs.existsSync(path.join(sounds,current)),'the new backup sound must remain');
  assert.ok(fs.existsSync(path.join(sounds,next)));assert.ok(fs.existsSync(path.join(sounds,unrelated)),'unrelated files must remain');
  assert.equal(fs.existsSync(path.join(sounds,oldBackup)),false);
});
test('invalid backups prevent audio cache deletion',t=>{
  const dir=fixture(t),sounds=path.join(dir,'sounds'),file=path.join(dir,'audio-preferences.json'),current=make('a'),next=make('b'),unrelated=make('c');
  for(const name of [current,next,unrelated])fs.writeFileSync(path.join(sounds,name),'fixture');put(file,prefs(current));fs.writeFileSync(file+'.bak','invalid-json');
  new AudioStore(app,dir).save(prefs(next));for(const name of [current,next,unrelated])assert.ok(fs.existsSync(path.join(sounds,name)));
});
