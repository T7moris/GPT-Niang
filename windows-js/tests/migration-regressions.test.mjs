import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { AudioStore } from "../src/core/audio.mjs";
import { normalizeSettings } from "../src/core/settings.mjs";
import { placement, layout, resizeAnchors } from "../src/core/layout.mjs";
import { formatQuota } from "../src/core/quota.mjs";
import { FrameStats } from "../ui/frame-stats.mjs";
import { guiEnvironment } from "../src/core/storage.mjs";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
test("GUI launch removes the Electron node-mode variable rather than assigning an empty value", () => {
  assert.deepEqual(
    guiEnvironment({
      PATH: "preserved",
      ELECTRON_RUN_AS_NODE: "1",
      Electron_Run_As_Node: "",
    }),
    { PATH: "preserved" },
  );
});
test("a missing custom preview cannot silence the selected builtin press sound", (t) => {
  const directory = fs.mkdtempSync(
    path.join(os.tmpdir(), "gpt-js-audio-fallback-"),
  );
  t.after(() => {
    assert.ok(directory.startsWith(os.tmpdir() + path.sep));
    fs.rmSync(directory, { recursive: true, force: true });
  });
  const store = new AudioStore(root, directory);
  store.import("press", path.join(root, "assets", "press.wav"));
  const file = store.preferences.press.file;
  store.mode("builtin");
  fs.unlinkSync(path.join(directory, "sounds", file));
  assert.ok(store.payload().slots.press);
  assert.equal(store.payload().previewSlots.press, null);
  assert.match(store.payload().preferences.errors.press, /无法读取/);
  store.mode("custom");
  assert.equal(store.payload().slots.press, null);
});
test("negative right offsets survive restart and a shrinking host clamps visually without rewriting saved offsets", () => {
  const s = normalizeSettings({
    layoutVersion: 2,
    right: -60,
    left: 700,
    bottom: -12,
    anchor: "free",
    side: "right",
    scale: 0.6,
    bubbleScale: 2.5,
  });
  assert.equal(s.right, -60);
  const large = { left: 0, top: 0, right: 1800, bottom: 1000 },
    small = { ...large, right: 600, bottom: 400 },
    initial = placement(large, s),
    shrunk = placement(small, s),
    restored = placement(large, s),
    l = layout(s),
    right = (14 + l.girl.left + l.girl.width) * l.display,
    bottom = (14 + l.girl.top + l.girl.height) * l.display;
  assert.ok(shrunk.x + right <= small.right + 1);
  assert.ok(shrunk.y + bottom <= small.bottom + 1);
  assert.deepEqual(restored, initial);
  assert.equal(s.left, 700);
});
test("independent resizing preserves negative transparent margins in follow mode", () => {
  const before = normalizeSettings({
    layoutVersion: 2,
    scale: 1,
    bubbleScale: 1,
    left: -14,
    right: -16,
    bottom: -12,
  });
  const next = resizeAnchors(before, { ...before, scale: 2 });
  assert.deepEqual([next.left, next.right, next.bottom], [-28, -32, -24]);
  assert.equal(resizeAnchors(before, { ...before, scale: 0.6 }).bottom, -12);
  assert.equal(
    resizeAnchors(
      { ...before, followHost: false },
      { ...before, followHost: false, scale: 2 },
    ).bottom,
    -12,
  );
});
test("quota tooltip preserves personal amounts and all omitted timed windows", () => {
  const now = Date.now(),
    quota = formatQuota(
      {
        ok: true,
        queryOk: true,
        observedAt: now,
        planLabel: "Business",
        windows: [
          {
            kind: "individual",
            used: 30,
            remaining: 70,
            total: 1000,
            amountUsed: 300,
            amountRemaining: 700,
          },
          { minutes: 300, used: 20, remaining: 80 },
          { minutes: 10080, used: 40, remaining: 60 },
        ],
      },
      "fixed",
      now,
    );
  assert.match(quota.tooltip, /非公司总余额/);
  assert.match(quota.tooltip, /额度上限 1000 · 已用 300 · 剩余 700/);
  assert.match(quota.tooltip, /每周：已用 40%/);
});
test("frame timing excludes startup and hidden intervals and counts actual long gaps", () => {
  const stats = new FrameStats();
  for (let n = 0; n < 180; n++) stats.sample((n * 1000) / 60, true);
  assert.ok(Math.abs(stats.read().fps - 60) < 0.1);
  stats.sample(3100, true);
  assert.equal(stats.read().over50ms, 1);
  stats.sample(3200, false);
  stats.sample(10000, true);
  assert.equal(stats.read().over50ms, 1);
});
