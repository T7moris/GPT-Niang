import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {spawnSync} from 'node:child_process';
import {randomUUID} from 'node:crypto';

const pluginId='gpt-niang-usage@gpt-niang-local',marketplace='gpt-niang-local';
const ownedTables=[['marketplaces','gpt-niang-local'],['plugins','gpt-niang-usage@gpt-niang-local']];
const selected=new Map(ownedTables.map((keys,index)=>[JSON.stringify(keys),index===0?'market':'plugin']));
const normalized=value=>path.resolve(value.replace(/^\\\\\?\\/,'' )).toLowerCase();
const same=(a,b)=>typeof a==='string'&&typeof b==='string'&&normalized(a)===normalized(b);
function keys(header){
  const parts=[];let rest=header.trim();
  while(rest){
    const token=rest.match(/^(?:"(?:[^"\\]|\\.)*"|'[^']*'|[A-Za-z0-9_-]+)/)?.[0];
    if(!token)throw Error('无法安全读取 Codex 插件设置分组');
    parts.push(token[0]==='"'?JSON.parse(token):token[0]==="'"?token.slice(1,-1):token);rest=rest.slice(token.length).trim();
    if(!rest)break;if(rest[0]!=='.')throw Error('Codex 插件设置分组格式无效');rest=rest.slice(1).trim();
  }
  return parts;
}
// Only the two owned tables are retained. Quoted multiline text is never
// interpreted as a table, and unrelated account/configuration data is not copied.
export function pluginSections(text){
  const tables=[];let offset=0,multiline=null;
  for(const line of text.match(/[^\n]*\n|[^\n]+$/g)??[]){
    if(!multiline){
      const header=line.match(/^\s*(?:\[\[(.*?)\]\]|\[(.*?)\])\s*(?:#.*)?(?:\r?\n)?$/);
      if(header)tables.push({start:offset,key:keys(header[1]??header[2])});
      else if(/^\s*(?:plugins|marketplaces)\s*=/.test(line))throw Error('Codex 插件设置使用内联表，请先保留现用版本');
    }
    let quote=null;
    for(let i=0;i<line.length;i++){
      const c=line[i];
      if(multiline){if(line.startsWith(multiline,i)){i+=2;multiline=null;}else if(multiline==='"""'&&c==='\\')i++;continue;}
      if(quote){if(quote==='"'&&c==='\\')i++;else if(c===quote)quote=null;continue;}
      if(c==='#')break;
      if(line.startsWith('"""',i)||line.startsWith("'''",i)){multiline=line.slice(i,i+3);i+=2;}
      else if(c==='"'||c==="'")quote=c;
    }
    offset+=line.length;
  }
  if(multiline)throw Error('Codex 设置包含未闭合的多行文本');
  const result={market:null,plugin:null},ranges=[];
  for(let i=0;i<tables.length;i++){
    const table=tables[i],name=selected.get(JSON.stringify(table.key));
    if(!name){if(ownedTables.some(keys=>table.key.length>keys.length&&keys.every((key,index)=>table.key[index]===key)))throw Error('Codex 插件包含嵌套设置，请先保留现用版本');continue;}
    if(result[name]!==null)throw Error('Codex 插件设置出现重复分组');
    const end=tables[i+1]?.start??text.length;result[name]=text.slice(table.start,end);ranges.push({...table,end,name});
  }
  return {sections:result,ranges};
}
export function replacePluginSections(text,sections){
  const {ranges}=pluginSections(text),found=new Set();let output='',offset=0;
  for(const row of ranges){output+=text.slice(offset,row.start)+(sections[row.name]??'');offset=row.end;found.add(row.name);}
  output+=text.slice(offset);
  for(const name of ['market','plugin'])if(!found.has(name)&&sections[name]!==null)output+=(output&&!output.endsWith('\n')?'\n':'')+'\n'+sections[name];
  return output;
}
function call(executable,args,execute,home){
  const result=execute(executable,['plugin',...args,'--json'],{windowsHide:true,timeout:60000,encoding:'utf8',env:{...process.env,CODEX_HOME:home}});
  if(result.error||result.status!==0)throw Error('Codex 插件状态操作失败：'+args.slice(0,2).join(' '));
  try{return JSON.parse(String(result.stdout).replace(/^\uFEFF/,''));}catch{throw Error('Codex 插件状态不是有效 JSON');}
}
function configPath(home){
  if(!path.isAbsolute(home))throw Error('Codex 设置目录无效');
  const file=path.join(home,'config.toml');
  for(let current=file;current!==path.dirname(current);current=path.dirname(current))if(fs.existsSync(current)&&fs.lstatSync(current).isSymbolicLink())throw Error('Codex 设置路径不能包含文件链接');
  return file;
}
export function capturePluginRegistration(plan,{execute=spawnSync,home=process.env.CODEX_HOME??path.join(os.homedir(),'.codex')}={}){
  const file=configPath(home),sections=pluginSections(fs.existsSync(file)?fs.readFileSync(file,'utf8'):'').sections;
  const catalog=call(plan.codexPath,['list','--marketplace',marketplace],execute,home),matches=(catalog.installed??[]).filter(row=>row.pluginId===pluginId&&row.installed===true);
  if(matches.length>1)throw Error('Codex 存在重复 GPT 娘插件注册');
  const previous=matches[0];
  if(previous&&(!same(previous.source?.path,plan.target)||typeof previous.version!=='string'||typeof previous.enabled!=='boolean'))throw Error('Codex GPT 娘插件属于其他安装');
  const markets=call(plan.codexPath,['marketplace','list'],execute,home).marketplaces?.filter(row=>row.name===marketplace)??[];
  if(markets.length>1||markets.some(row=>!same(row.root,plan.marketplaceRoot)))throw Error('Codex GPT 娘插件市场属于其他安装');
  return {schema:1,home:path.resolve(home),codexPath:plan.codexPath,target:plan.target,installVersion:plan.version,marketplaceRoot:plan.marketplaceRoot,sections,previous:previous?{version:previous.version,enabled:previous.enabled}:null};
}
function editConfig(home,edit){
  const file=configPath(home);fs.mkdirSync(path.dirname(file),{recursive:true});
  for(let attempt=0;attempt<5;attempt++){
    const read=()=>fs.existsSync(file)?fs.readFileSync(file,'utf8'):'',before=read(),after=edit(before);
    if(before===after)return;
    const temporary=file+'.gpt-niang-'+randomUUID()+'.tmp';let fd;
    try{
      fd=fs.openSync(temporary,'wx');fs.writeFileSync(fd,after);fs.fsyncSync(fd);fs.closeSync(fd);fd=undefined;
      if(read()!==before)continue;fs.renameSync(temporary,file);return;
    }finally{if(fd!==undefined)fs.closeSync(fd);if(fs.existsSync(temporary))fs.unlinkSync(temporary);}
  }
  throw Error('Codex 设置正被其他操作修改，请稍后重试');
}
export function retainPluginPreference(snapshot){
  if(!snapshot?.previous||snapshot.sections.plugin===null)return;
  editConfig(snapshot.home,text=>replacePluginSections(text,{...pluginSections(text).sections,plugin:snapshot.sections.plugin}));
}
export function restorePluginRegistration(snapshot,{execute=spawnSync}={}){
  if(snapshot?.schema!==1||!path.isAbsolute(snapshot.codexPath??'')||!path.isAbsolute(snapshot.target??'')||!path.isAbsolute(snapshot.marketplaceRoot??''))throw Error('Codex 插件恢复记录无效');
  const file=configPath(snapshot.home),original=snapshot.sections;
  if(!original||Object.keys(original).sort().join(',')!=='market,plugin'||Object.values(original).some(value=>value!==null&&typeof value!=='string'))throw Error('Codex 插件恢复分组无效');
  for(const name of ['market','plugin'])if(original[name]!==null){
    const parsed=pluginSections(original[name]);
    if(parsed.ranges.length!==1||parsed.ranges[0].start!==0||parsed.ranges[0].name!==name)throw Error('Codex 插件恢复分组不匹配');
  }
  const current=fs.existsSync(file)?fs.readFileSync(file,'utf8'):'';pluginSections(current);
  // Rebuild the old cache from the restored program; no second program backup
  // is retained. remove/add are idempotent when recovery itself is interrupted.
  const run=args=>call(snapshot.codexPath,args,execute,snapshot.home);
  const catalog=run(['list','--marketplace',marketplace]);
  const installed=(catalog.installed??[]).filter(row=>row.pluginId===pluginId&&row.installed===true),markets=run(['marketplace','list']).marketplaces?.filter(row=>row.name===marketplace)??[];
  if(installed.length>1||installed.some(row=>!same(row.source?.path,snapshot.target)||![snapshot.previous?.version,snapshot.installVersion].includes(row.version))||markets.length>1||markets.some(row=>!same(row.root,snapshot.marketplaceRoot)))throw Error('Codex 插件注册已被其他操作更改，保留恢复记录');
  if((catalog.installed??[]).some(row=>row.pluginId===pluginId&&row.installed===true))run(['remove',pluginId]);
  if(snapshot.previous){
    run(['marketplace','add',snapshot.marketplaceRoot]);
    const added=run(['add',pluginId]);
    if(added.version!==snapshot.previous.version)throw Error('恢复后的 Codex 插件版本与原版本不一致');
  }else if(original.market===null){
    const markets=run(['marketplace','list']);
    if(markets.marketplaces?.some(row=>row.name===marketplace))run(['marketplace','remove',marketplace]);
  }
  editConfig(snapshot.home,text=>replacePluginSections(text,original));
  const restored=run(['list','--marketplace',marketplace]).installed?.filter(row=>row.pluginId===pluginId&&row.installed===true)??[];
  if(snapshot.previous?(restored.length!==1||restored[0].version!==snapshot.previous.version||restored[0].enabled!==snapshot.previous.enabled):restored.length!==0)throw Error('Codex 插件恢复后的状态对账未通过');
  return {ok:true,installed:!!snapshot.previous,enabled:snapshot.previous?.enabled??false,version:snapshot.previous?.version??null};
}
