import { app, BrowserWindow, ipcMain, screen, dialog, Menu } from "electron";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { Worker } from "node:worker_threads";
import { SettingsStore, normalizeSettings } from "./core/settings.mjs";
import {
  QuoteStore,
  normalizeQuotes,
  AutoQuoteSchedule,
  parseQuoteLines,
} from "./core/quotes.mjs";
import { Characters } from "./core/characters.mjs";
import { AudioStore } from "./core/audio.mjs";
import { Scene } from "./core/scene.mjs";
import { Colors, palettes } from "./core/colors.mjs";
import { formatQuota } from "./core/quota.mjs";
import {
  layout,
  resizeAnchors,
  placement,
  dragPlacement,
  snapPlacement,
} from "./core/layout.mjs";
import { readJson, writeJson, samePath, resolveNodeHost } from "./core/storage.mjs";
import { NativeWindows } from "./windows/native.mjs";
import { WindowsBridge } from "./windows/bridge.mjs";
import { Updater } from "./core/updater.mjs";
import { OcclusionRecovery } from "./core/occlusion.mjs";
import { WorkerStarter } from "./core/worker-starter.mjs";
import { readRefreshRequest } from "../runtime/refresh-queue.mjs";
import {UsageService} from './core/usage-service.mjs';
import {parseAutoQuoteInterval,validAutoQuoteSeconds} from './core/auto-quote-interval.mjs';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), ".."),
  args = process.argv.slice(2),
  option = (name) => {
    const i = args.indexOf(name);
    return i < 0 ? null : args[i + 1];
  };
const savedConfiguration = readJson(
  option("--config") ?? path.join(root, "installation.json"),
);
const candidate =
    args.includes("--candidate") ||
    savedConfiguration?.candidate === true ||
    savedConfiguration?.architecture !== "javascript-electron" ||
    !samePath(savedConfiguration?.appDir, root),
  preview = args.includes("--preview"),
  verify = args.includes("--verify") || args.includes("--verify-suite"),
  verifySuite = candidate && args.includes("--verify-suite");
const candidateRoot = path.resolve(root, "..", "candidate");
const configuration =
  savedConfiguration ??
  (candidate
    ? readJson(
        path.resolve(root, "..", "baseline-1.3.5", "app", "installation.json"),
      )
    : null) ??
  {};
