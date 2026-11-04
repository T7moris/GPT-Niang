const fs = require("node:fs"),
  path = require("node:path"),
  { app } = require("electron");
let config = {};
try {
  config = JSON.parse(
    fs
      .readFileSync(path.resolve(__dirname, "..", "installation.json"), "utf8")
      .replace(/^\uFEFF/, ""),
  );
} catch {}
const dataOption = process.argv.indexOf("--data-dir"),
  installed =
    config.architecture === "javascript-electron" &&
    typeof config.appDir === 'string' && config.appDir.length > 0 &&
    (process.platform === 'win32'
      ? path.resolve(config.appDir).toLowerCase() === path.resolve(__dirname, "..").toLowerCase()
      : path.resolve(config.appDir) === path.resolve(__dirname, "..")) &&
    !process.argv.includes("--candidate"),
  directory =
    (dataOption >= 0 && process.argv[dataOption + 1]) ||
    ((config.candidate === true || installed) && config.dataDir) ||
    path.resolve(__dirname, "..", "..", "candidate", "state"),
  file = path.join(directory, "startup.log");
const log = (value) => {
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.appendFileSync(
      file,
      new Date().toISOString() + " " + String(value) + "\n",
    );
  } catch {}
};
log("bootstrap " + process.pid + " " + JSON.stringify(process.argv));
process.on("uncaughtException", (error) => {
  log(error.stack);
  app.exit(1);
});
process.on("unhandledRejection", (error) => {
  log(error?.stack ?? error);
  app.exit(1);
});
process.on("exit", (code) => log("exit " + code));
import("./main.mjs").catch((error) => {
  log(error.stack);
  app.exit(1);
});
