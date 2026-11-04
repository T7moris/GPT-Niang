import fs from "node:fs";
export function guiEnvironment(env = process.env) {
  return Object.fromEntries(
    Object.entries(env).filter(
      ([key]) => key.toUpperCase() !== "ELECTRON_RUN_AS_NODE",
    ),
  );
}
import path from "node:path";
export function samePath(a, b) {
  if (typeof a !== 'string' || !a || typeof b !== 'string' || !b) return false;
  const left = path.resolve(a), right = path.resolve(b);
  return process.platform === 'win32'
    ? left.toLowerCase() === right.toLowerCase()
    : left === right;
}
export function resolveNodeHost(root, configured, fallback = process.execPath) {
  const bundled = path.join(root, 'node_modules', 'electron', 'dist', 'electron.exe');
  for (const file of [configured, bundled, fallback]) {
    if (typeof file !== 'string' || !file) continue;
    try { if (fs.statSync(file).isFile()) return path.resolve(file); } catch {}
  }
  throw Error('没有找到可用的运行环境，请重新运行安装检查。');
}
export function readJson(file, fallback = null) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""));
  } catch {
    return fallback;
  }
}
export function writeJson(file, value, { backup = true } = {}) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary =
    file +
    "." +
    process.pid +
    "." +
    Math.random().toString(16).slice(2) +
    ".tmp";
  try {
    fs.writeFileSync(temporary, JSON.stringify(value, null, 2) + "\n", "utf8");
    if (backup && fs.existsSync(file)) fs.copyFileSync(file, file + ".bak");
    fs.renameSync(temporary, file);
  } finally {
    try {
      fs.unlinkSync(temporary);
    } catch {}
  }
}
export function inside(root, relative) {
  if (typeof relative !== "string" || !relative || path.isAbsolute(relative))
    throw new Error("文件路径必须位于数据目录中。");
  const base = path.resolve(root),
    file = path.resolve(base, relative);
  if (!file.toLowerCase().startsWith(base.toLowerCase() + path.sep))
    throw new Error("文件路径超出了数据目录。");
  for (let p = file; p.length >= base.length; p = path.dirname(p)) {
    try {
      if (fs.lstatSync(p).isSymbolicLink())
        throw new Error("文件目录不能使用文件链接。");
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    if (p === base) break;
  }
  return file;
}