const dataDir = path.resolve(
  option("--data-dir") ??
    (candidate
      ? savedConfiguration?.candidate === true
        ? savedConfiguration.dataDir
        : path.join(candidateRoot, "state")
      : (configuration.dataDir ??
        path.join(process.env.LOCALAPPDATA, "GPTNiangUsage", "data"))),
);
fs.mkdirSync(dataDir, { recursive: true });
if (candidate && !fs.existsSync(path.join(dataDir, "settings.json"))) {
  const baseline = path.resolve(root, "..", "baseline-1.3.5", "user-config");
  if (fs.existsSync(baseline))
    for (const entry of fs.readdirSync(baseline, { withFileTypes: true })) {
      if (entry.isFile())
        fs.copyFileSync(
          path.join(baseline, entry.name),
          path.join(dataDir, entry.name),
        );
      else if (entry.isDirectory())
        fs.cpSync(
          path.join(baseline, entry.name),
          path.join(dataDir, entry.name),
          { recursive: true },
        );
    }
}
app.setPath("userData", path.join(dataDir, "electron-profile"));
app.setAppUserModelId(
  candidate ? "GPTNiangUsage.JavaScript.Candidate" : "GPTNiangUsage",
);
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  await app.whenReady();
  Menu.setApplicationMenu(null);
  await run();
}
async function run() {
  const config = {
    ...configuration,
    dataDir,
    codexPath: configuration.codexPath ?? "",
    nodePath: resolveNodeHost(root, configuration.nodePath),
  };
  const settingsStore = new SettingsStore(path.join(dataDir, "settings.json"));
  let settings = settingsStore.value;
  const quotes = new QuoteStore(dataDir, path.join(root, "assets")),
    characters = new Characters(root, dataDir),
    audio = new AudioStore(root, dataDir),
    native = new NativeWindows(),
    bridge = new WindowsBridge(root);
  const initialStop = readRefreshRequest(path.join(dataDir, "stop.flag"));
  let host = 0,
    ready = false,
    probeBusy = false,
    candidateReady = false,
    lastProbe = 0,
    desktopStarted = false,
    visible = false,
    blocked = false,
    sizePreview = false,
    drag = null,
    music = false,
    musicColor = false,
    musicOffset = null,
    musicStatus = null,
    temporary = null,
    completionPending = false,
    completionCount = 0,
    completionReceived = 0,
    completionAck = 0,
    monitor = null,
    quotaWorker = null,
    menu = null,
    menuPlacement = null,
    menuBounds = [],
    menuNativeShape = false,
    menuDismissTimer = null,
    dialogBusy = false,
    editorBusy = false,
    openingEditor = false,
    editor = null,
    lastImage = "",
    statusStamp = 0,
    status = null,
    displayToken = "",
    rendererReady = false,
    stopToken = initialStop,
    stopping = false,
    lastNormal = null,
    frame = null,
    metrics = { movementEvents: 0, positionChanges: 0 },
    lastRuntime = 0;
  const usageService=new UsageService({dataDir,codexHome:config.codexHome,onChange:()=>{
    if(editor&&!editor.isDestroyed()&&new URL(editor.webContents.getURL()||'about:blank').searchParams.get('kind')==='usage')editor.webContents.send('state',dialogState('usage'));
  }});
  let bench = null;
  if (candidate && args.includes("--bench")) {
    bench = new BrowserWindow({
      width: 1150,
      height: 800,
      title: "GPT 娘 · JavaScript 交互验证台",
      show: false,
      webPreferences: {
        preload: path.join(root, "src", "preload.cjs"),
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
        offscreen: candidate && args.includes('--hidden-test'),
      },
    });
    host = native.handle(bench);
    ready = true;
    candidateReady = true;
    desktopStarted = true;
    bench.on("closed", () => {
      bench = null;
      app.quit();
    });
  }
  const scene = new Scene({ settings, quote: () => quotes.next() }),
    schedule = new AutoQuoteSchedule(settings),
    colors = new Colors(
      settings,
      readJson(path.join(dataDir, "color-triggers.json"))?.quotes,
    );
  const colorEpoch = Date.now();
  let lastLampImage = "";
  const win = new BrowserWindow({
    width: 378,
    height: 378,
    transparent: true,
    backgroundColor: "#00000000",
    frame: false,
    resizable: false,
    hasShadow: false,
    skipTaskbar: true,
    focusable: false,
    show: false,
    alwaysOnTop: false,
    webPreferences: {
      preload: path.join(root, "src", "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      backgroundThrottling: false,
      offscreen: candidate && args.includes('--hidden-test'),
      autoplayPolicy: "no-user-gesture-required",
    },
  });
  const handle = native.handle(win);
  for (const surface of [win]) {
    surface.webContents.on('did-start-loading',()=>{rendererReady=false;});
    surface.webContents.on('render-process-gone',(_event,details)=>{
      rendererReady=false;
      if(stopping)return;
      fs.appendFileSync(path.join(dataDir,'renderer-errors.log'),'Renderer exited: '+details.reason+'\n');
      app.quit();
    });
    surface.webContents.on("console-message", (_event, ...details) => {
      const strings = details.map((v) =>
        typeof v === "object" ? JSON.stringify(v) : String(v),
      );
      if (strings.some((v) => /Error|error|CSP|violat/i.test(v)))
        fs.appendFileSync(
          path.join(dataDir, "renderer-errors.log"),
          strings.join(" ").slice(0, 1000) + "\n",
        );
    });
    surface.webContents.on("preload-error", (_event, _file, error) =>
      fs.appendFileSync(
        path.join(dataDir, "renderer-errors.log"),
        error.stack + "\n",
      ),
    );
  }
  native.noActivate(handle);
  win.setIgnoreMouseEvents(true, { forward: true });
  let hit = false,
    nativeShape = false,
    shapeDetails = null,
    shapeError = null;
  const recovery = new OcclusionRecovery(native, handle);
  function updateIdle(){return !stopping&&!blocked&&!dialogBusy&&!editorBusy&&!openingEditor&&!drag&&!music&&!temporary&&ioWorkers.size===0&&scene.collapsed;}
  const updater = new Updater({
    root,
    dataDir,
    version: app.getVersion(),
    candidate,
    nodePath: config.nodePath,
    isIdle:updateIdle,
    onChange: () => {
      send();
      if (menu && !menu.isDestroyed())
        menu.webContents.send("state", dialogState("menu"));
    },
    onInstall: () => {
      stopping = true;
      app.quit();
    },
  });
  const lamp = new BrowserWindow({
    width: 640,
    height: 480,
    transparent: true,
    backgroundColor: "#00000000",
    frame: false,
    resizable: false,
    hasShadow: false,
    skipTaskbar: true,
    focusable: false,
    show: false,
    webPreferences: {
      preload: path.join(root, "src", "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      backgroundThrottling: false,
    },
  });
  const lampHandle = native.handle(lamp);
  native.noActivate(lampHandle);
  lamp.setIgnoreMouseEvents(true);
  await lamp.loadFile(path.join(root, "ui", "lamp.html"));
  let activeImage,
    characterNotice = "";
  try {
    activeImage = await characters.display(settings.characterId);
  } catch {
    activeImage = await characters.display("gpt-dragon");
    characterNotice = "上次使用的图片无法读取，已恢复龙娘1。";
  }
  settings.characterId = activeImage.id;
  const galleryImages = new Map([[activeImage.id, activeImage]]),
    galleryRevisions = new Map(),
    ioWorkers = new Set();
  const imagePayload = () => activeImage;
  async function prepareGallery() {
    const rows=characters.list(),ids=new Set(rows.map(row=>row.id));
    for(const id of galleryImages.keys())if(!ids.has(id)){galleryImages.delete(id);galleryRevisions.delete(id);}
    for (const row of rows) {
      try {
        const revision=characters.revision(row);
        if(galleryRevisions.get(row.id)===revision&&galleryImages.get(row.id)?.url)continue;
        galleryImages.set(
          row.id,
          await characters.display(row, { thumbnail: true }),
        );
        galleryRevisions.set(row.id,revision);
      } catch {
        galleryImages.set(row.id, { unavailable: true, url: null });
      }
    }
  }
  function runIo(kind, value) {
    return new Promise((resolve, reject) => {
      let settled=false;
      const worker = new Worker(path.join(root, "src", "io-worker.mjs"), {
        workerData: { root, dataDir, kind, ...value },
        resourceLimits: { maxOldGenerationSizeMb: 192 },
      });
      ioWorkers.add(worker);
      const timer = setTimeout(() => {
        settled=true;
        worker.terminate();
        reject(Error("文件读取超时，请换一个文件。"));
      }, 15000);
      worker.once("message", (message) => {
        settled=true;
        clearTimeout(timer);
        ioWorkers.delete(worker);
        if (message?.ok===true) resolve(message.result);
        else reject(Error(message?.error??'文件处理未完成。'));
      });
      worker.once("error", (error) => {
        settled=true;
        clearTimeout(timer);
        ioWorkers.delete(worker);
        reject(error);
      });
      worker.once("exit", (code) => {
        clearTimeout(timer);
        ioWorkers.delete(worker);
        if (!settled) reject(Error("文件处理未完成。"));
      });
    });
  }
  const quoteLayouts = readJson(
    path.join(root, "assets", "quote-layouts.json"),
  );
  let audioPayload = audio.payload(),
    audioRevision = 0,
    sentAudioRevision = -1;
  function effectiveLayout() {
    const value = layout(settings),
      dpi =
        settings.followHost && !preview && host
          ? native.dpi(host)
          : native.dpi(handle);
    if (frame && (!settings.followHost || preview))
      value.display = Math.min(
        value.display,
        (frame.right - frame.left) / dpi / 378,
        (frame.bottom - frame.top) / dpi / 378,
      );
    value.size = 378 * value.display;
    return value;
  }
  function geometry() {
    return {
      layout: effectiveLayout(),
      frame: frame
        ? {
            width: frame.right - frame.left,
            height: frame.bottom - frame.top,
            left: frame.left,
            top: frame.top,
          }
        : null,
      normal: lastNormal,
      position: native.rect(handle),
      dpi: settings.followHost && host && !preview ? native.dpi(host) : native.dpi(handle),
    };
  }
  function snapshot(forceImage = false) {
    const image =
      forceImage || lastImage !== activeImage.id ? imagePayload() : null;
    if (image) lastImage = activeImage.id;
    const sendAudio = forceImage || sentAudioRevision !== audioRevision;
    if (sendAudio) sentAudioRevision = audioRevision;
    return {
      settings: {
        ...settings,
        followHost: preview ? false : settings.followHost,
      },
      scene: scene.snapshot(),
      quota: formatQuota(status, scene.resetTimeMode),
      ...geometry(),
      colors: colors.scene(scene),
      audio: sendAudio ? audioPayload : null,
      image,
      quoteLayouts: forceImage ? quoteLayouts : null,
      visible,
      music,
      musicColor,
      musicStatus,
      temporary: !!temporary,
      blocked,
      candidate,
    };
  }
  function sendGeometry() {
    if (!win.isDestroyed() && !win.webContents.isLoading())
      win.webContents.send("geometry", geometry());
  }
  function send() {
    if (!win.isDestroyed() && !win.webContents.isLoading())
      win.webContents.send("state", snapshot());
  }
  function save(patch) {
    const previous = { ...settings };
    settings = settingsStore.save(
      resizeAnchors(previous, {
        ...settings,
        ...patch,
        collapsed: scene.collapsed,
      }),
    );
    scene.settings = settings;
    schedule.configure(
      settings.autoQuoteEnabled,
      settings.autoQuoteIntervalSeconds,
    );
    colors.settings = settings;
    if (previous.followHost !== settings.followHost) {
      setMusic(false);
      if (!settings.followHost) {
        const r = native.rect(handle);
        if (settings.desktopLeft === null && r)
          settings = settingsStore.save({
            desktopLeft: r.left,
            desktopTop: r.top,
          });
        native.owner(handle, 0);
      } else native.band(handle, false);
    }
    if (!settings.taskCompletionBubble) stopMonitor();
    else startMonitor();
    sync();
    send();
    if (menu && !menu.isDestroyed())
      menu.webContents.send("state", dialogState("menu"));
  }
  function resetSchedule() {
    schedule.reset();
  }
  function setVisible(value) {
    if (value === visible) return;
    visible = value;
    if (value) {
      win.showInactive();
      if (!preview) refresh();
    } else {
      recovery.configure(host, false);
      win.hide();
      lamp.webContents.send("lamp", { mode: "hidden" });
      lamp.hide();
      if (menu) menu.close();
      resetSchedule();
    }
    send();
  }
  function frameForDesktop() {
    const r = native.rect(handle),
      point = r
        ? {
            x: r.left + (r.right - r.left) / 2,
            y: r.top + (r.bottom - r.top) / 2,
          }
        : screen.getPrimaryDisplay().bounds;
    const dip = screen.screenToDipPoint({
        x: Math.round(point.x),
        y: Math.round(point.y),
      }),
      display = screen.getDisplayNearestPoint(dip);
    const area = screen.dipToScreenRect(win, display.workArea);
    return {
      left: area.x,
      top: area.y,
      right: area.x + area.width,
      bottom: area.y + area.height,
    };
  }
  async function probe() {
    if (preview) {
      ready = true;
      desktopStarted = true;
      return;
    }
    if (!host || ready || probeBusy || Date.now() - lastProbe < 1000) return;
    probeBusy = true;
    lastProbe = Date.now();
    const checking = host,
      result = await bridge.probe(host);
    probeBusy = false;
    if (checking !== host) return;
    ready = result && candidateReady;
    candidateReady = result;
    if (ready) desktopStarted = true;
    sync();
  }
  function hostSelection() {
    if (preview || bench) return;
    const foreground = native.foreground(),
      next = native.isCodex(foreground)
        ? foreground
        : native.valid(host)
          ? host
          : native.findCodex();
    if (next !== host) {
      host = next;
      ready = false;
      candidateReady = false;
      lastProbe = 0;
      musicOffset = null;
      resetSchedule();
    }
    if (!host) host = native.findCodex();
  }
  function sync() {
    if (stopping || win.isDestroyed()) return;
    hostSelection();
    const follow = settings.followHost && !preview;
    if (follow) {
      frame = host ? native.frame(host) : null;
      if (
        !temporary &&
        (!host ||
          !native.visible(host) ||
          !ready ||
          !frame ||
          frame.right - frame.left < 64 * native.dpi(host) ||
          frame.bottom - frame.top < 64 * native.dpi(host))
      ) {
        setVisible(false);
        void probe();
        return;
      }
    } else {
      frame = frameForDesktop();
      if (!host || (ready && native.visible(host))) desktopStarted = true;
      if (!preview && !desktopStarted) {
        setVisible(false);
        void probe();
        return;
      }
    }
    if (!frame) return;
    const dpi = follow ? native.dpi(host) : native.dpi(handle),
      p = placement(frame, settings, dpi);
    lastNormal = p;
    if (!follow) {
      p.size = Math.round(effectiveLayout().size * dpi);
      p.x = settings.desktopLeft ?? frame.right - p.size - 24;
      p.y = settings.desktopTop ?? frame.bottom - p.size - 24;
      if (preview && !args.includes("--saved-position")) {
        p.x = Math.round(frame.left + (frame.right - frame.left - p.size) / 2);
        p.y = Math.round(frame.top + (frame.bottom - frame.top - p.size) / 2);
      }
      const limited = dragPlacement(
        frame,
        settings,
        p.x,
        p.y,
        dpi,
        settings.side === "left" ? frame.left : frame.right,
        effectiveLayout().display,
      );
      p.x = limited.x;
      p.y = limited.y;
    }
    if ((!drag || drag.music) && !temporary) {
      const x = music && musicOffset ? frame.left + musicOffset.x : p.x,
        y = music && musicOffset ? frame.top + musicOffset.y : p.y;
      if (native.move(handle, { x, y, width: p.size, height: p.size }))
        metrics.positionChanges++;
    }
    if (follow && !temporary) {
      const r = native.rect(handle),
        display = screen.getDisplayNearestPoint(
          screen.screenToDipPoint({
            x: Math.round((r.left + r.right) / 2),
            y: Math.round((r.top + r.bottom) / 2),
          }),
        ),
        area = screen.dipToScreenRect(win, display.workArea);
      native.clip(handle, {
        left: Math.max(frame.left, area.x),
        top: Math.max(frame.top, area.y),
        right: Math.min(frame.right, area.x + area.width),
        bottom: Math.min(frame.bottom, area.y + area.height),
      });
    } else native.clip(handle, null);
    if (!temporary) {
      if (follow) native.above(handle, host, music ? lampHandle : 0);
      else {
        native.owner(handle, 0);
        native.desktopBand(handle, settings.desktopTopmost);
      }
    }
    recovery.configure(
      host,
      follow && ready && !temporary && !drag && !blocked && visible,
    );
    setVisible(true);
    const color = colors.scene(scene),
      halo = !music && color.scope === "full";
    if ((music || halo) && !temporary) {
      const width = frame.right - frame.left,
        height = frame.bottom - frame.top;
      native.move(lampHandle, { x: frame.left, y: frame.top, width, height });
      if (follow) native.above(lampHandle, host);
      else {
        native.owner(lampHandle, 0);
        native.desktopBand(lampHandle, settings.desktopTopmost);
      }
      lamp.showInactive();
      if (follow) native.above(handle, host, lampHandle);
      if (Date.now() - (sync.lastLamp ?? 0) >= 1000 / 30) {
        sync.lastLamp = Date.now();
        lamp.webContents.send("lamp", {
          mode: music ? "music" : "halo",
          frame: { width: width / dpi, height: height / dpi },
          dpi,
          top: follow ? 52 : 4,
          figure: 208 * settings.scale,
          motion: musicStatus?.motion,
          figureGeometry: musicStatus?.figure,
          artTime: musicStatus?.artTime ?? 0,
          palette: palettes.rainbow,
          ...(halo
            ? {
                palette: color.palette,
                paused: color.paused,
                epoch: colorEpoch,
                display: effectiveLayout().display,
                part: shapeDetails?.girl,
                windowOffset: {
                  x: native.rect(handle).left - frame.left,
                  y: native.rect(handle).top - frame.top,
                },
                image: lastLampImage !== activeImage.id ? activeImage : null,
              }
            : {}),
        });
        if (halo) lastLampImage = activeImage.id;
      }
    } else {
      if (lamp.isVisible()) lamp.webContents.send("lamp", { mode: "hidden" });
      lamp.hide();
    }
  }
  function setMusic(value) {
    if (value && !visible) throw Error("请先显示挂件再开启音乐律动。");
    bridge.capture(value === true);
    music = value === true;
    musicColor = false;
    musicOffset = null;
    musicStatus = null;
    if (music) scene.hide();
    else lamp.hide();
    sync();
    send();
    resetSchedule();
  }
  function refresh() {
    fs.writeFileSync(path.join(dataDir, "refresh.flag"), String(Date.now()));
    ensureWorker();
  }
  function spawnNode(file, arguments_ = []) {
    const bundled =
      config.nodePath === process.execPath ||
      /electron\.exe$/i.test(config.nodePath);
    return spawn(
      config.nodePath,
      [path.join(root, "runtime", file), ...arguments_],
      {
        cwd: root,
        windowsHide: true,
        env: {
          ...process.env,
          ...(bundled ? { ELECTRON_RUN_AS_NODE: "1" } : {}),
          ...(config.codexHome ? { CODEX_HOME: config.codexHome } : {}),
        },
        stdio: ["pipe", "pipe", "pipe"],
      },
    );
  }
  const configPath = path.join(dataDir, "javascript-installation.json");
  writeJson(configPath, { ...config, appDir: root });
  const workerStarter = new WorkerStarter({ dataDir, launch: () => {
    quotaWorker = spawnNode("watch.mjs", [configPath, String(process.pid), "--inherit-stop"]);
    quotaWorker.on("error", (e) => {
      status = { ok: false, queryOk: false, error: e.message };
      send();
    });
    quotaWorker.stderr.on("data", () => {});
    return quotaWorker;
  } });
  function ensureWorker() {
    if (preview || verify || (candidate && !args.includes("--live-quota")))
      return;
    workerStarter.ensure();
  }
  function startMonitor() {
    if (
      !settings.taskCompletionBubble ||
      preview ||
      verify ||
      (monitor && monitor.exitCode === null)
    )
      return;
    monitor = spawnNode("completion-monitor.mjs", [
      path.join(dataDir, "completion-monitor-state.json"),
    ]);
    let buffer = "";
    monitor.stdout.on("data", (bytes) => {
      buffer += bytes.toString();
      const lines = buffer.split("\n");
      buffer = lines.pop();
      if (buffer.length > 4096) buffer = "";
      for (const line of lines) {
        if (line.length > 2048) continue;
        try {
          const event = JSON.parse(line);
          if (
            event.type === "completion" &&
            typeof event.sessionId === "string" &&
            event.sessionId &&
            typeof event.turnId === "string" &&
            event.turnId &&
            event.endedAt >= completionAck
          ) {
            completionPending = true;
            completionReceived++;
          }
        } catch {}
      }
    });
    monitor.on("error", () => {});
    monitor.stderr.on("data", () => {});
  }
  function stopMonitor() {
    if (monitor) {
      monitor.stdin.end();
      monitor = null;
    }
    dismissCompletion();
    completionPending = false;
    if(scene.mode==='completion'&&!scene.collapsed)scene.hide();
  }
  function dismissCompletion() {
    completionAck = Date.now();
    completionPending = false;
    if (temporary) {
      const previous = temporary;
      temporary = null;
      if (previous.position) native.move(handle, previous.position);
      win.setIgnoreMouseEvents(!nativeShape, { forward: true });
      hit = false;
      if (!previous.visible) {
        win.hide();
        visible = false;
      }
      native.restoreLayer(handle, previous);
      sync();
    }
    resetSchedule();
  }
  function completionTick() {
    if (!settings.taskCompletionBubble) return;
    const active = host && native.foreground() === host;
    if (temporary) {
      if (
        active ||
        Date.now() >= temporary.expiresAt ||
        (scene.deadline > 0 && Date.now() >= scene.deadline) ||
        (temporary.fullscreen &&
          (native.foreground() !== temporary.foreground ||
            !fullscreen(temporary.foreground))) ||
        scene.collapsed ||
        blocked ||
        drag
      ) {
        dismissCompletion();
        if (!scene.collapsed) scene.hide();
      }
      return;
    }
    if (blocked || drag) {
      if (!scene.collapsed && scene.mode === "completion") scene.hide();
      return;
    }
    if (!scene.collapsed || !completionPending) return;
    if (active && !visible) return;
    if (!active) {
      recovery.configure(0, false);
      native.clip(handle, null);
      temporary = {
        ...native.layer(handle),
        visible,
        foreground: native.foreground(),
        fullscreen: fullscreen(native.foreground()),
        expiresAt: Date.now() + 7000,
      };
      const previousRect = native.rect(handle),
        area = frameForDesktop(),
        x = Math.max(
          area.left,
          Math.min(
            area.right - (previousRect.right - previousRect.left),
            previousRect.left,
          ),
        ),
        y = Math.max(
          area.top,
          Math.min(
            area.bottom - (previousRect.bottom - previousRect.top),
            previousRect.top,
          ),
        );
      if (x !== previousRect.left || y !== previousRect.top) {
        temporary.position = { x: previousRect.left, y: previousRect.top };
        native.move(handle, { x, y });
      }
      native.owner(handle, 0);
      win.setIgnoreMouseEvents(!nativeShape, {forward:true});
      hit = false;
      native.band(handle, true);
      win.showInactive();
    }
    scene.show("completion");
    completionCount++;
  }
  function fullscreen(h) {
    const r = native.rect(h);
    if (!r) return false;
    const display = screen.getDisplayNearestPoint(
        screen.screenToDipPoint({
          x: Math.round((r.left + r.right) / 2),
          y: Math.round((r.top + r.bottom) / 2),
        }),
      ),
      b = screen.dipToScreenRect(win, display.bounds);
    return (
      r.left <= b.x &&
      r.top <= b.y &&
      r.right >= b.x + b.width &&
      r.bottom >= b.y + b.height
    );
  }
  let phaseTimer = null;
  scene.on("change", () => {
    resetSchedule();
    clearTimeout(phaseTimer);
    if (
      scene.mode === "quota" &&
      !scene.collapsed &&
      scene.resetTimeMode === "countdown" &&
      !sizePreview
    )
      phaseTimer = setTimeout(
        () => scene.tick(),
        Math.max(1, scene.startedAt + 2000 - Date.now()),
      );
    if (scene.collapsed && scene.mode === "completion") dismissCompletion();
    if (!settingsStore.loadFailed) {
      try {
        settingsStore.save({ collapsed: scene.collapsed });
      } catch (error) {
        // Bubble visibility is transient. A locked/full settings volume must
        // not turn a display timer into an uncaught error and restart loop.
        try {
          fs.appendFileSync(path.join(dataDir, "startup.log"),
            Date.now() + " scene settings save failed: " + String(error?.message ?? error) + "\n");
        } catch {}
      }
    }
    send();
    if (menu && !menu.isDestroyed())
      menu.webContents.send("state", dialogState("menu"));
  });
  scene.on("refresh", refresh);
  let verificationSection = null;
  function dialogState(kind) {
    if(kind==='usage')return {kind,usage:usageService.value};
    if (kind === "quotes")
      return {
        kind,
        ...quotes.list(),
        lines: quotes
          .list()
          .quotes.map((q) =>
            q.weight === 1 ? q.text : `${q.weight} | ${q.text}`,
          )
          .join("\n"),
      };
    if (kind === "characters")
      return {
        kind,
        busy:editorBusy,
        selected: settings.characterId,
        notice: characterNotice,
        characters: characters.list().map((row) => ({
          ...row,
          ...galleryImages.get(row.id),
        })),
        removed: characters.removed().map(({ path, ...row }) => row),
      };
    if (kind === "colors") return { kind, lines: colors.triggers.join("\n") };
    if (kind === "audio")
      return { kind, settings, audio: audioPayload.preferences, busy:editorBusy };
    return {
      kind: "menu",
      settings,
      scene: scene.snapshot(),
      music,
      audio: audio.preferences,
      verificationSection,
      update: { ...updater.state, ...updater.preferences },
      placement: menuPlacement,
      version: app.getVersion(),
    };
  }
  function unblock() {
    blocked = !!menu || !!editor || openingEditor;
    resetSchedule();
    send();
  }
  async function openMenu() {
    if (menu && !menu.isDestroyed()) {
      menu.show();
      return;
    }
    blocked = true;
    resetSchedule();
    const r = native.rect(handle),
      l = effectiveLayout(),
      dpi = native.dpi(handle),
      button = l.menu;
    const anchor = screen.screenToDipPoint({
      x: Math.round(
        r.left +
          (14 +
            (l.mirror < 0 ? 350 - button.left - button.width : button.left)) *
            l.display *
            dpi,
      ),
      y: Math.round(r.top + (14 + button.top) * l.display * dpi),
    });
    const display = screen.getDisplayNearestPoint(anchor),
      work = display.workArea,
      hostArea =
        settings.followHost && frame
          ? screen.screenToDipRect(win, {
              x: frame.left,
              y: frame.top,
              width: frame.right - frame.left,
              height: frame.bottom - frame.top,
            })
          : work;
    const area = {
      x: Math.max(work.x, hostArea.x),
      y: Math.max(work.y, hostArea.y),
      right: Math.min(work.x + work.width, hostArea.x + hostArea.width),
      bottom: Math.min(work.y + work.height, hostArea.y + hostArea.height),
    };
    const width = Math.max(180, Math.min(956, area.right - area.x - 16)),
      height = Math.max(160, Math.min(730, area.bottom - area.y - 16)),
      rootWidth = Math.min(328, width),
      direction = settings.side === "left" ? "right" : "left";
    const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
    const mainX = clamp(
        direction === "right"
          ? anchor.x + button.width * l.display + 8
          : anchor.x - rootWidth - 8,
        area.x + 8,
        area.right - rootWidth - 8,
      ),
      x = clamp(
        direction === "right" ? mainX : mainX - width + rootWidth,
        area.x + 8,
        area.right - width - 8,
      ),
      y = area.y + 8;
    menuPlacement = {
      mainOffset: mainX - x,
      rootWidth,
      submenuWidth: Math.max(180, Math.min(300, width - rootWidth - 4)),
      maxHeight: height,
      anchorY: anchor.y - y,
      direction,
    };
    let menuClosing=false;
    menu = new BrowserWindow({
      width: Math.round(width),
      height: Math.round(height),
      x: Math.round(x),
      y: Math.round(y),
      frame: false,
      transparent: true,
      hasShadow: true,
      resizable: false,
      skipTaskbar: true,
      show: false,
      webPreferences: {
        preload: path.join(root, "src", "preload.cjs"),
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
        offscreen: candidate && args.includes('--hidden-test'),
      },
    });
    menu.on('close',()=>{menuClosing=true;});
    menu.on("closed", () => {
      native.releaseShape(menuPlacement.handle);
      menuNativeShape = false;
      clearInterval(menuDismissTimer);
      menuDismissTimer = null;
      menuBounds = [];
      menu = null;
      sizePreview = false;
      scene.preview = false;
      if (!scene.collapsed) scene.restart();
      unblock();
    });
    menuPlacement.handle = native.handle(menu);
    const openedMenu=menu;
    try{await openedMenu.loadFile(path.join(root, "ui", "panel.html"), {
      query: { kind: "menu" },
    });}catch(error){if(menuClosing||openedMenu.isDestroyed()||stopping)return;openedMenu.destroy();throw error;}
    if(openedMenu.isDestroyed()||menu!==openedMenu||stopping)return;
    if (verifySuite) menu.showInactive();
    else menu.show();
    menu.setIgnoreMouseEvents(!menuNativeShape, { forward: true });
    let previousMask = native.mouseMask();
    menuDismissTimer = setInterval(() => {
      if (!menu || menu.isDestroyed() || dialogBusy) return;
      const mask = native.mouseMask(),
        pressed = mask & ~previousMask;
      previousMask = mask;
      if (!pressed) return;
      const cursor = native.cursor(),
        rect = native.rect(native.handle(menu)),
        dpi = native.dpi(native.handle(menu));
      if (
        cursor &&
        rect &&
        menuBounds.length &&
        !menuBounds.some(
          (b) =>
            cursor.x >= rect.left + b.x * dpi &&
            cursor.x < rect.left + (b.x + b.width) * dpi &&
            cursor.y >= rect.top + b.y * dpi &&
            cursor.y < rect.top + (b.y + b.height) * dpi,
        )
      )
        menu.close();
    }, 16);
    menu.on("blur", () => {
      if (menu && !editor && !dialogBusy) menu.close();
    });
    send();
  }
  async function openEditor(kind) {
    if(openingEditor)return;
    if (editor && !editor.isDestroyed()) {
      if(menu)menu.close();
      editor.focus();
      return;
    }
    openingEditor=true;
    blocked = true;
    resetSchedule();
    send();
    let opened,editorClosing=false;
    try{
    if (kind === "characters") await prepareGallery();
    if(kind==='usage')usageService.start();
    if(stopping)return;
    editor = new BrowserWindow({
      width: kind === 'usage' ? 820 : kind === "characters" ? 610 : 540,
      height: kind === 'usage' ? 720 : kind === "characters" ? 560 : kind === "audio" ? 620 : 480,
      frame: kind !== "characters",
      resizable: kind !== "characters",
      minWidth: kind==='usage'?560:440,
      minHeight: 330,
      title:
        kind === "characters"
          ? "GPT 娘 · 形象图库"
          : kind === "quotes"
            ? "GPT 娘 · 我的语录"
            : kind === "audio"
              ? "GPT 娘 · 点击音效"
              : kind==='usage'?'GPT 娘 · 用量与记账':"GPT 娘 · 特殊台词",
      backgroundColor: "#FAF8FD",
      skipTaskbar: true,
      show: false,
      webPreferences: {
        preload: path.join(root, "src", "preload.cjs"),
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
        offscreen: candidate && args.includes('--hidden-test'),
      },
    });
    opened=editor;
    opened.on('close',()=>{editorClosing=true;});
    opened.on("closed", () => {
      if(editor===opened)editor = null;
      if(kind==='usage')usageService.close();
      unblock();
    });
    await opened.loadFile(path.join(root, "ui", "panel.html"), {
      query: { kind },
    });
    if(opened.isDestroyed()||editor!==opened||stopping)return;
    if(menu)menu.close();
    if (verifySuite) opened.showInactive();
    else opened.show();
    send();
    }catch(error){if(editorClosing||opened?.isDestroyed()||stopping)return;if(opened&&!opened.isDestroyed())opened.destroy();throw error;}
    finally{openingEditor=false;if(!editor){if(kind==='usage')usageService.close();unblock();}}
  }
  function widgetEvent(event) {
    return !stopping && !win.isDestroyed() && event.sender === win.webContents;
  }
  function trusted(event) {
    if (stopping) return false;
    return [win, lamp, menu, editor, bench].some(
      (w) => w && !w.isDestroyed() && w.webContents.id === event.sender.id,
    );
  }
  ipcMain.handle("initial", (event) => {
    if (!trusted(event)) throw Error("Unknown window");
    if (widgetEvent(event)) return snapshot(true);
    if (!lamp.isDestroyed() && event.sender.id === lamp.webContents.id) return {};
    if (bench && !bench.isDestroyed() && event.sender.id === bench.webContents.id)
      return { kind: "bench", candidate, architecture: "javascript-electron" };
    return dialogState(new URL(event.sender.getURL()).searchParams.get("kind"));
  });
  ipcMain.on("hit", (event, inside) => {
    if (!widgetEvent(event) || nativeShape)
      return;
    inside = inside === true;
    if (hit !== inside) {
      hit = inside;
      win.setIgnoreMouseEvents(!inside, { forward: true });
    }
  });
  ipcMain.on("shape", (event, value) => {
    if (!widgetEvent(event) || !value) return;
    try {
      if (native.updateShape(handle, value)) {
        shapeDetails = value.details;
        shapeError = null;
        if (!nativeShape) {
          nativeShape = true;
          win.setIgnoreMouseEvents(false);
        }
      }
    } catch (error) {
      shapeError = error.message;
    }
  });
  ipcMain.handle("pointer", (event) => {
    if (!widgetEvent(event)) return null;
    return { cursor: native.cursor(), rect: native.rect(handle) };
  });
  ipcMain.on("drag", (event, value) => {
    if (!widgetEvent(event) || !value || temporary) return;
    // Preserve the pointer location at the time of each event. Reading the
    // current cursor after IPC is delivered can collapse a quick drag into a
    // click because the cursor has already reached its destination.
    const cursor = Number.isFinite(value.x) && Number.isFinite(value.y)
      ? screen.dipToScreenPoint({ x: Math.round(value.x), y: Math.round(value.y) })
      : native.cursor();
    if (!cursor) return;
    if (value.op === "arm") {
      if (scene.mode === "completion") {
        dismissCompletion();
        scene.hide();
      }
      drag = { cursor, rect: native.rect(handle), moved: false, music };
      resetSchedule();
      if (music) {
        win.webContents.send('pointer-position',{id:value.id,cursor,start:true});
        musicColor =
          settings.colorMode !== "original" &&
          Math.random() < Math.min(100, 2 * settings.colorChance) / 100;
        send();
      }
    } else if(value.op==='move'&&drag&&music){
      win.webContents.send('pointer-position',{id:value.id,cursor});
    } else if (value.op === "move" && drag && !music) {
      const dx = cursor.x - drag.cursor.x,
        dy = cursor.y - drag.cursor.y;
      if (dx * dx + dy * dy < 9 && !drag.moved) return;
      drag.moved = true;
      let x = drag.rect.left + dx,
        y = drag.rect.top + dy;
      const follow = settings.followHost && !preview,
        dpi = follow ? native.dpi(host) : native.dpi(handle),
        nextSide = cursor.x < (frame.left + frame.right) / 2 ? "left" : "right";
      if (nextSide !== settings.side) {
        const g = layout(settings).girl,
          delta = (2 * g.left + g.width - 350) * layout(settings).display * dpi,
          shift = settings.side === "right" ? delta : -delta;
        x += shift;
        drag.rect.left += shift;
        settings = { ...settings, side: nextSide };
      }
      const next = dragPlacement(
        frame,
        settings,
        x,
        y,
        dpi,
        cursor.x,
        effectiveLayout().display,
      );
      if (follow) {
        const { x: unusedX, y: unusedY, ...placementSettings } = next;
        settings = { ...settings, ...placementSettings };
      } else
        settings = {
          ...settings,
          side: next.side,
          desktopLeft: next.x,
          desktopTop: next.y,
        };
      scene.settings = settings;
      colors.settings = settings;
      native.move(handle, { x: next.x, y: next.y });
      send();
    } else if (value.op === "end" || value.op === "cancel") {
      if (!drag) return;
      const completed = drag;
      drag = null;
      if (completed && !completed.music && value.op === "end") {
        if (!completed.moved) scene.characterClick();
        else if (settings.followHost && !preview)
          settings = snapPlacement(settings);
      }
      save({});
    }
  });
  let frameTiming = null;
  ipcMain.on("frame-timing", (event, value) => {
    if (widgetEvent(event)) frameTiming = value;
  });
  ipcMain.on("music-position", (event, value) => {
    if (
      !widgetEvent(event) ||
      !music ||
      !value ||
      !Number.isFinite(value.x) ||
      !Number.isFinite(value.y)
    )
      return;
    musicOffset = { x: value.x, y: value.y };
    musicStatus = value;
    sync();
  });
  ipcMain.handle("command", async (event, name, value) => {
    if (!trusted(event)) throw Error("Unknown window");
    let guarded=false;
    const fileCommands=['character-select','character-import','character-remove','character-restore','audio-import','audio-mode','audio-clear','usage-save','usage-folder','usage-home-auto'];
    const notifyBusy=value=>{
      if(editor&&!editor.isDestroyed()&&['characters','audio','usage'].includes(new URL(editor.webContents.getURL()||'file:///').searchParams.get('kind')))
        editor.webContents.send('busy',value);
    };
    try {
      if(fileCommands.includes(name)){
        if(editorBusy)throw Error('正在处理上一个文件，请稍候。');
        guarded=true;editorBusy=true;notifyBusy(true);
      }
      if (name.startsWith("bench-")) {
        if (!bench || event.sender.id !== bench.webContents.id)
          throw Error("验证台不可用");
        if (name === "bench-move") {
          const [x, y] = bench.getPosition();
          bench.setPosition(x + 40, y + 24);
        } else if (name === "bench-resize") {
          const [w, h] = bench.getSize();
          bench.setSize(w === 1150 ? 1050 : 1150, h === 800 ? 740 : 800);
        } else if (name === "bench-minimize") {
          bench.minimize();
          setTimeout(() => {
            if (bench && !bench.isDestroyed()) bench.restore();
          }, 600);
        } else if (name === "bench-completion") {
          completionPending = true;
          completionReceived++;
          scene.hide();
          completionTick();
        } else if (name === "bench-status")
          return {
            ok: true,
            data: {
              host,
              widget: handle,
              position: native.rect(handle),
              hostFrame: native.frame(host),
              visible,
              scene: scene.snapshot(),
              metrics,
              musicStatus,
              music,
              candidate,
              foreground: native.foreground(),
            },
          };
        else throw Error("未知验证操作");
        return { ok: true };
      }
      if(name==='renderer-ready'){
        if(!widgetEvent(event))throw Error('Unknown window');
        rendererReady=true;
      } else if (name === "quota") {
        dismissCompletion();
        !scene.collapsed && scene.mode === "quota"
          ? scene.hide()
          : scene.show("quota");
      } else if (name === "role") {
        dismissCompletion();
        scene.characterClick();
      } else if (name === "bubble") {
        const returnToHost=scene.mode==='completion'&&!scene.collapsed;
        const targetHost=host;
        dismissCompletion();
        scene.bubbleClick();
        if(returnToHost&&!native.activateCodex(targetHost))return {ok:false,error:'未能返回 Codex 窗口，请从任务栏打开。'};
      } else if (name === "quote") {
        dismissCompletion();
        scene.show("quote");
      } else if (name === "refresh") {
        scene.refreshInside();
      } else if (name === "refresh-menu") {
        scene.refreshFromMenu();
      } else if (name === "hide") {
        scene.hide();
      } else if (name === "menu") await openMenu();
      else if (["quotes", "characters", "colors", "audio",'usage'].includes(name))
        await openEditor(name);
      else if(name.startsWith('usage-')){
        if(!editor||editor.isDestroyed()||event.sender.id!==editor.webContents.id||new URL(editor.webContents.getURL()).searchParams.get('kind')!=='usage')throw Error('请在用量面板中操作');
        if(name==='usage-folder'){
          dialogBusy=true;let choice;
          try{choice=await dialog.showOpenDialog(editor,{title:'选择 Codex 数据目录',properties:['openDirectory']});}finally{dialogBusy=false;}
          if(!choice.canceled)await usageService.request('save',{...usageService.value.preferences,codexHome:choice.filePaths[0]});
        }else if(name==='usage-home-auto')await usageService.request('save',{...usageService.value.preferences,codexHome:null});
        else if(name==='usage-save')await usageService.request('save',{...usageService.value.preferences,rules:value?.rules});
        else if(name==='usage-select')await usageService.request('select',value);
        else if(name==='usage-refresh')await usageService.request('refresh');
        else throw Error('未知记账操作');
        return {ok:true,state:dialogState('usage')};
      }
      else if (name === "close-panel") {
        BrowserWindow.fromWebContents(event.sender)?.close();
      } else if (name === "menu-hit") {
        if (menu && event.sender.id === menu.webContents.id && !menuNativeShape)
          menu.setIgnoreMouseEvents(value !== true, { forward: true });
      } else if (name === "menu-bounds") {
        if (
          menu &&
          event.sender.id === menu.webContents.id &&
          Array.isArray(value)
        )
          menuBounds = value
            .slice(0, 12)
            .filter(
              (b) =>
                b &&
                ["x", "y", "width", "height"].every((k) =>
                  Number.isFinite(b[k]),
                ) &&
                b.width > 0 &&
                b.height > 0,
            );
        if (
          menu &&
          event.sender.id === menu.webContents.id &&
          menuBounds.length
        ) {
          const mh = native.handle(menu);
          menuNativeShape = native.rectangleShape(
            mh,
            menuBounds,
            native.dpi(mh),
          );
          if (menuNativeShape) menu.setIgnoreMouseEvents(false);
        }
      } else if(name==='auto-quote-interval'){
        save({autoQuoteIntervalSeconds:parseAutoQuoteInterval(value?.raw,value?.unit)});
      } else if (name === "settings") {
        if (!value || typeof value !== "object" || Array.isArray(value))
          throw Error("无效设置");
        const allowed = [
          "scale",
          "bubbleScale",
          "hideMenu",
          "soundOn",
          "soundVolume",
          "bubbleTapAdvance",
          "characterQuoteRepeat",
          "autoQuoteEnabled",
          "autoQuoteIntervalSeconds",
          "taskCompletionBubble",
          "followHost",
          "desktopTopmost",
          "colorMode",
          "colorChance",
          "colorTextChance",
          "colorPaused",
        ];
        const patch = Object.fromEntries(
          Object.entries(value).filter(([k]) => allowed.includes(k)),
        );
        if(Object.hasOwn(patch,'autoQuoteIntervalSeconds')&&!validAutoQuoteSeconds(patch.autoQuoteIntervalSeconds))throw Error('自动语录间隔须在 10 秒至 24 小时之间。');
        const normalized = normalizeSettings({ ...settings, ...patch });
        save(
          Object.fromEntries(Object.keys(patch).map((k) => [k, normalized[k]])),
        );
      } else if (name === "reset-position") {
        setMusic(false);
        scene.hide();
        save(
          settings.followHost
            ? { anchor: "right", side: "right", left: 0, right: 0, bottom: 0 }
            : { side: "right", desktopLeft: null, desktopTop: null },
        );
      } else if (name === "music") setMusic(value);
      else if (name === "quotes-save") {
        quotes.save(parseQuoteLines(String(value)));
        return { ok: true, state: dialogState("quotes") };
      } else if (name === "quotes-reset") {
        quotes.reset();
        return { ok: true, state: dialogState("quotes") };
      } else if (name === "colors-save") {
        const triggers = normalizeQuotes(String(value).split(/\r?\n/)).map(row=>row.text);
        writeJson(path.join(dataDir, "color-triggers.json"), {
          version: 1,
          quotes: triggers,
        });
        colors.triggers=triggers;
        send();
      } else if (name === "character-select") {
        const selected = characters.list().find((c) => c.id === value);
        if (!selected) throw Error("形象不可用");
        const image = await characters.display(selected);
        setMusic(false);
        activeImage = image;
        lastImage = "";
        save({ characterId: selected.id });
        return { ok: true, close: true };
      } else if (name === "character-import") {
        const selected = await dialog.showOpenDialog(editor ?? win, {
          title: "导入角色图片",
          filters: [
            {
              name: "角色图片",
              extensions: ["png", "jpg", "jpeg", "bmp", "gif"],
            },
          ],
          properties: ["openFile"],
        });
        if (selected.canceled) return { ok: true };
        const imported = await runIo("character", {
          source: selected.filePaths[0],
        });
        const importedImage = await characters.display(imported.id);
        galleryImages.set(imported.id,importedImage);
        setMusic(false);
        activeImage = importedImage;
        lastImage = "";
        save({ characterId: imported.id });
        return { ok: true, close: true };
      } else if (name === "character-remove") {
        const previous = activeImage;
        if (settings.characterId === value) {
          activeImage = await characters.display("gpt-dragon");
          lastImage = "";
          save({ characterId: "gpt-dragon" });
        }
        try {
          characters.remove(String(value));
        } catch (error) {
          if (previous.id === value) {
            activeImage = previous;
            lastImage = "";
            save({ characterId: previous.id });
          }
          throw error;
        }
        if (previous.id === value) setMusic(false);
        return { ok: true, state: dialogState("characters") };
      } else if (name === "character-restore") {
        characters.restore(String(value));
        await prepareGallery();
        return { ok: true, state: dialogState("characters") };
      } else if (name === "audio-mode") {
        audio.mode(value);
        audioPayload = audio.payload();
        audioRevision++;
        send();
      } else if (name === "audio-clear") {
        audio.clear(value);
        audioPayload = audio.payload();
        audioRevision++;
        send();
      } else if (name === "audio-import") {
        if (!["press", "release"].includes(value)) throw Error("无效音效");
        dialogBusy = true;
        let result;
        try {
          result = await dialog.showOpenDialog(editor ?? menu ?? win, {
            title: "选择 WAV 音效（最长5秒）",
            filters: [{ name: "WAV 音效", extensions: ["wav"] }],
            properties: ["openFile"],
          });
        } finally {
          dialogBusy = false;
        }
        if (!result.canceled) {
          await runIo("audio", { slot: value, source: result.filePaths[0] });
          audio.reload();
          audioPayload = audio.payload();
          audioRevision++;
          send();
        }
      } else if (name === "size-preview") {
        sizePreview = value?.active === true;
        scene.preview = sizePreview && value?.bubble === true;
        if (sizePreview) clearTimeout(phaseTimer);
        else if (!scene.collapsed) scene.restart();
        send();
      } else if (name === "audio-preview") {
        win.webContents.send("audio", { preview: value });
      } else if (name === "update-check") {
        await updater.check("manual");
      } else if (name === "update-automatic") {
        updater.automatic(value === true);
      } else if (name === "exit") {
        if (!candidate) {
          const identity = host ? native.identity(host) : null;
          writeJson(
            path.join(dataDir, "supervisor-pause.json"),
            settings.followHost
              ? {
                  host,
                  hostPid: identity?.pid ?? 0,
                  hostStarted: identity?.started ?? "0",
                  at: new Date().toISOString(),
                }
              : { desktop: true, at: new Date().toISOString() },
          );
        }
        stopping = true;
        app.quit();
      } else throw Error("未知操作");
      return { ok: true };
    } catch (error) {
      return { ok: false, error: error.message };
    }finally{
      if(guarded){
        editorBusy=false;notifyBusy(false);
        if(editor&&!editor.isDestroyed()){
          const kind=new URL(editor.webContents.getURL()||'file:///').searchParams.get('kind');
          if(['characters','audio'].includes(kind))editor.webContents.send('state',dialogState(kind));
        }
      }
    }
  });
  native.listen(
    (event, h) => {
      if (stopping) return;
      if ([3, 17, 22, 23, 0x800a, 0x8002, 0x8003].includes(event))
        recovery.begin();
      if (h === host && event === 0x10 && menu) menu.close();
      if (h === host && event === 0x800b) {
        metrics.movementEvents++;
        sync();
        sendGeometry();
      } else if (h === host || event === 3) {
        sync();
        void probe();
      }
    },
    { includeOwn: !!bench },
  );
  bridge.on("audio", (value) => {
    if (music && !win.isDestroyed())
      win.webContents.send("audio", {
        ...value,
        cursor: drag?.music ? native.cursor() : null,
      });
  });
  if (bench) {
    await bench.loadFile(path.join(root, "ui", "bench.html"));
    bench.show();
  }
  await win.loadFile(path.join(root, "ui", "index.html"));
  win.on("closed", () => {
    if (!stopping) app.quit();
  });
  app.on("second-instance", () => {
    scene.show("quota");
    sync();
  });
  if (preview) {
    ready = true;
    desktopStarted = true;
    scene.show("quota");
  }
  sync();
  ensureWorker();
  startMonitor();
  void probe();
  const timer = setInterval(() => {
    try {
      sync();
      void probe();
      if (
        schedule.due(
          Date.now(),
          visible,
          blocked || !!drag || !scene.collapsed || music || !!temporary,
        )
      )
        scene.show("quote");
      completionTick();
      startMonitor();
      ensureWorker();
      const f = path.join(dataDir, "status.json");
      if (fs.existsSync(f)) {
        const stamp = fs.statSync(f).mtimeMs;
        if (stamp !== statusStamp) {
          status = readJson(f);
          statusStamp = stamp;
        }
      }
      const request = readJson(path.join(dataDir, "display-request.json"));
      if (request?.nonce && request.nonce !== displayToken) {
        displayToken = request.nonce;
        if (Math.abs(Date.now() - Number(request.at)) < 10000) {
          if (request.mode === "quota") scene.show("quota");
          else if (request.mode === "quote") scene.show("quote");
          else if (
            request.mode === "completion" &&
            settings.taskCompletionBubble
          ) {
            completionPending = true;
            completionReceived++;
          } else if (request.mode === "menu" && visible) void openMenu();
          else if (request.mode === "characters" && visible)
            void openEditor("characters");
          else if (request.mode === "close-menu" && menu) menu.close();
          else if (request.mode === "music-on") setMusic(true);
          else if (request.mode === "music-off") setMusic(false);
        }
      }
      writeJson(path.join(dataDir, "presence.json"), {
        visible,
        pid: process.pid,
        at: Date.now(),
      });
      if (Date.now() - lastRuntime >= 1000) {
        lastRuntime = Date.now();
        writeJson(path.join(dataDir, "runtime.json"), {
          pid: process.pid,
          widget: handle,
          appDir: root,
          processStartedTicks: native.identity(handle).started,
          version: app.getVersion(),
          architecture: "javascript-electron",
          candidate,
          host,
          hostTitle: host ? native.title(host) : "",
          visible,
          rendererReady,
          collapsed: scene.collapsed,
          mode: scene.mode,
          characterId: settings.characterId,
          followHost: settings.followHost,
          music: { enabled: music, color: musicColor, ...musicStatus },
          completion: {
            enabled: settings.taskCompletionBubble,
            pending: completionPending,
            received: completionReceived,
            displayCount: completionCount,
            temporaryTopmost: !!temporary,
          },
          metrics,
          frameTiming,
          shape: {
            enabled: nativeShape,
            error: shapeError,
            ...native.shapeStatus(handle),
          },
          bridgeError: bridge.error,
          at: Date.now(),
        });
      }
      if (!candidate) {
        const stop = readRefreshRequest(path.join(dataDir, "stop.flag"));
        if (stop && stop !== stopToken) {
          stopping = true;
          app.quit();
        }
      }
      updater.tick(updateIdle());
      send();
    } catch (error) {
      fs.appendFileSync(
        path.join(dataDir, "candidate-errors.log"),
        new Date().toISOString() + " " + error.stack + "\n",
      );
    }
  }, 1000);
  const completionTimer = setInterval(completionTick, 100),
    sceneTimer = setInterval(() => {
      if (!sizePreview && !temporary) scene.tick();
    }, 120);
  if (verify) {
    setTimeout(async () => {
      try {
        const panels = [];
        if (verifySuite) {
          const pause = (ms) =>
            new Promise((resolve) => setTimeout(resolve, ms));
          const inspectPanel = async (window, name) => {
            await pause(250);
            const content = await window.webContents.executeJavaScript(`({
              text: document.body.innerText,
              controls: document.querySelectorAll('button,input,textarea,summary').length,
              bounds: Array.from(document.querySelectorAll('main,details[open]>.flyout')).map((el)=>{
                const r=el.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height,scrollWidth:el.scrollWidth,clientWidth:el.clientWidth};
              }), viewport: {width:innerWidth,height:innerHeight}
            })`);
            if (
              !content.controls ||
              content.bounds.some(
                (r) =>
                  r.x < -1 ||
                  r.y < -1 ||
                  r.x + r.width > content.viewport.width + 1 ||
                  r.y + r.height > content.viewport.height + 1 ||
                  r.scrollWidth > r.clientWidth + 1,
              )
            )
              throw Error("界面超出可见范围：" + name);
            fs.writeFileSync(
              path.join(dataDir, name + ".png"),
              (await window.webContents.capturePage()).toPNG(),
            );
            panels.push({ name, ...content });
          };
          for (const section of [
            null,
            "形象与大小",
            "声音与点击",
            "显示与位置",
            "语录与提醒",
            "版本与更新",
          ]) {
            verificationSection = section;
            await openMenu();
            await inspectPanel(menu, "menu-" + (section ?? "main"));
            menu.close();
            await pause(100);
          }
          verificationSection = null;
          for (const kind of ["audio", "characters", "quotes"]) {
            await openEditor(kind);
            await inspectPanel(editor, "panel-" + kind);
            editor.close();
            await pause(100);
          }
          setMusic(true);
          bridge.capture(false);
          const pulse = setInterval(() => {
            const now = performance.now();
            win.webContents.send("audio", {
              nowMs: now,
              snapshot: {
                RhythmLocked: true,
                PeriodMs: 500,
                NextBeatAtMs: Math.ceil(now / 500) * 500,
                BeatAtMs: Math.floor(now / 500) * 500,
                Sequence: Math.floor(now / 500),
                Strength: 1,
                SourceProcessId: 0,
              },
            });
          }, 16);
          await pause(12000);
          clearInterval(pulse);
          const timing = await win.webContents.executeJavaScript(
            "window.widgetVerification().frameTiming",
          );
          panels.push({
            name: "music-timing",
            syntheticBeat: true,
            durationMs: 12000,
            timing,
          });
          fs.writeFileSync(
            path.join(dataDir, "music.png"),
            (await win.webContents.capturePage()).toPNG(),
          );
          setMusic(false);
          scene.show("quota");
          await pause(600);
        }
        const result = await win.webContents.executeJavaScript(
          "window.widgetVerification()",
        );
        writeJson(path.join(dataDir, "verification.json"), {
          ...result,
          panels,
          nativeShape: {
            enabled: nativeShape,
            error: shapeError,
            ...native.shapeStatus(handle),
          },
          architecture: "javascript-electron",
          bridge: fs.existsSync(
            path.join(root, "native", "GPTNiang.Native.exe"),
          ),
          candidate,
          at: Date.now(),
        });
        const image = await win.webContents.capturePage();
        fs.writeFileSync(path.join(dataDir, "verification.png"), image.toPNG());
      } catch (error) {
        writeJson(path.join(dataDir, "verification.json"), {
          ok: false,
          error: error.message,
        });
      } finally {
        stopping = true;
        app.quit();
      }
    }, 1600);
  }
  app.on("before-quit", () => {
    stopping = true;
    usageService.close();
    for (const worker of ioWorkers) void worker.terminate();
    clearInterval(timer);
    clearInterval(completionTimer);
    clearInterval(sceneTimer);
    clearTimeout(phaseTimer);
    recovery.close();
    native.close();
    bridge.close();
    if (monitor) monitor.stdin.end();
    if (quotaWorker) quotaWorker.kill();
    if (menu && !menu.isDestroyed()) menu.destroy();
    if (editor && !editor.isDestroyed()) editor.destroy();
    if (!lamp.isDestroyed()) lamp.destroy();
  });
}
