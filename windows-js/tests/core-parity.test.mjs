import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import sharp from "sharp";
import { fileURLToPath } from "node:url";
import { normalizeSettings, SettingsStore } from "../src/core/settings.mjs";
import {
  normalizeQuotes,
  parseQuoteLines,
  QuoteStore,
  AutoQuoteSchedule,
} from "../src/core/quotes.mjs";
import { Scene } from "../src/core/scene.mjs";
import {
  layout,
  placement,
  dragPlacement,
  snapPlacement,
} from "../src/core/layout.mjs";
import {
  formatQuota,
  quotaRows,
  resetCountdown,
  resetFixed,
} from "../src/core/quota.mjs";
import { Colors, resolvePalette } from "../src/core/colors.mjs";
import { Characters } from "../src/core/characters.mjs";
import { AudioStore } from "../src/core/audio.mjs";
import { ClickSequence } from "../ui/click-audio.mjs";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
function temporary(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "gpt-js-core-"));
  t.after(() => {
    if (
      !path.resolve(directory).startsWith(path.resolve(os.tmpdir()) + path.sep)
    )
      throw Error("Unexpected cleanup path");
    fs.rmSync(directory, { recursive: true, force: true });
  });
  return directory;
}
test("independent settings retain negative bottom, malformed-field isolation and old-layout migration", () => {
  const s = normalizeSettings({
    layoutVersion: 2,
    scale: 0.6,
    bottom: -12,
    followHost: false,
    soundVolume: "bad",
    bubbleScale: 1.4,
    left: -3,
    side: "left",
    autoQuoteIntervalSeconds: 900,
  });
  assert.equal(s.bottom, -12);
  assert.equal(s.scale, 0.6);
  assert.equal(s.bubbleScale, 1.4);
  assert.equal(s.soundVolume, 0.9);
  assert.equal(s.followHost, false);
  assert.equal(s.left, -3);
  assert.equal(normalizeSettings({ scale: 1.4 }).bubbleScale, 1.4);
  assert.equal(normalizeSettings({ right: 30, bottom: -12 }).anchor, "free");
  assert.equal(normalizeSettings({ right: 30, bottom: -12 }).bottom, 0);
});
test("settings save preserves unknown fields, creates backup and does not overwrite a broken file on load", (t) => {
  const dir = temporary(t),
    file = path.join(dir, "settings.json");
  fs.writeFileSync(file, "broken");
  const failed = new SettingsStore(file);
  assert.equal(failed.loadFailed, true);
  assert.equal(fs.readFileSync(file, "utf8"), "broken");
  fs.writeFileSync(
    file,
    JSON.stringify({ layoutVersion: 2, unknown: "keep", scale: 0.8 }),
  );
  const store = new SettingsStore(file);
  store.save({ bubbleScale: 1.6 });
  assert.equal(JSON.parse(fs.readFileSync(file)).unknown, "keep");
  assert.equal(JSON.parse(fs.readFileSync(file + ".bak")).scale, 0.8);
});
test("quote validation, duplicates, weights and editor parsing match original rules", () => {
  assert.deepEqual(
    normalizeQuotes([
      { text: 22 },
      { text: " A ", weight: 800 },
      { text: "A", weight: 800 },
      "B",
      { text: "x", weight: 0 },
      "\x01bad",
      "a".repeat(201),
    ]),
    [
      { text: "A", weight: 1000 },
      { text: "B", weight: 1 },
    ],
  );
  assert.deepEqual(parseQuoteLines("3 | 你好\n一条\n0 | 忽略\n3 | 你好"), [
    { text: "你好", weight: 6 },
    { text: "一条", weight: 1 },
  ]);
});
test("custom quote pool takes effect, avoids repeats and restores a backed-up builtin pool", (t) => {
  const dir = temporary(t),
    store = new QuoteStore(dir, path.join(root, "assets"), () => 0.1);
  const builtins = store.list().quotes;
  assert.equal(builtins.length, 39);
  store.save(["甲", "乙"]);
  assert.equal(store.next(), "甲");
  assert.equal(store.next(), "乙");
  store.reset();
  assert.equal(store.list().source, "built-in");
  assert.ok(fs.existsSync(path.join(dir, "quotes.json.bak")));
});
test("scene timing retains 520 ms opening, 280 ms switch, 2 s countdown and 5 s visible life", () => {
  let now = 10000;
  const s = new Scene({
    settings: { bubbleTapAdvance: false },
    quote: () => "语录",
    now: () => now,
  });
  assert.equal(s.collapsed, true);
  s.characterClick();
  assert.equal(s.startedAt, 10520);
  assert.equal(s.deadline, 15520);
  s.tick(12519);
  assert.equal(s.resetTimeMode, "countdown");
  s.tick(12520);
  assert.equal(s.resetTimeMode, "fixed");
  now = 13000;
  s.bubbleClick();
  assert.equal(s.mode, "quote");
  assert.equal(s.startedAt, 13280);
  s.bubbleClick();
  assert.equal(s.collapsed, true);
  s.bubbleClick();
  assert.equal(s.collapsed, true);
  s.characterClick();
  now = 14000;
  s.characterClick();
  assert.equal(s.startedAt, 14000);
  s.tick(19000);
  assert.equal(s.collapsed, true);
});
test("automatic quotes wait for visible idle time and restart after interaction, clock change or resume", () => {
  const schedule = new AutoQuoteSchedule(
    { autoQuoteEnabled: true, autoQuoteIntervalSeconds: 60 },
    10000,
  );
  assert.equal(schedule.due(10000, true, false), false);
  for (let n = 11000; n < 70000; n += 1000)
    assert.equal(schedule.due(n, true, false), false);
  assert.equal(schedule.due(70000, true, false), true);
  assert.equal(schedule.due(71000, false, false), false);
  assert.equal(schedule.due(80000, true, false), false);
  assert.equal(schedule.next, 140000);
  assert.equal(schedule.due(79000, true, false), false);
  assert.equal(schedule.next, 139000);
});
test("business personal cap and additional timed quotas retain display selection and unavailable reset semantics", () => {
  const personal = {
      kind: "individual",
      used: 20,
      remaining: 80,
      resetsAt: null,
    },
    short = { minutes: 300, used: 90, remaining: 10, resetsAt: 5000 },
    week = { minutes: 10080, used: 10, remaining: 90, resetsAt: 9000 };
  const rows = quotaRows({ windows: [week, short, personal] });
  assert.equal(rows[0].label, "个人额度");
  assert.equal(rows[1].window, short);
  const view = formatQuota(
    {
      ok: true,
      queryOk: true,
      windows: [personal, short, week],
      observedAt: 1000000,
    },
    "countdown",
    1000000,
  );
  assert.equal(view.rows[0].resetText, "未提供重置时间");
  assert.equal(view.rows[1].valueColor, "#B74839");
  assert.equal(
    formatQuota({ ok: true, queryOk: true, windows: [] }).rows.every(
      (r) => !r.visible,
    ),
    true,
  );
  assert.equal(resetCountdown(3600), "1 小时后重置");
  assert.equal(resetCountdown(3660), "1 小时 1 分后重置");
  assert.equal(resetCountdown(86400), "1 天后重置");
  assert.equal(resetFixed(1, 2), "重置已到，等待更新");
});
test("all independent sizes stay in the immutable 378 px canvas and placement preserves full host offsets", () => {
  for (const scale of [0.6, 1, 2.5])
    for (const bubbleScale of [0.6, 1, 2.5])
      for (const side of ["left", "right"]) {
        const s = normalizeSettings({
          layoutVersion: 2,
          scale,
          bubbleScale,
          side,
          anchor: "free",
          left: 30,
          bottom: -12,
        });
        const l = layout(s);
        assert.ok(
          l.bubble.left >= 0 &&
            l.bubble.left + 350 * l.bubble.scale <= 350.00001,
        );
        assert.ok(
          l.bubble.top >= 0 && l.bubble.top + 239 * l.bubble.scale <= 350.00001,
        );
        const p = placement(
          { left: -100, top: 0, right: 1500, bottom: 900 },
          s,
          1.25,
        );
        assert.equal(p.x, -62);
        const desiredY = 900 - 378 * l.display * 1.25 + 15,
          bottomLimit =
            900 - (14 + l.girl.top + l.girl.height) * l.display * 1.25;
        assert.equal(p.y, Math.round(Math.min(desiredY, bottomLimit)));
        assert.equal(s.bottom, -12);
      }
  assert.equal(snapPlacement({ side: "left", left: 10 }).anchor, "left");
  assert.equal(snapPlacement({ side: "right", right: -2 }).anchor, undefined);
});
test("drag limits constrain the character while allowing transparent bubble space outside the frame", () => {
  for (const side of ["left", "right"]) {
    const s = normalizeSettings({
      layoutVersion: 2,
      scale: 0.6,
      bubbleScale: 2.5,
      side,
    });
    const f = { left: 0, top: 0, right: 1000, bottom: 800 },
      p = dragPlacement(f, s, -10000, 10000, 1, side === "left" ? 0 : 1000),
      g = layout(s).girl,
      l = layout(s),
      left = side === "left" ? 350 - g.left - g.width : g.left;
    assert.ok(p.x + (14 + left) * l.display >= -0.001);
    assert.ok(p.y + (14 + g.top + g.height) * l.display <= 800.001);
  }
});
test("color decisions are once per quote and text selection is independent of appearance", () => {
  const settings = normalizeSettings({
    layoutVersion: 2,
    colorMode: "mixed",
    colorChance: 0.5,
    colorTextChance: 3,
  });
  let draws = 0;
  const colors = new Colors(settings, undefined, () => {
      draws++;
      return 0.01;
    }),
    scene = { revision: 1, text: "甲", mode: "quote", collapsed: false };
  assert.equal(colors.scene(scene).scope, "text");
  colors.scene(scene);
  assert.equal(draws, 1);
  assert.equal(colors.scene({ ...scene, collapsed: true }).scope, "none");
  assert.equal(resolvePalette("Claude 和 GPT"), "rainbow");
  assert.equal(resolvePalette("失忆"), "claude");
  assert.equal(resolvePalette("肥鱼"), "deepsea");
  assert.equal(resolvePalette("屠龙"), "creeper");
});
test("character import owns a bounded PNG, rejects invisible images and supports removal undo", async (t) => {
  const dir = temporary(t),
    characters = new Characters(root, dir),
    source = path.join(dir, "portrait.png");
  const bytes = await sharp({
    create: {
      width: 50,
      height: 90,
      channels: 4,
      background: { r: 1, g: 2, b: 3, alpha: 1 },
    },
  })
    .png()
    .toBuffer();
  fs.writeFileSync(source, bytes);
  const imported = await characters.import(source);
  assert.match(imported.id, /^custom-[a-f0-9]{32}$/);
  assert.equal(characters.list().length, 2);
  characters.remove(imported.id);
  assert.equal(characters.list().length, 1);
  assert.equal(characters.removed().length, 1);
  characters.restore(imported.id);
  assert.equal(characters.list().length, 2);
  assert.deepEqual(fs.readFileSync(source), bytes);
  fs.writeFileSync(
    source,
    await sharp({
      create: {
        width: 32,
        height: 32,
        channels: 4,
        background: { r: 0, g: 0, b: 0, alpha: 0 },
      },
    })
      .png()
      .toBuffer(),
  );
  await assert.rejects(characters.import(source), /没有可见像素/);
});
test("custom audio import and clearing switch to custom mode, retain the other slot and persist normalized WAV", (t) => {
  const dir = temporary(t),
    audio = new AudioStore(root, dir);
  audio.import("press", path.join(root, "assets", "press.wav"));
  assert.equal(audio.preferences.mode, "custom");
  const press = audio.preferences.press.file;
  audio.import("release", path.join(root, "assets", "release.wav"));
  assert.equal(audio.preferences.press.file, press);
  audio.mode("builtin");
  assert.ok(audio.payload().previewSlots.press);
  audio.clear("press");
  assert.equal(audio.preferences.mode, "custom");
  assert.equal(audio.preferences.press, null);
  assert.ok(audio.preferences.release);
  assert.equal(JSON.parse(fs.readFileSync(path.join(dir,"audio-preferences.json.bak"),"utf8")).press.file, press);
  assert.equal(fs.existsSync(path.join(dir, "sounds", press)), true);
  audio.mode("builtin"); // The backup is now superseded and no longer references the clip.
  assert.equal(fs.existsSync(path.join(dir, "sounds", press)), false);
});
test("click sound release waits for press duration plus 60 ms, and a new press or cancellation cancels it", () => {
  let now = 100,
    scheduled = null,
    delay = 0;
  const plays = [],
    sequence = new ClickSequence({
      play: (s) => plays.push(s),
      stop: () => {},
      available: () => true,
      duration: () => 0.2,
      enabled: () => true,
      now: () => now,
      schedule: (callback, ms) => {
        scheduled = callback;
        delay = ms;
        return 1;
      },
      cancel: () => {
        scheduled = null;
      },
    });
  sequence.press();
  now = 120;
  sequence.release();
  assert.equal(delay, 240);
  assert.deepEqual(plays, ["press"]);
  scheduled();
  assert.deepEqual(plays, ["press", "release"]);
  sequence.press();
  sequence.release();
  sequence.press();
  assert.equal(scheduled, null);
  sequence.release();
  sequence.stop();
  assert.equal(scheduled, null);
});
