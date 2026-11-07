import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { randomUUID, createHash } from "node:crypto";
import { readJson, writeJson, inside } from "./core/storage.mjs";
import { resolveInstallCli } from "./core/cli.mjs";
import { safePackagePath } from "./core/archive.mjs";
import { installationHealthy, assertPluginRegistration } from "./core/installation-health.mjs";
import { cleanupFinishedInstall } from "./core/update-cleanup.mjs";
import { ownerAlive, renameWithRetry,terminalPhases } from "./core/update-transaction.mjs";
import { processIdentity } from "../runtime/process-identity.mjs";
import {readInstallRecord,writeInstallRecord,installFinished,claimInstall,prepareInstallRecovery,recoverInstall,snapshotFile,stopProgramOwners} from './core/install-recovery.mjs';
import {capturePluginRegistration,restorePluginRegistration,retainPluginPreference} from './core/plugin-registration.mjs';
import {resolveCodexHome,applyCodexHomeArgument} from '../runtime/codex-home.mjs';
import {stableInstallPaths} from './core/install-paths.mjs';
import {resolveLauncherBinding,resolveLegacyLauncherBinding} from './core/launcher-binding.mjs';
if(process.versions.electron)process.noAsar=true;
const source = path.resolve(path.dirname(fileURLToPath(import.meta.url)), ".."),
  args = process.argv.slice(2),
  option = (n) => {
    const i = args.indexOf(n);
    return i < 0 ? null : args[i + 1];
  },
  target = path.resolve(option("--target") ?? source);
const win = process.env.WINDIR ?? "C:\\Windows",
  wscript = path.join(win, "System32", "wscript.exe"),
  powershell = path.join(
    win,
    "System32",
    "WindowsPowerShell",
    "v1.0",
    "powershell.exe",
  ),
  launcher = path.join(target, "native", "GPTNiang.Start.exe");
const digest = (b) => createHash("sha256").update(b).digest("hex"),
  xmlEscape = (x) =>
    String(x)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;"),
  quote = (x) => '"' + x + '"',
  same = (a, b) =>
    String(a ?? "").toLowerCase() === String(b ?? "").toLowerCase();
