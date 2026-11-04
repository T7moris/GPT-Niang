import { inflateRawSync } from "node:zlib";
import { createHash } from "node:crypto";
const MAX_ZIP = 1024 ** 3,
  MAX_TOTAL = 2 * 1024 ** 3,
  MAX_FILE = 512 * 1024 ** 2;
export function safePackagePath(name) {
  if (
    typeof name !== "string" ||
    !name ||
    name.length > 1024 ||
    name.includes("\\") ||
    name.startsWith("/") ||
    /[\x00-\x1f\x7f:<>"|?*\uFFFD]/.test(name)
  )
    throw Error("更新包路径无效");
  const parts = name.replace(/\/$/, "").split("/");
  if (
    parts.some(
      (p) =>
        !p ||
        p.length > 255 ||
        [".", "..", ".git"].includes(p.toLowerCase()) ||
        /[. ]$/.test(p) ||
        /^(con|prn|aux|nul|conin\$|conout\$|com[1-9¹²³]|lpt[1-9¹²³])(?:\.|$)/i.test(
          p,
        ),
    )
  )
    throw Error("更新包路径无效");
  return name;
}
let table;
export function crc32(bytes) {
  table ??= Array.from({ length: 256 }, (_, n) => {
    for (let b = 0; b < 8; b++) n = n & 1 ? 0xedb88320 ^ (n >>> 1) : n >>> 1;
    return n >>> 0;
  });
  let crc = 0xffffffff;
  for (const byte of bytes) crc = table[(crc ^ byte) & 255] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}
export function readPackageZip(zip) {
  if (zip.length < 22 || zip.length > MAX_ZIP) throw Error("更新包大小无效");
  let end = -1;
  for (let n = zip.length - 22; n >= Math.max(0, zip.length - 65557); n--)
    if (
      zip.readUInt32LE(n) === 0x06054b50 &&
      n + 22 + zip.readUInt16LE(n + 20) === zip.length
    ) {
      end = n;
      break;
    }
  if (end < 0) throw Error("更新包不完整");
  const count = zip.readUInt16LE(end + 10),
    centralSize = zip.readUInt32LE(end + 12),
    central = zip.readUInt32LE(end + 16);
  if (
    !count ||
    count > 20000 ||
    count !== zip.readUInt16LE(end + 8) ||
    zip.readUInt16LE(end + 4) ||
    zip.readUInt16LE(end + 6) ||
    central + centralSize !== end
  )
    throw Error("更新包目录无效");
  let offset = central,
    total = 0;
  const files = [],
    names = new Set(),
    ranges = [],
    fileNames = new Set();
  for (let i = 0; i < count; i++) {
    if (offset + 46 > end || zip.readUInt32LE(offset) !== 0x02014b50)
      throw Error("更新包目录损坏");
    const flags = zip.readUInt16LE(offset + 8),
      method = zip.readUInt16LE(offset + 10),
      crc = zip.readUInt32LE(offset + 16),
      compressed = zip.readUInt32LE(offset + 20),
      size = zip.readUInt32LE(offset + 24),
      length = zip.readUInt16LE(offset + 28),
      extra = zip.readUInt16LE(offset + 30),
      comment = zip.readUInt16LE(offset + 32),
      attr = zip.readUInt32LE(offset + 38),
      local = zip.readUInt32LE(offset + 42);
    if (
      offset + 46 + length + extra + comment > end ||
      flags & ~0x080e ||
      flags & 1 ||
      ![0, 8].includes(method) ||
      ((attr >>> 16) & 0xf000) === 0xa000
    )
      throw Error("更新包包含不支持的文件");
    const raw = zip.subarray(offset + 46, offset + 46 + length),
      name = safePackagePath(raw.toString("utf8")),
      key = name.replace(/\/$/, "").toLowerCase();
    if (!Buffer.from(name).equals(raw) || names.has(key))
      throw Error("更新包包含重名或无效文件");
    names.add(key);
    if (!name.endsWith("/")) fileNames.add(key);
    offset += 46 + length + extra + comment;
    total += size;
    if (
      total > MAX_TOTAL ||
      size > MAX_FILE ||
      compressed === 0xffffffff ||
      size === 0xffffffff ||
      local === 0xffffffff
    )
      throw Error("更新包解压体积过大");
    if (
      local + 30 > central ||
      zip.readUInt32LE(local) !== 0x04034b50 ||
      zip.readUInt16LE(local + 6) !== flags ||
      zip.readUInt16LE(local + 8) !== method
    )
      throw Error("更新包文件头损坏");
    const localNameLength = zip.readUInt16LE(local + 26),
      start = local + 30 + localNameLength + zip.readUInt16LE(local + 28);
    if (
      !zip.subarray(local + 30, local + 30 + localNameLength).equals(raw) ||
      start + compressed > central
    )
      throw Error("更新包文件越界");
    let finish = start + compressed;
    if (flags & 8) {
      const signature =
        finish + 4 <= central && zip.readUInt32LE(finish) === 0x08074b50
          ? 4
          : 0;
      if (
        finish + signature + 12 > central ||
        zip.readUInt32LE(finish + signature) !== crc ||
        zip.readUInt32LE(finish + signature + 4) !== compressed ||
        zip.readUInt32LE(finish + signature + 8) !== size
      )
        throw Error("更新包数据描述损坏");
      finish += signature + 12;
    } else if (
      zip.readUInt32LE(local + 14) !== crc ||
      zip.readUInt32LE(local + 18) !== compressed ||
      zip.readUInt32LE(local + 22) !== size
    )
      throw Error("更新包文件长度不符");
    ranges.push({ start: local, end: finish });
    const bytes =
      method === 8
        ? inflateRawSync(zip.subarray(start, start + compressed), {
            maxOutputLength: size + 1,
          })
        : zip.subarray(start, start + compressed);
    if (bytes.length !== size || crc32(bytes) !== crc)
      throw Error("更新包文件校验失败");
    if (!name.endsWith("/")) files.push({ name, bytes });
  }
  if (offset !== end) throw Error("更新包目录长度不符");
  ranges.sort((a, b) => a.start - b.start);
  for (let n = 1; n < ranges.length; n++)
    if (ranges[n].start < ranges[n - 1].end) throw Error("更新包文件重叠");
  for (const name of names) {
    const parts = name.split("/");
    while (parts.length > 1) {
      parts.pop();
      if (fileNames.has(parts.join("/"))) throw Error("更新包文件与目录冲突");
    }
  }
  return files;
}
export function inspectJavaScriptPackage(zip, version) {
  const files = readPackageZip(zip),
    packageFile =
      files.find((f) => f.name === "package.json") ??
      files.find((f) => f.name.endsWith("/gpt-niang-usage/package.json"));
  if (!packageFile)
    throw Error("此更新包仍使用旧架构，等待 JavaScript 发行包。");
  const prefix = packageFile.name.slice(0, -12);
  if (files.some((f) => !f.name.startsWith(prefix)))
    throw Error("更新包包含程序目录以外的文件");
  const stripped = files.map((f) => ({
      ...f,
      name: f.name.slice(prefix.length),
    })),
    meta = JSON.parse(packageFile.bytes.toString("utf8"));
  if (
    meta.architecture !== "javascript-electron" ||
    meta.name !== "gpt-niang-usage"
  )
    throw Error("此更新包仍使用旧架构，等待 JavaScript 发行包。");
  if (meta.version !== version) throw Error("更新包版本不匹配");
  for (const name of [
    "src/bootstrap.cjs",
    "src/main.mjs",
    "src/preload.cjs",
    "src/update-agent.mjs",
    "src/start.mjs",
    "src/supervisor.mjs",
    "src/install.mjs",
    "native/GPTNiang.Native.exe",
    "native/GPTNiang.Start.exe",
    "native/GPTNiang.Setup.exe",
    "ui/index.html",
    "runtime/usage.mjs",
  ])
    if (!stripped.some((f) => f.name === name))
      throw Error("更新包缺少 " + name);
  const manifest = stripped.find((f) => f.name === "integrity.json");
  if (!manifest) throw Error("更新包缺少文件清单");
  const integrity = JSON.parse(manifest.bytes.toString("utf8"));
  if (
    integrity.version !== 1 ||
    !integrity.files ||
    Array.isArray(integrity.files)
  )
    throw Error("更新包文件清单无效");
  const expected = Object.keys(integrity.files).sort(),
    actual = stripped
      .filter((f) => f.name !== "integrity.json")
      .map((f) => f.name)
      .sort();
  if (JSON.stringify(expected) !== JSON.stringify(actual))
    throw Error("更新包文件与清单不一致");
  for (const file of stripped)
    if (file.name !== "integrity.json") {
      const hash = createHash("sha256").update(file.bytes).digest("hex");
      if (integrity.files[file.name] !== hash)
        throw Error("更新包文件哈希不符：" + file.name);
    }
  return stripped;
}
