import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
const app=fileURLToPath(new URL('../../',import.meta.url));
export function personalState(dataDir) {
  const id='custom-'+'a'.repeat(32),removed='custom-'+'b'.repeat(32),press='c'.repeat(32)+'.wav',release='d'.repeat(32)+'.wav';
  const values={
    'settings.json':{layoutVersion:2,right:17,bottom:-12,anchor:'left',side:'left',left:31,scale:1.2,bubbleScale:0.8,characterId:id,soundOn:true,soundVolume:0.37,bubbleTapAdvance:true,followHost:false,desktopTopmost:true,desktopLeft:-210,desktopTop:330,autoQuoteEnabled:true,autoQuoteIntervalSeconds:900,taskCompletionBubble:true,colorMode:'special',colorChance:7,colorTextChance:5,unknownPreference:{text:'保留未知设置'}},
    'quotes.json':{version:1,quotes:[{text:'第一条自定义语录 🌙',weight:0.25},{text:'第二条｜保留权重',weight:23}]},
    'quote-sources.json':{version:1,custom:'原有自定义来源'},
    'characters.json':{version:1,characters:[{id,file:id+'.png',name:'我的角色 🌟'}],removed:[{id:removed,file:removed+'.png',name:'可恢复角色',removedAt:'2026-10-01T00:00:00Z'}]},
    'audio-preferences.json':{version:1,mode:'custom',press:{file:press,name:'按下.wav'},release:{file:release,name:'松开.wav'}},
    'color-triggers.json':{version:1,quotes:['自定义触发词']},
    'update-preferences.json':{automatic:false,unknownPreference:'保留'},
  };
  fs.mkdirSync(dataDir,{recursive:true});
  for(const [name,value]of Object.entries(values))fs.writeFileSync(path.join(dataDir,name),'\uFEFF'+JSON.stringify(value,null,2)+'\r\n');
  fs.copyFileSync(path.join(dataDir,'audio-preferences.json'),path.join(dataDir,'audio-preferences.json.bak'));
  for(const [name,source]of Object.entries({
    ['characters/'+id+'.png']:'gpt-dragon-niang-bust.png',
    ['characters/removed/'+removed+'.png']:'gpt-dragon-niang-bust.png',
    ['sounds/'+press]:'press.wav',['sounds/'+release]:'release.wav',
  })) {const file=path.join(dataDir,name);fs.mkdirSync(path.dirname(file),{recursive:true});fs.copyFileSync(path.join(app,'assets',source),file);}
  fs.writeFileSync(path.join(dataDir,'用户自留内容.txt'),'不属于已知配置的内容也不能清理。\r\n');
  const files={};
  for(const name of [...Object.keys(values),'audio-preferences.json.bak','characters/'+id+'.png','characters/removed/'+removed+'.png','sounds/'+press,'sounds/'+release,'用户自留内容.txt'])
    files[name]=createHash('sha256').update(fs.readFileSync(path.join(dataDir,name))).digest('hex');
  return {id,removed,values,files};
}
export function personalHashes(dataDir,files) {
  return Object.fromEntries(Object.keys(files).map(name=>[name,createHash('sha256').update(fs.readFileSync(path.join(dataDir,name))).digest('hex')]));
}