function setup(op, ...values) {
  const r = spawnSync(
    path.join(source, "native", "GPTNiang.Setup.exe"),
    [op, ...values],
    { windowsHide: true },
  );
  if (r.error) throw r.error;
  const text = r.stdout
    .toString("utf8")
    .replace(/^\uFEFF/, "")
    .trim();
  let result;
  try {
    result = JSON.parse(text);
  } catch {
    throw Error("Windows 启动设置未返回有效结果");
  }
  if (!result.ok) throw Error(result.error);
  return result;
}
function assertDirectory(directory) {
  const full = path.resolve(directory);
  if (full === path.dirname(full)) throw Error("不能使用磁盘根目录");
  let p = full;
  while (p !== path.dirname(p)) {
    if (fs.existsSync(p) && fs.lstatSync(p).isSymbolicLink())
      throw Error("安装路径不能使用文件链接");
    p = path.dirname(p);
  }
  return full;
}
function identity() {
  const r = spawnSync("whoami.exe", ["/user", "/fo", "csv", "/nh"], {
    windowsHide: true,
  });
  if (r.error || r.status) throw Error("无法确认当前 Windows 用户");
  const sid = r.stdout.toString().match(/S-\d-(?:\d+-)+\d+/)?.[0];
  if (!sid) throw Error("无法读取当前用户标识");
  return sid;
}
export function validateTarget(root, config) {
  assertDirectory(root);
  const pkg = readJson(path.join(root, "package.json"));
  if (fs.existsSync(root) && (!pkg || pkg.name !== "gpt-niang-usage"))
    throw Error("目标目录不是 GPT 娘安装目录");
  if (config?.appDir && !same(path.resolve(config.appDir), root))
    throw Error("安装目录标识不匹配");
}
function taskXml(plan) {
  return (
    '<?xml version="1.0" encoding="UTF-16"?><Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><RegistrationInfo><Description>GPT Niang supervisor</Description></RegistrationInfo><Triggers><LogonTrigger><Enabled>true</Enabled><UserId>' +
    plan.sid +
    '</UserId></LogonTrigger></Triggers><Principals><Principal id="User"><UserId>' +
    plan.sid +
    '</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals><Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><StartWhenAvailable>true</StartWhenAvailable><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><RestartOnFailure><Interval>PT1M</Interval><Count>3</Count></RestartOnFailure></Settings><Actions Context="User"><Exec><Command>' +
    xmlEscape(plan.launcherPath??path.join(plan.target, "native", "GPTNiang.Start.exe")) +
    "</Command><Arguments>" +
    "--supervise" +
    "</Arguments><WorkingDirectory>" +
    xmlEscape(path.dirname(plan.launcherPath??path.join(plan.target,"native","GPTNiang.Start.exe"))) +
    "</WorkingDirectory></Exec></Actions></Task>"
  );
}
function writeXml(file, xml) {
  fs.writeFileSync(
    file,
    Buffer.concat([Buffer.from([255, 254]), Buffer.from(xml, "utf16le")]),
  );
}
export function preflight() {
  applyCodexHomeArgument(args);
  if (process.platform !== "win32") throw Error("此安装包用于 Windows");
  assertDirectory(source);
  assertDirectory(target);
  const previous = readJson(path.join(target, "installation.json"));
  validateTarget(target, previous);
  const dataDir = assertDirectory(
    option("--data-dir") ??
      previous?.dataDir ??
      stableInstallPaths().dataDir,
  );
  if (
    same(dataDir, target) ||
    dataDir.toLowerCase().startsWith(target.toLowerCase() + path.sep) ||
    target.toLowerCase().startsWith(dataDir.toLowerCase() + path.sep)
  )
    throw Error("个人数据目录必须放在程序目录之外");
  const sid = identity(),
    taskName = "GPT Niang Usage - " + sid,
    task = setup("task-info", taskName),
    shortcut =
      previous?.startupShortcut ??
      path.join(
        process.env.APPDATA,
        "Microsoft",
        "Windows",
        "Start Menu",
        "Programs",
        "Startup",
        "GPT Niang Usage.lnk",
      ),
    link = setup("shortcut-info", shortcut),
    legacyAgent = previous?.updateAgent;
  const legacyArguments = legacyAgent
    ? "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File " +
      quote(path.join(legacyAgent, "update-agent.ps1")) +
      " -Supervisor"
    : null;
  const accepted = [
    quote(path.join(target, "supervisor.vbs")),
    ...(legacyAgent
      ? [quote(path.join(legacyAgent, "agent-supervisor.vbs"))]
      : []),
  ];
  const launcherPath=path.join(dataDir,"launcher","GPTNiang.Start.exe"),bindingFile=path.join(dataDir,'launcher','launcher.json');
  if (
    task.exists &&
    (!(
      ([launcher,launcherPath].some(p=>same(task.command,p)) && same(task.arguments, "--supervise")) ||
      (legacyArguments &&
        same(task.command, powershell) &&
        same(task.arguments, legacyArguments)) ||
      (same(task.command, wscript) &&
        accepted.some((a) => same(task.arguments, a)))
    ) ||
      task.actions !== 1 ||
      task.level !== 0 ||
      task.logon !== 3 ||
      !same(task.sid ?? task.user, sid))
  )
    throw Error("已有启动任务属于其他安装，已停止检查");
  let repairLegacyBinding=false;
  if (
    legacyAgent &&
    task.exists &&
    (same(
      task.arguments,
      quote(path.join(legacyAgent, "agent-supervisor.vbs")),
    ) ||
      same(task.arguments, legacyArguments))
  ) {
    const file=path.join(legacyAgent,'binding.json');
    repairLegacyBinding=resolveLegacyLauncherBinding({exists:fs.existsSync(file),binding:readJson(file),previous,target,dataDir,sid,agent:legacyAgent,task}).recovered;
  }
  const linkArguments = [
    quote(path.join(target, "launch.vbs")),
    ...(legacyAgent ? [quote(path.join(legacyAgent, "agent-launch.vbs"))] : []),
  ];
  if (
    link.exists &&
    !(
      ([launcher,launcherPath].some(p=>same(link.target,p)) && !link.arguments) ||
      (legacyArguments &&
        same(link.target, powershell) &&
        same(link.arguments, legacyArguments)) ||
      (same(link.target, wscript) &&
        linkArguments.some((a) => same(link.arguments, a)))
    )
  )
    throw Error("现有启动快捷方式不属于该安装");
  const launcherBinding=(same(task.command,launcherPath)||same(link.target,launcherPath))?
    resolveLauncherBinding({exists:fs.existsSync(bindingFile),binding:readJson(bindingFile),previous,target,dataDir,sid,launcherPath,task,link}):null;
  const pkg = readJson(path.join(source, "package.json"));
  if (pkg?.architecture !== "javascript-electron")
    throw Error("源程序架构不匹配");
  const integrity = readJson(path.join(source, "integrity.json"));
  if (!integrity?.files) throw Error("请先生成带校验清单的完整安装包");
  for (const [name, hash] of Object.entries(integrity.files)) {
    safePackagePath(name);
    if (digest(fs.readFileSync(inside(source, name))) !== hash)
      throw Error("程序文件校验失败：" + name);
  }
  const electronPath = path.join(
      target,
      "node_modules",
      "electron",
      "dist",
      "electron.exe",
    ),
    nodePath =
      previous?.nodePath && (()=>{try{return fs.statSync(previous.nodePath).isFile();}catch{return false;}})()
        ? previous.nodePath
        : electronPath,
    codexPath = resolveInstallCli(previous?.codexPath),
    marketplaceRoot = previous?.marketplaceRoot ?? path.dirname(target);
  if (!codexPath || !fs.existsSync(codexPath))
    throw Error("未找到 Codex 桌面程序");
  const transaction = legacyAgent
    ? readJson(path.join(legacyAgent, "update-transaction.json"))
    : null;
  if (transaction && !["committed", "rolled-back"].includes(transaction.phase))
    throw Error("旧版本有未完成更新，请先完成恢复");
  return {
    target,
    dataDir,
    sid,
    taskName,
    shortcut,
    launcherPath,
    electronPath,
    nodePath,
    codexPath,
    codexHome:resolveCodexHome(option('--codex-home')??previous?.codexHome),
    marketplaceRoot,
    version: pkg.version,
    integrity,
    previous,
    repairLauncherBinding:launcherBinding?.recovered===true,
    repairLegacyBinding,
    task,
    link,
  };
}
export async function stopOwned(plan) {
  await stopProgramOwners({root:plan.target,dataDir:plan.dataDir,stopTask:()=>{if(plan.task.exists)setup('task-stop',plan.taskName);}});
}
export async function verifyStarted(plan, {timeoutMs=25000, inspect, now=Date.now}={}) {
  const deadline=now()+timeoutMs;
  do {
    const runtime = readJson(path.join(plan.dataDir, "runtime.json"));
    const supervisor = readJson(
      path.join(plan.dataDir, "supervisor-status.json"),
    );
    if(installationHealthy({root:plan.target,version:plan.version,runtime,supervisor,settings:readJson(path.join(plan.dataDir,'settings.json')),startedAt:plan.startRequestedAt??0,now:now(),inspect,nodePath:plan.electronPath,electronPath:plan.electronPath,requireSupervisor:true}))return;
    await new Promise((r) => setTimeout(r, 100));
  }while(now()<deadline);
  throw Error("新程序没有通过启动检查");
}
export async function install(
  plan,
  {
    fileSource = source,
    windows = setup,
    execute = spawnSync,
    stop = stopOwned,
    verify = verifyStarted,
    phaseHook = () => {},
    beforeStop = () => {},
    migration = null,
    capturePlugin = capturePluginRegistration,
    restorePlugin = restorePluginRegistration,
  } = {},
) {
  assertDirectory(plan.target);assertDirectory(plan.dataDir);
  if(same(plan.target,plan.dataDir)||plan.dataDir.toLowerCase().startsWith(plan.target.toLowerCase()+path.sep)||plan.target.toLowerCase().startsWith(plan.dataDir.toLowerCase()+path.sep))throw Error('个人数据目录必须放在程序目录之外');
  if(!cleanupFinishedInstall(plan.dataDir,ownerAlive))throw Error('上次安装助手尚未退出，请稍后重试');
  const unfinished=readInstallRecord(plan.dataDir);
  if(unfinished&&!installFinished.has(unfinished.phase))throw Error('上次安装尚未恢复，请通过启动入口完成恢复后重试');
  const assertNoPendingUpdate=()=>{
    const file=path.join(plan.dataDir,'javascript-update-journal.json'),pending=readJson(file);
    if(fs.existsSync(file)&&(!pending||!terminalPhases.has(pending.phase)))throw Error('现用版本的更新或恢复尚未完成，请稍后重试');
  };
  assertNoPendingUpdate();
  const token=randomUUID(),transaction = path.join(plan.dataDir, "install-js-" + token);
  plan.launcherPath??=path.join(plan.dataDir,"launcher","GPTNiang.Start.exe");
  const stage = plan.target + ".stage-" + token,
    backup = plan.target + ".rollback-" + token,
    market = path.join(
      plan.marketplaceRoot,
      ".agents",
      "plugins",
      "marketplace.json",
    ),
    oldMarket = fs.existsSync(market) ? fs.readFileSync(market) : null,
    oldShortcut = fs.existsSync(plan.shortcut)
      ? fs.readFileSync(plan.shortcut)
      : null;
  const flagNames = [
      "stop.flag",
      "supervisor-stop.flag",
      "supervisor-disabled.flag",
      "supervisor-pause.json",
    ],
    oldFlags = new Map(
      flagNames.map((name) => {
        const file = path.join(plan.dataDir, name);
        return [name, fs.existsSync(file) ? fs.readFileSync(file) : null];
      }),
    );
  const bootstrapFiles=[plan.launcherPath,path.join(path.dirname(plan.launcherPath),"launcher.json"),path.join(path.dirname(plan.launcherPath),"launcher.json.bak"),...(plan.repairLegacyBinding?[path.join(plan.previous.updateAgent,'binding.json')]:[])];
  const oldBootstrap=new Map(bootstrapFiles.map(file=>[file,fs.existsSync(file)?fs.readFileSync(file):null]));
  const bootstrapOriginal=new Map(oldBootstrap);
  if(plan.repairLauncherBinding){
    // A failed upgrade must also restore a usable old launcher, rather than
    // reintroducing the absent binding that preflight has safely reconstructed.
    oldBootstrap.set(path.join(path.dirname(plan.launcherPath),'launcher.json'),Buffer.from(JSON.stringify({appDir:plan.target,dataDir:plan.dataDir,sid:plan.sid},null,2)+'\n'));
  }
  if(plan.repairLegacyBinding)oldBootstrap.set(path.join(plan.previous.updateAgent,'binding.json'),Buffer.from(JSON.stringify({appDir:plan.target,dataDir:plan.dataDir,sid:plan.sid},null,2)+'\n'));
  const priorMarket = oldMarket
    ? JSON.parse(oldMarket.toString("utf8").replace(/^\uFEFF/, ""))
    : null;
  if (priorMarket && priorMarket.name !== "gpt-niang-local")
    throw Error("现有插件市场不属于 GPT 娘");
  if (same(fileSource, plan.target))
    throw Error("请从独立候选包安装到现用目录，以保留完整回退副本");
  const release=claimInstall(plan.dataDir);if(!release)throw Error('另一个安装或恢复仍在进行');
  const detachedRunning=['runtime.json','supervisor-status.json'].some(name=>{
    const owner=readJson(path.join(plan.dataDir,name));
    if(owner?.appDir)return same(owner.appDir,plan.target)&&ownerAlive(owner.pid,owner.processStartedTicks??owner.startedTicks);
    // Released PowerShell versions did not write appDir or creation ticks.
    // Accept their exact creation time only inside the bound old data directory.
    if(!same(plan.previous?.appDir,plan.target)||plan.previous?.architecture==='javascript-electron')return false;
    const identity=processIdentity(owner?.pid),started=Date.parse(owner?.processStartedAt);
    return !!(identity&&Number.isFinite(started)&&identity.startedAt===started);
  });
  let record={schema:1,token,root:plan.target,dataDir:plan.dataDir,transaction,stage,backup,source:path.resolve(fileSource),hadTarget:fs.existsSync(plan.target),migration,resumeTask:plan.task.exists&&(plan.task.state===4||detachedRunning),
    plan:{...Object.fromEntries(['target','dataDir','launcherPath','taskName','sid','shortcut','marketplaceRoot','nodePath','codexPath','task'].map(name=>[name,plan[name]])),...(plan.repairLegacyBinding?{legacyBindingPath:path.join(plan.previous.updateAgent,'binding.json')}:{})},
    snapshots:{market:oldMarket?.toString('base64')??null,marketBackup:snapshotFile(market+'.bak'),shortcut:oldShortcut?.toString('base64')??null,
      flags:Object.fromEntries([...oldFlags].map(([name,value])=>[name,value?.toString('base64')??null])),bootstrap:[...oldBootstrap].map(([file,value])=>[file,value?.toString('base64')??null]),
      identity:Object.fromEntries(['package.json','installation.json'].map(name=>[name,snapshotFile(path.join(plan.target,name))]))}};
  const phase=async(value,extra={})=>{
    const next={...record,...extra,phase:value,ownerPid:process.pid,ownerStartedTicks:processIdentity(process.pid)?.startedTicks,at:Date.now()};
    writeInstallRecord(next);record=next;await phaseHook(value,record);
  };
  try {
    assertNoPendingUpdate();
    await phase('staging');
    fs.mkdirSync(transaction);
    fs.mkdirSync(stage);
    for (const name of [
      ...Object.keys(plan.integrity.files),
      "integrity.json",
    ]) {
      const out = inside(stage, name);
      fs.mkdirSync(path.dirname(out), { recursive: true });
      fs.copyFileSync(inside(fileSource, name), out);
      if (
        plan.integrity.files[name] &&
        digest(fs.readFileSync(out)) !== plan.integrity.files[name]
      )
        throw Error("复制期间程序文件发生变化：" + name);
    }
    const config = {
      ...(plan.previous ?? {}),
      appDir: plan.target,
      dataDir: plan.dataDir,
      version: plan.version,
      architecture: "javascript-electron",
      electronPath: plan.electronPath,
      nodePath: plan.nodePath,
      codexPath: plan.codexPath,
      codexHome:resolveCodexHome(plan.codexHome??plan.previous?.codexHome),
      startupShortcut: plan.shortcut,
      launcherPath: plan.launcherPath,
      marketplaceRoot: plan.marketplaceRoot,
      taskName: plan.taskName,
      sid: plan.sid,
      installedAt: new Date().toISOString(),
      installTransaction:token,
    };
    delete config.updateAgent;
    delete config.candidate;
    writeJson(path.join(stage, "installation.json"), config);
    await beforeStop(plan);
    const pluginSnapshot=capturePlugin(plan,{execute});
    const currentTask=windows('task-info',plan.taskName);
    if(currentTask&&Boolean(currentTask.exists)!==Boolean(plan.task.exists)||currentTask?.exists&&(!same(currentTask.command,plan.task.command)||currentTask.arguments!==plan.task.arguments||currentTask.sid!==plan.task.sid))throw Error('启动任务在安装准备期间发生变化，现用版本保留');
    if(snapshotFile(plan.shortcut)!==(oldShortcut?.toString('base64')??null))throw Error('启动快捷方式在安装准备期间发生变化，现用版本保留');
    record.recovery=prepareInstallRecovery(record,source);
    for(const [file,value]of bootstrapOriginal)if(snapshotFile(file)!==(value?.toString('base64')??null))throw Error('启动器在安装准备期间发生变化，现用版本保留');
    // A waiting GUI supervisor host holds its executable open on Windows.
    // Older JS launchers already understand this durable recovery journal.
    const stopBeforeLauncher=plan.previous?.architecture==='javascript-electron';
    if(stopBeforeLauncher){await phase('stopping',{systemTouched:true,pluginSnapshot});await stop(plan);}
    await phase('arming-launcher',{bootstrapTouched:true,pluginSnapshot});
    fs.mkdirSync(path.dirname(plan.launcherPath),{recursive:true});
    writeJson(path.join(path.dirname(plan.launcherPath),"launcher.json"),{appDir:plan.target,dataDir:plan.dataDir,sid:plan.sid});
    await renameWithRetry(path.join(stage,"native","GPTNiang.Start.exe"),plan.launcherPath,{rename:fs.copyFileSync});
    const taskFile=path.join(transaction,'task.xml');writeXml(taskFile,taskXml(plan));
    await phase('arming-task',{taskTouched:true});
    windows('task-register',plan.taskName,taskFile,plan.sid);
    await phase('arming-shortcut',{shortcutTouched:true});
    windows('shortcut-write',plan.shortcut,plan.launcherPath,'',path.dirname(plan.launcherPath));
    if(!stopBeforeLauncher){await phase('stopping',{systemTouched:true});await stop(plan);}
    if (fs.existsSync(plan.target)) {
      await phase('moving-old');
      await renameWithRetry(plan.target, backup);
    }
    await phase('moving-new');
    await renameWithRetry(stage, plan.target);
    await phase('new-in-place');
    const plugins = (priorMarket?.plugins ?? []).filter(
      (p) => p.name !== "gpt-niang-usage",
    );
    plugins.push({
      name: "gpt-niang-usage",
      source: "./" + path.basename(plan.target),
    });
    const nextMarket = {
      ...(priorMarket ?? {}),
      name: "gpt-niang-local",
      plugins,
    };
    if(snapshotFile(market)!==(oldMarket?.toString('base64')??null))throw Error('插件市场文件在安装期间发生变化，保留外部修改');
    fs.mkdirSync(path.dirname(market), { recursive: true });
    await phase('writing-market',{marketWritten:digest(Buffer.from(JSON.stringify(nextMarket,null,2)+'\n'))});
    writeJson(market, nextMarket);
    await phase('registering-plugin',{pluginTouched:!!record.pluginSnapshot});
    for (const command of [
      ["plugin", "marketplace", "add", plan.marketplaceRoot, "--json"],
      ["plugin", "add", "gpt-niang-usage@gpt-niang-local", "--json"],
    ]) {
      const r = execute(plan.codexPath, command, {
        windowsHide: true,
        timeout: 60000,
        env:record.pluginSnapshot?{...process.env,CODEX_HOME:record.pluginSnapshot.home}:process.env,
      });
      if (r.error || r.status) throw Error("Codex 插件注册未完成");
    }
    retainPluginPreference(record.pluginSnapshot);
    assertPluginRegistration(execute(plan.codexPath,["plugin","list","--marketplace","gpt-niang-local","--json"],{windowsHide:true,timeout:30000,env:record.pluginSnapshot?{...process.env,CODEX_HOME:record.pluginSnapshot.home}:process.env}),plan.version,{enabled:record.pluginSnapshot?.previous?.enabled??true});
    for (const name of [
      "supervisor-stop.flag",
      "supervisor-disabled.flag",
      "supervisor-pause.json",
      "stop.flag",
    ])
      try {
        fs.unlinkSync(path.join(plan.dataDir, name));
      } catch (e) {
        if (e.code !== "ENOENT") throw e;
      }
    plan.startRequestedAt=Date.now();
    await phase('waiting-health',{startRequestedAt:plan.startRequestedAt});
    windows("task-start", plan.taskName);
    await verify(plan);
    await phase('committed');
    const cleanup={root:plan.target,dataDir:plan.dataDir,token,phase:'committed',ownerPid:process.pid,ownerStartedTicks:processIdentity(process.pid)?.startedTicks};
    writeJson(path.join(plan.dataDir,'javascript-install-cleanup.json'),cleanup,{backup:false});
    let cleanupPending=false;
    try{cleanupPending=!cleanupFinishedInstall(plan.dataDir,()=>false);}catch{cleanupPending=true;}
    const result={ok:true,backup:fs.existsSync(backup)?backup:null,dataDir:plan.dataDir,cleanupPending,at:Date.now()};
    try{writeJson(path.join(plan.dataDir,'javascript-install-result.json'),result,{backup:false});}
    catch(error){result.reportError=error.message;}
    return result;
  } catch (error) {
    if(record.phase==='committed')throw error;
    try {
      if(readInstallRecord(plan.dataDir)?.token===token)
        await recoverInstall(plan.dataDir,{token,windows,currentOwner:true,stop:()=>stop(plan),phaseHook,restorePlugin:snapshot=>restorePlugin(snapshot,{execute})});
    } catch (rollback) {
      error.message += "；恢复未完成：" + rollback.message;
    }
    writeJson(path.join(plan.dataDir, "javascript-install-result.json"), {
      ok: false,
      error: error.message,
      at: Date.now(),
    },{backup:false});
    throw error;
  }finally{release();}
}
async function main() {
  const plan = preflight();
  if (args.includes("--integrate"))
    console.log(JSON.stringify(await install(plan)));
  else if (args.includes("--disable") || args.includes("--uninstall")) {
    await stopOwned(plan);
    fs.writeFileSync(
      path.join(plan.dataDir, "supervisor-disabled.flag"),
      "disabled",
    );
    if (plan.task.exists) setup("task-delete", plan.taskName);
    if (plan.link.exists) fs.unlinkSync(plan.shortcut);
    if (args.includes("--uninstall")) {
      const r = spawnSync(
        plan.codexPath,
        ["plugin", "remove", "gpt-niang-usage@gpt-niang-local", "--json"],
        { windowsHide: true, timeout: 60000 },
      );
      if (r.error || r.status)
        throw Error("挂件已停止，Codex 插件移除尚未完成");
    }
    console.log(
      JSON.stringify({ ok: true, dataPreserved: true, dataDir: plan.dataDir }),
    );
  } else
    console.log(
      JSON.stringify({
        ok: true,
        checkOnly: true,
        source,
        target: plan.target,
        dataDir: plan.dataDir,
        version: plan.version,
        architecture: "javascript-electron",
        existingTask: plan.task.exists,
        existingShortcut: plan.link.exists,
        files: Object.keys(plan.integrity.files).length,
      }),
    );
}
if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
)
  main().catch((e) => {
    console.error(e.message);
    process.exitCode = 1;
  });
