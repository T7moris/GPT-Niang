import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { randomUUID, createHash } from "node:crypto";
import {
  DAY,
  RELEASE_API,
  download,
  selectRelease,
  verifyHash,
} from "./update-network.mjs";
import { readJson, writeJson, inside } from "./storage.mjs";
import { inspectJavaScriptPackage } from "./archive.mjs";
import { runUpdateIO } from "./update-io.mjs";
import { processIdentity } from "../../runtime/process-identity.mjs";
import { ownerAlive,claimProgramChange,terminalPhases } from "./update-transaction.mjs";
import { cleanupFinishedUpdate, removeTransactionDirectory } from "./update-cleanup.mjs";
export { inspectJavaScriptPackage } from "./archive.mjs";
const retryMessage = deadline =>
  "更新服务暂时限制请求，请约 " +
  Math.max(1, Math.ceil((deadline - Date.now()) / 60000)) +
  " 分钟后重试。";
export function acquireLock(dataDir) {
  const directory = path.join(dataDir, "javascript-update.lock"),
    token = randomUUID(),
    owner = path.join(directory, "owner.json");
  fs.mkdirSync(dataDir, { recursive: true });
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      fs.mkdirSync(directory);
      writeJson(owner, { pid: process.pid, startedTicks:processIdentity(process.pid)?.startedTicks, token }, { backup: false });
      return {
        token,
        release() {
          if (readJson(owner)?.token === token) {
            fs.unlinkSync(owner);
            fs.rmdirSync(directory);
          }
        },
      };
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      const previous = readJson(owner);
      if (previous?.pid) {
        if(ownerAlive(previous.pid,previous.startedTicks))return null;
      } else if (Date.now() - fs.statSync(directory).mtimeMs < 10000)
        return null;
      const stale = directory + ".stale-" + token;
      try {
        fs.renameSync(directory, stale);
      } catch {
        return null;
      }
      try{removeTransactionDirectory(dataDir,path.basename(stale));}catch{}
    }
  }
  return null;
}
export class Updater {
  constructor({
    root,
    dataDir,
    version,
    candidate,
    nodePath = process.execPath,
    onChange,
    onInstall,
    fetchBytes = download,
    launch = null,
    isIdle = () => true,
  }) {
    Object.assign(this, {
      root,
      dataDir,
      version,
      candidate,
      nodePath,
      onChange,
      onInstall,
      fetchBytes,
      launch,
      isIdle,
    });
    this.preferences = readJson(
      path.join(dataDir, "update-preferences.json"),
    ) ?? { automatic: true };
    this.state = readJson(
      path.join(dataDir, "javascript-update-state.json"),
    ) ?? {
      status: "idle",
      message: "尚未检查更新",
      nextCheckAt: Date.now() + 30000,
    };
    this.startedAt = Date.now();
    this.busy = false;
    this.reconcile(false);
  }
  reconcile(notify=true) {
    const journal=readJson(path.join(this.dataDir,"javascript-update-journal.json"));
    if(!this.busy&&this.state.status==="preparing"&&(!journal||journal.token!==this.state.transactionId)){
      this.state={...this.state,status:"error",message:"上次更新准备中断，原版本未改动。",nextCheckAt:Date.now()+DAY};
      writeJson(path.join(this.dataDir,"javascript-update-state.json"),this.state);
      if(notify)this.onChange?.();
      return;
    }
    const terminal=journal&&terminalPhases.has(journal.phase)&&journal.token===this.state.transactionId&&Number.isFinite(journal.at);
    const result=terminal?
      {ok:journal.phase==='committed',recovered:true,token:journal.token,root:journal.root,version:journal.phase==='committed'?journal.version:(journal.oldVersion??this.version),error:journal.error,at:journal.at}:readJson(path.join(this.dataDir,"javascript-update-result.json"));
    if(!result || typeof result.ok!=="boolean" || !Number.isFinite(result.at) || (!["installing","preparing"].includes(this.state.status)&&!(this.state.status==='error'&&this.state.recoveryPending)) || result.at<(this.state.installStartedAt??0) || result.at<=(this.state.lastResultAt??0) ||
       (this.state.transactionId && result.token!==this.state.transactionId) ||
       (result.root && path.resolve(result.root)!==path.resolve(this.root)))return;
    const recoveryPending=result.recovered===false||journal?.phase==='recovery-failed';
    this.state={...this.state,status:result.ok?"current":"error",recoveryPending,message:result.ok?"已更新至 "+result.version:(recoveryPending?"更新失败，恢复尚未完成：":"更新失败，已恢复原版本：")+result.error,lastResultAt:result.at,nextCheckAt:Date.now()+DAY};
    writeJson(path.join(this.dataDir,"javascript-update-state.json"),this.state);
    if(notify)this.onChange?.();
  }
  automatic(value) {
    const preferences = { ...this.preferences, automatic: value };
    writeJson(
      path.join(this.dataDir, "update-preferences.json"),
      preferences,
    );
    this.preferences = preferences;
    if (value) {
      this.state.nextCheckAt = 0;
      this.startedAt = 0;
    }
    this.changed();
  }
  changed() {
    writeJson(
      path.join(this.dataDir, "javascript-update-state.json"),
      this.state,
    );
    this.onChange?.();
  }
  reportBackgroundError(error) {
    this.state = {
      ...this.state,
      status: "error",
      message: error?.message ?? "更新暂时不可用，请稍后重试。",
      nextCheckAt: Date.now() + DAY,
    };
    try {
      this.changed();
    } catch {
      // An unavailable update-state file must not take down the widget.
      // Keep the error in memory so opening the menu still explains it.
      try { this.onChange?.(); } catch {}
    }
  }
  tick(idle) {
    try {
      this.reconcile();
      if (!idle || this.busy) return;
      if (this.state.status === "ready") {
        if (
          !this.candidate &&
          (this.state.mode !== "automatic" ||
            this.preferences.automatic !== false)
        )
          void this.install().catch(error => this.reportBackgroundError(error));
        return;
      }
      if (
        this.preferences.automatic !== false &&
        Date.now() >=
          Math.max(this.startedAt + 30000, this.state.nextCheckAt ?? 0)
      )
        void this.check("automatic").catch(error => this.reportBackgroundError(error));
    } catch (error) {
      this.reportBackgroundError(error);
    }
  }
  async check(mode = "manual") {
    this.reconcile();
    if(this.state.recoveryPending)return;
    if(this.busy || ["preparing","installing"].includes(this.state.status))return;
    if(this.state.status==="ready"){
      if(mode==="manual"){
        this.state={...this.state,mode:"manual",message:this.candidate?"更新包已校验，候选版不替换现用安装":"更新包已校验，等待空闲时安装"};
        this.changed();
      }
      return;
    }
    if (Date.now() < (this.state.retryAfterAt ?? 0)) {
      if (mode === "manual") {
        this.state = { ...this.state, message: retryMessage(this.state.retryAfterAt) };
        this.changed();
      }
      return;
    }
    if (mode === "automatic" && this.preferences.automatic === false) return;
    const lock = acquireLock(this.dataDir);
    if (!lock) return;
    this.busy = true;
    this.state = {
      ...this.state,
      status: "checking",
      message: "正在检查更新…",
    };
    try {
      this.changed();
      const release = JSON.parse(
          (
            await this.fetchBytes(RELEASE_API, {
              api: true,
              limit: 4 * 1024 * 1024,
            })
          ).toString("utf8"),
        ),
        selected = selectRelease(release, this.version);
      if (!selected) {
        this.state = {
          ...this.state,
          status: "current",
          message: "当前已是最新版本",
          nextCheckAt: Date.now() + DAY,
        };
        return;
      }
      this.state = {
        ...this.state,
        status: "downloading",
        message: `正在下载 ${selected.version}…`,
      };
      this.changed();
      const [bytes, sums] = await Promise.all([
        this.fetchBytes(selected.zip.browser_download_url, {
          limit: 1024 ** 3,
        }),
        this.fetchBytes(selected.sums.browser_download_url, {
          limit: 1024 ** 2,
        }),
      ]);
      const {hash,directory}=await runUpdateIO({kind:"stage",bytes,sums,asset:selected.zip,version:selected.version,dataDir:this.dataDir});
      this.state = {
        ...this.state,
        status: "ready",
        message: this.candidate
          ? "更新包已校验，候选版不替换现用安装"
          : "更新包已校验，等待空闲时安装",
        mode,
        version: selected.version,
        hash,
        directory,
        nextCheckAt: Date.now() + DAY,
      };
    } catch (error) {
      this.state = {
        ...this.state,
        status: "error",
        message: error.retryAfterMs > 0
          ? retryMessage(Date.now() + error.retryAfterMs)
          : error.message,
        retryAfterAt: Date.now() + (error.retryAfterMs ?? 0),
        nextCheckAt: Date.now() + Math.max(DAY, error.retryAfterMs ?? 0),
      };
    } finally {
      this.busy = false;
      lock.release();
      this.changed();
    }
  }
  async install() {
    if (this.busy || this.candidate || this.state.status !== "ready" || !this.isIdle()) return;
    const lock = acquireLock(this.dataDir);
    if (!lock) return;
    let releaseProgram=()=>{};
    this.busy = true;
    try {
      const claimed=claimProgramChange(this.dataDir);
      if(!claimed)return;
      releaseProgram=claimed;
      const previousState={...this.state}, installStartedAt=Date.now();
      this.state={...this.state,status:"preparing",message:"正在准备更新…",transactionId:lock.token,installStartedAt};
      this.changed();
      for(const name of ['javascript-install-journal.json','javascript-update-journal.json']){
        const file=path.join(this.dataDir,name),pending=readJson(file);
        if(fs.existsSync(file)&&(!pending||!terminalPhases.has(pending.phase)))throw Error('上次安装、更新或恢复尚未完成');
      }
      if(!cleanupFinishedUpdate(this.dataDir,ownerAlive))throw Error('上次更新助手尚未退出，请稍后重试');
      const {agent,executable,job}=await runUpdateIO({kind:"prepare",root:this.root,dataDir:this.dataDir,directory:this.state.directory,version:this.state.version,hash:this.state.hash,token:lock.token,nodePath:this.nodePath,hostPath:process.execPath,parentPid:process.pid});
      if (
        (this.state.mode === "automatic" && this.preferences.automatic === false) || !this.isIdle()
      )
        {const journal=readJson(path.join(this.dataDir,"javascript-update-journal.json"));if(journal?.token===lock.token)writeJson(path.join(this.dataDir,"javascript-update-journal.json"),{...journal,phase:"rolled-back",ownerPid:0,keepSource:true},{backup:false});this.state=previousState;this.changed();return;}
      this.state={...this.state,status:"installing",message:"正在安装更新…"};
      this.changed();
      releaseProgram();releaseProgram=()=>{};
      if (this.launch) await this.launch({ executable, agent, job });
      else {
        const child = spawn(
          executable,
          [path.join(agent, "src", "update-agent.mjs"), job],
          {
            cwd: agent,
            detached: true,
            windowsHide: true,
            stdio: "ignore",
            env: { ...process.env, ELECTRON_RUN_AS_NODE: "1" },
          },
        );
        await new Promise((resolve, reject) => {
          child.once("spawn", resolve);
          child.once("error", reject);
        });
        writeJson(path.join(this.dataDir, "update-installing.json"), {
          pid: child.pid,
          startedTicks: processIdentity(child.pid)?.startedTicks,
          token: lock.token,
          at: Date.now(),
        });
        child.unref();
      }
      this.state = {
        ...this.state,
        status: "installing",
        message: "正在安装更新…",
        transactionId: lock.token,
        installStartedAt,
      };
      this.changed();
      this.onInstall?.();
    } catch (error) {
      const journalFile=path.join(this.dataDir,"javascript-update-journal.json"),journal=readJson(journalFile);
      if(journal?.token===lock.token&&journal.phase==="prepared")writeJson(journalFile,{...journal,phase:"rolled-back",ownerPid:0,error:error.message},{backup:false});
      this.state = {
        ...this.state,
        status: "error",
        message: error.message,
        nextCheckAt: Date.now() + DAY,
      };
      this.changed();
    } finally {
      this.busy = false;
      releaseProgram();
      lock.release();
    }
  }
}
