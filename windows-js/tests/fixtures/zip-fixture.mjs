import { deflateRawSync } from "node:zlib";
import { crc32 } from "../../src/core/archive.mjs";
import { createHash } from "node:crypto";
export function zipFixture(files, { mode = 0x8000, compressed = true } = {}) {
  let offset = 0;
  const local = [],
    central = [];
  for (const [name, value] of Object.entries(files)) {
    const raw = Buffer.from(name),
      data = Buffer.from(value),
      packed = compressed ? deflateRawSync(data) : data,
      head = Buffer.alloc(30),
      entry = Buffer.alloc(46);
    head.writeUInt32LE(0x04034b50);
    head.writeUInt16LE(20, 4);
    head.writeUInt16LE(0x800, 6);
    head.writeUInt16LE(compressed ? 8 : 0, 8);
    head.writeUInt32LE(crc32(data), 14);
    head.writeUInt32LE(packed.length, 18);
    head.writeUInt32LE(data.length, 22);
    head.writeUInt16LE(raw.length, 26);
    entry.writeUInt32LE(0x02014b50);
    entry.writeUInt16LE(0x314, 4);
    entry.writeUInt16LE(20, 6);
    entry.writeUInt16LE(0x800, 8);
    entry.writeUInt16LE(compressed ? 8 : 0, 10);
    entry.writeUInt32LE(crc32(data), 16);
    entry.writeUInt32LE(packed.length, 20);
    entry.writeUInt32LE(data.length, 24);
    entry.writeUInt16LE(raw.length, 28);
    entry.writeUInt32LE((mode << 16) >>> 0, 38);
    entry.writeUInt32LE(offset, 42);
    local.push(head, raw, packed);
    central.push(entry, raw);
    offset += head.length + raw.length + packed.length;
  }
  const dir = Buffer.concat(central),
    end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50);
  end.writeUInt16LE(Object.keys(files).length, 8);
  end.writeUInt16LE(Object.keys(files).length, 10);
  end.writeUInt32LE(dir.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...local, dir, end]);
}
export function packageFiles(version = "1.3.6") {
  const files = Object.fromEntries(
    [
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
    ].map((name) => [name, Buffer.from("fixture " + name)]),
  );
  files["package.json"] = Buffer.from(
    JSON.stringify({
      name: "gpt-niang-usage",
      architecture: "javascript-electron",
      version,
    }),
  );
  files["integrity.json"] = Buffer.from(
    JSON.stringify({
      version: 1,
      files: Object.fromEntries(
        Object.entries(files).map(([name, bytes]) => [
          name,
          createHash("sha256").update(bytes).digest("hex"),
        ]),
      ),
    }),
  );
  return files;
}
