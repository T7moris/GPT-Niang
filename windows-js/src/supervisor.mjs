import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { NativeWindows } from "./windows/native.mjs";
import { readJson, writeJson, guiEnvironment, samePath } from "./core/storage.mjs";
import { readPause, sessionPaused, shouldLaunch } from "./core/lifecycle.mjs";
import { acquireLock } from "./core/updater.mjs";
import { widgetUpdating } from "../runtime/refresh-client.mjs";
import { processIdentity } from "../runtime/process-identity.mjs";
import { pendingRecovery, ownerAlive } from "./core/update-transaction.mjs";
import { cleanupFinishedUpdate, cleanupFinishedInstall, cleanupFinishedMigration } from "./core/update-cleanup.mjs";
import {readInstallRecord,installFinished} from './core/install-recovery.mjs';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), ".."),
  config = readJson(path.join(root, "installation.json"));
if (!config?.dataDir || !samePath(config.appDir, root))
  throw Error("安装标识不匹配");
const dataDir = config.dataDir,
  lock = acquireLock(path.join(dataDir, "supervisor-lock"));
if (!lock) process.exit(0);
const native = new NativeWindows();
let pending = null,
  nextLaunch = 0,
  lastHosts = "",
  lastStatus = 0,
  nextCleanup = 0,
  stopped = false;
function tick() {
  try {
    if (["supervisor-disabled.flag", "supervisor-stop.flag"].some(name=>fs.existsSync(path.join(dataDir,name)))) {stop();return;}
    const installation=readInstallRecord(dataDir);
    if(installation&&!installFinished.has(installation.phase)){
      if(!ownerAlive(installation.ownerPid,installation.ownerStartedTicks)){
        if(installation.recovery&&Date.now()>=nextLaunch){
          nextLaunch=Date.now()+10000;const recovery=installation.recovery;
          const child=spawn(recovery.executable,[recovery.script,dataDir,installation.token],{cwd:dataDir,windowsHide:true,detached:true,stdio:'ignore',env:{...guiEnvironment(),ELECTRON_RUN_AS_NODE:'1'}});
          child.on('error',()=>{});child.unref();
        }
        return;
      }
      if(installation.phase!=='waiting-health'||config.installTransaction!==installation.token)return;
    }
    if(Date.now()>=nextCleanup){nextCleanup=Date.now()+10000;try{cleanupFinishedUpdate(dataDir,ownerAlive);cleanupFinishedInstall(dataDir,ownerAlive);cleanupFinishedMigration(dataDir,ownerAlive);}catch{}}
    const recovery=pendingRecovery(dataDir);
    if(recovery){
      if(Date.now()>=nextLaunch){nextLaunch=Date.now()+10000;const child=spawn(recovery.executable,[path.join(recovery.agent,"src","update-agent.mjs"),recovery.job,"--recover"],{cwd:recovery.agent,windowsHide:true,detached:true,stdio:"ignore",env:{...guiEnvironment(),ELECTRON_RUN_AS_NODE:"1"}});child.on("error",()=>{});child.unref();}
      return;
    }
    const hosts = native.hosts(),
      pauseFile = path.join(dataDir, "supervisor-pause.json"),
      pause = readPause(pauseFile),
      paused = sessionPaused(pause, hosts);
    if (pause && !paused) fs.unlinkSync(pauseFile);
    const key = hosts
      .filter((h) => h.visible)
      .map((h) => [h.handle, h.pid, h.started].join(":"))
      .sort()
      .join("|");
    if (key !== lastHosts) {
      nextLaunch = 0;
      lastHosts = key;
    }
    const runtime = readJson(path.join(dataDir, "runtime.json")),
      running =
        samePath(runtime?.appDir, root) &&
        runtime?.architecture === "javascript-electron" &&
        native.valid(runtime.widget) &&
        native.pid(runtime.widget) === runtime.pid &&
        String(native.identity(runtime.widget).started) ===
          String(runtime.processStartedTicks);
    if (pending && (running || pending.exitCode !== null)) pending = null;
    const settings = readJson(path.join(dataDir, "settings.json"));
    if (
      !widgetUpdating(dataDir) &&
      shouldLaunch({
        hosts,
        settings,
        pause,
        running,
        pending: !!pending,
        now: Date.now(),
        nextLaunch,
      })
    ) {
      nextLaunch = Date.now() + 10000;
      pending = spawn(config.electronPath, [root, "--installed"], {
        cwd: root,
        windowsHide: false,
        stdio: "ignore",
        env: guiEnvironment(),
      });
      pending.on("error", () => {
        pending = null;
      });
    }
    if (Date.now() - lastStatus >= 5000) {
      lastStatus = Date.now();
      writeJson(path.join(dataDir, "supervisor-status.json"), {
        pid: process.pid,
        processStartedTicks: processIdentity(process.pid)?.startedTicks,
        nodePath: process.execPath,
        appDir: root,
        version: config.version,
        at: new Date().toISOString(),
        mainWindows: hosts.length,
        visibleWindows: hosts.filter((h) => h.visible).length,
        paused,
        widgetRunning: !!running,
        taskName: config.taskName,
      });
    }
  } catch (error) {
    fs.writeFileSync(path.join(dataDir, "supervisor-error.txt"), error.stack);
  }
}
const timer = setInterval(tick, 1500);
function stop() {
  if (stopped) return;
  stopped = true;
  clearInterval(timer);
  if (pending) pending.unref();
  native.close();
  lock.release();
  if (
    readJson(path.join(dataDir, "supervisor-status.json"))?.pid === process.pid
  )
    try {
      fs.unlinkSync(path.join(dataDir, "supervisor-status.json"));
    } catch {}
}
process.on("SIGTERM", () => {
  stop();
  process.exit(0);
});
process.on("exit", stop);
tick();
