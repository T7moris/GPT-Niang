import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Worker } from "node:worker_threads";
import { fileURLToPath } from "node:url";
import sharp from "sharp";
import { AudioStore } from "../src/core/audio.mjs";
import { Characters } from "../src/core/characters.mjs";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
function temp(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "gpt-js-io-"));
  t.after(() => {
    if (!path.resolve(dir).startsWith(path.resolve(os.tmpdir()) + path.sep))
      throw Error("Unexpected cleanup");
    fs.rmSync(dir, { recursive: true, force: true });
  });
  return dir;
}
function run(dataDir, kind, values) {
  return new Promise((resolve, reject) => {
    const worker = new Worker(path.join(root, "src", "io-worker.mjs"), {
      workerData: { root, dataDir, kind, ...values },
    });
    worker.once("message", resolve);
    worker.once("error", reject);
  });
}
test("image import runs outside the UI thread and commits an independent normalized PNG", async (t) => {
  const dataDir = temp(t),
    source = path.join(dataDir, "test.png");
  fs.writeFileSync(
    source,
    await sharp({
      create: { width: 240, height: 160, channels: 4, background: "#9988bb" },
    })
      .png()
      .toBuffer(),
  );
  const result = await run(dataDir, "character", { source });
  assert.equal(result.ok, true);
  const characters = new Characters(root, dataDir);
  assert.equal(characters.list().length, 2);
  const display = await characters.display(result.result.id);
  assert.match(display.url, /^data:image\/png;base64,/);
  assert.ok(fs.existsSync(source));
});
test("WAV import worker keeps the source and makes normalized audio immediately readable", async (t) => {
  const dataDir = temp(t),
    source = path.join(root, "assets", "press.wav"),
    result = await run(dataDir, "audio", { source, slot: "press" });
  assert.equal(result.ok, true);
  const audio = new AudioStore(root, dataDir);
  assert.equal(audio.preferences.mode, "custom");
  assert.ok(audio.payload().slots.press);
  assert.ok(fs.existsSync(source));
});
