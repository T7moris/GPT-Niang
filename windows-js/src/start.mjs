import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { readJson, writeJson, guiEnvironment, samePath, resolveNodeHost } from "./core/storage.mjs";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), ".."),
  config = readJson(path.join(root, "installation.json")),
  args = process.argv.slice(2);
if (!config?.dataDir || !samePath(config.appDir, root))
  throw Error("安装位置已改变，请重新运行安装检查。");
if (args.includes("--supervise")) await import("./supervisor.mjs");
else {
  for (const name of [
    "supervisor-pause.json",
    "supervisor-disabled.flag",
    "supervisor-stop.flag",
    "stop.flag",
  ])
    try {
      fs.unlinkSync(path.join(config.dataDir, name));
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
  const node = resolveNodeHost(root, config.nodePath),
    child = spawn(node, [path.join(root, "src", "supervisor.mjs")], {
      cwd: root,
      windowsHide: true,
      detached: true,
      stdio: "ignore",
      env: {
        ...guiEnvironment(),
        ...(/electron\.exe$/i.test(node) ? { ELECTRON_RUN_AS_NODE: "1" } : {}),
      },
    });
  child.on("error", () => {});
  child.unref();
  writeJson(path.join(config.dataDir, "display-request.json"), {
    mode: "quota",
    at: Date.now(),
    nonce: crypto.randomUUID(),
  });
}
