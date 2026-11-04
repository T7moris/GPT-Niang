import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import sharp from 'sharp';
import {Characters} from '../src/core/characters.mjs';
const app=fileURLToPath(new URL('../',import.meta.url));
function bitmap({bits=24,gap=0,v4=false}={}){
  const width=4,height=2,header=v4?108:40,maskBytes=bits===16?12:0,offset=14+header+maskBytes+gap,stride=Math.ceil(width*bits/32)*4,bytes=Buffer.alloc(offset+stride*height);
  bytes.write('BM');bytes.writeUInt32LE(bytes.length,2);bytes.writeUInt32LE(offset,10);bytes.writeUInt32LE(header,14);bytes.writeInt32LE(width,18);bytes.writeInt32LE(height,22);bytes.writeUInt16LE(1,26);bytes.writeUInt16LE(bits,28);bytes.writeUInt32LE(v4||bits===16?3:0,30);bytes.writeUInt32LE(stride*height,34);
  if(v4){for(const [index,value]of [0x00ff0000,0x0000ff00,0x000000ff,0xff000000].entries())bytes.writeUInt32LE(value,54+index*4);bytes.writeUInt32LE(0x73524742,70);}
  if(bits===16){for(const [index,value]of [0xf800,0x07e0,0x001f].entries())bytes.writeUInt32LE(value,54+index*4);}
  if(gap)bytes.fill(0x5a,14+header+maskBytes,offset);
  for(let y=0;y<height;y++)for(let x=0;x<width;x++){
    const at=offset+y*stride+x*bits/8;
    if(bits===16)bytes.writeUInt16LE(y?0x001f:0xf800,at);
    else{bytes[at]=y?255:0;bytes[at+1]=0;bytes[at+2]=y?0:255;if(bits===32)bytes[at+3]=x<2?128:255;}
  }
  return bytes;
}
test('BMP pixels and transparency match the original WPF reader for offsets and bitfields',{skip:process.platform!=='win32',timeout:15000},async t=>{
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-bmp-compat-'));t.after(()=>{assert.equal(path.dirname(directory),path.resolve(os.tmpdir()));fs.rmSync(directory,{recursive:true,force:true});});
  const input=path.join(directory,"中文 & # % ' 🌟");fs.mkdirSync(input);
  const files=Object.entries({'offset24.bmp':{gap:16},'rgb565.bmp':{bits:16},'alpha-v4.bmp':{bits:32,v4:true}}).map(([name,spec])=>{const file=path.join(input,name);fs.writeFileSync(file,bitmap(spec));return file;});
  const legacy=fs.readFileSync(path.resolve(app,process.env.GPT_NIANG_LEGACY_ROOT??'../gpt-niang-usage','runtime/characters.ps1'),'utf8'),start=legacy.indexOf('function Read-WidgetCharacterImage('),end=legacy.indexOf('function Import-WidgetCharacter(',start);assert.ok(start>=0&&end>start);
  const quoted=files.map(file=>"'"+file.replaceAll("'","''")+"'").join(','),script=`Add-Type -AssemblyName PresentationCore;${legacy.slice(start,end)}\n$rows=@(foreach($file in @(${quoted})){$image=Read-WidgetCharacterImage $file;$pixels=New-Object byte[] ($image.PixelWidth*$image.PixelHeight*4);$image.CopyPixels($pixels,$image.PixelWidth*4,0);@{name=[IO.Path]::GetFileName($file);pixels=[Convert]::ToBase64String($pixels)}});ConvertTo-Json -InputObject $rows -Compress`;
  const reference=spawnSync(path.join(process.env.WINDIR,'System32/WindowsPowerShell/v1.0/powershell.exe'),['-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',Buffer.from(script,'utf16le').toString('base64')],{windowsHide:true,encoding:'utf8',timeout:10000});assert.equal(reference.status,0,reference.stderr);
  const rows=JSON.parse(reference.stdout.replace(/^\uFEFF/,'')),failures=[],characters=new Characters(app,directory);
  for(const [index,file]of files.entries()){
    const bgra=Buffer.from(rows[index].pixels,'base64'),expected=Buffer.alloc(bgra.length);for(let n=0;n<bgra.length;n+=4){expected[n]=bgra[n+2];expected[n+1]=bgra[n+1];expected[n+2]=bgra[n];expected[n+3]=bgra[n+3];}
    try{const shown=await characters.display({id:'fixture',name:'fixture',path:file}),actual=await sharp(Buffer.from(shown.url.split(',')[1],'base64')).ensureAlpha().raw().toBuffer();assert.deepEqual(actual,expected);}catch(error){failures.push(path.basename(file)+': '+error.message+(error.cause?.stderr?' '+error.cause.stderr.toString():''));}
  }
  assert.deepEqual(failures,[]);
});

test('malformed or oversized BMP input leaves the character catalog and personal files untouched',{skip:process.platform!=='win32',timeout:15000},async t=>{
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),'gpt-bmp-reject-'));t.after(()=>{assert.equal(path.dirname(directory),path.resolve(os.tmpdir()));fs.rmSync(directory,{recursive:true,force:true});});
  const data=path.join(directory,'personal');fs.mkdirSync(data);const catalog=Buffer.from('{"version":1,"characters":[],"removed":[],"personal":"keep"}');fs.writeFileSync(path.join(data,'characters.json'),catalog);fs.writeFileSync(path.join(data,'characters.json.bak'),'keep backup');
  const characters=new Characters(app,data),large=bitmap();large.writeInt32LE(5000,18);
  for(const [name,bytes]of [['broken.bmp',Buffer.from('BMbroken')],['oversized.bmp',large]]){
    const file=path.join(directory,name);fs.writeFileSync(file,bytes);await assert.rejects(characters.import(file),/图片/);
    assert.deepEqual(fs.readFileSync(path.join(data,'characters.json')),catalog);assert.equal(fs.readFileSync(path.join(data,'characters.json.bak'),'utf8'),'keep backup');assert.deepEqual(fs.readdirSync(data).sort(),['characters.json','characters.json.bak']);
  }
});
