import fs from "node:fs";
import path from "node:path";
import { parentPort, workerData } from "node:worker_threads";
import { resolveCodexHome } from "../runtime/codex-home.mjs";
import { UsageLedger } from "./core/usage-ledger.mjs";
import { readJson, writeJson } from "./core/storage.mjs";
import {
  defaultUsagePreferences,
  validateUsagePreferences,
} from "./core/usage-pricing.mjs";
const file = path.join(workerData.dataDir, "usage-preferences.json");
let preferences,
  ledger,
  selectedId = "",
  provider = "*",
  timer,
  stopped = false;
try {
  preferences = validateUsagePreferences(
    readJson(file, defaultUsagePreferences()),
  );
} catch {
  preferences = defaultUsagePreferences();
}
function open() {
  ledger?.close();
  ledger = new UsageLedger({
    dataDir: workerData.dataDir,
    codexHome: resolveCodexHome(preferences.codexHome ?? workerData.codexHome),
  });
}
function send(requestId = null, error = null) {
  let snapshot;
  try {
    snapshot = ledger?.snapshot({
      rules: preferences.rules,
      selectedId,
      provider,
    });
  } catch {
    error = "用量统计暂时不可用，请稍后重试。";
  }
  parentPort.postMessage({
    requestId,
    ok: !error,
    error,
    preferences,
    snapshot,
  });
}
function tick() {
  if (stopped) return;
  try {
    ledger.scan();
    send();
  } catch {
    send(null, "用量日志或记账文件暂时不可读，请稍后重试。");
  }
}
try {
  open();
  tick();
  timer = setInterval(tick, 1000);
} catch {
  send(null, "无法打开本地用量账本，请检查数据目录是否可写。");
}
parentPort.on("message", (message) => {
  try {
    if (message.op === "stop") {
      stopped = true;
      clearInterval(timer);
      ledger?.close();
      parentPort.close();
      return;
    }
    if (message.op === "save") {
      const next = validateUsagePreferences(message.value),
        changed = next.codexHome !== preferences.codexHome;
      if (next.codexHome) {
        const root = next.codexHome;
        if (
          root === path.dirname(root) ||
          !fs.statSync(root).isDirectory() ||
          !["sessions", "archived_sessions", "config.toml"].some((name) =>
            fs.existsSync(path.join(root, name)),
          )
        )
          throw Error(
            "所选目录里没有找到 Codex 日志或配置，请选择 Codex 数据根目录",
          );
      }
      // Validate/open a changed source before replacing the user's preferences.
      let replacement;
      if (changed)
        replacement = new UsageLedger({
          dataDir: workerData.dataDir,
          codexHome: resolveCodexHome(next.codexHome ?? workerData.codexHome),
        });
      try {
        writeJson(file, next);
      } catch (error) {
        replacement?.close();
        throw error;
      }
      preferences = next;
      if (replacement) {
        ledger?.close();
        ledger = replacement;
        selectedId = "";
        provider = "*";
      }
    } else if (message.op === "select") {
      if (
        typeof message.value?.id !== "string" ||
        message.value.id.length > 200 ||
        typeof message.value?.provider !== "string" ||
        message.value.provider.length > 160
      )
        throw Error("对话选择无效");
      selectedId = message.value.id;
      provider = message.value.provider;
    } else if (message.op !== "refresh") throw Error("未知记账操作");
    if (!ledger) open();
    ledger.scan();
    send(message.requestId);
  } catch (error) {
    send(
      message.requestId,
      message.op === "save"
        ? String(error.message)
        : "操作未完成，请稍后重试。",
    );
  }
});
