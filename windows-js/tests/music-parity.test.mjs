import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { MusicMotion } from "../ui/music-motion.mjs";
test(
  "JS physics matches 2700 frames from the frozen original C# implementation",
  { skip: process.platform !== "win32" },
  () => {
    const root = path.dirname(fileURLToPath(import.meta.url)),
      compiler = path.join(
        process.env.WINDIR,
        "Microsoft.NET",
        "Framework64",
        "v4.0.30319",
        "csc.exe",
      ),
      generated = path.join(root, ".generated");
    fs.mkdirSync(generated, { recursive: true });
    const exe = path.join(generated, "GoldenMotion.exe");
    execFileSync(compiler, [
      "/nologo",
      "/optimize+",
      "/reference:System.Web.Extensions.dll",
      "/out:" + exe,
      path.join(root, "fixtures", "GptMusicMotion.reference.cs"),
      path.join(root, "fixtures", "GoldenMotion.cs"),
    ]);
    const expected = JSON.parse(
      execFileSync(exe, [], { encoding: "utf8", maxBuffer: 16 * 1024 * 1024 }),
    );
    let row = 0,
      maxError = 0;
    for (const dpi of [1, 1.25, 1.5]) {
      const m = new MusicMotion(
        350 * dpi,
        400 * dpi,
        1000 * dpi,
        700 * dpi,
        118 * dpi,
        dpi,
      );
      for (let i = 0; i < 900; i++) {
        const dt = [1 / 60, 0.012, 0.018, 0.15, 0.033][i % 5];
        if (i === 100) m.beginHold(320 * dpi, 240 * dpi);
        if (i > 100 && i <= 130)
          m.moveHeld(
            (320 + (i - 100) * 7) * dpi,
            (260 - Math.sin(i * 0.11) * 80) * dpi,
            dt,
            (320 + (i - 100) * 7) * dpi,
            (240 - Math.sin(i * 0.11) * 80) * dpi,
          );
        if (i === 131) m.release();
        if (i === 500) m.resize(1250 * dpi, 740 * dpi, 140 * dpi, dpi);
        const locked = i > 220 && (i < 600 || i > 650);
        m.step(
          dt,
          i >= 300 && i < 332,
          locked,
          (i * 0.016) / 0.52,
          0.52,
          0.93,
          dt,
        );
        if (!locked && i > 220) m.respondToOnset((i % 40) * 0.016, 0.9);
        const reference = expected[row++];
        for (const [key, value] of Object.entries(reference)) {
          if (["dpi", "i"].includes(key)) continue;
          if (typeof value === "number") {
            const error = Math.abs(value - m[key]);
            maxError = Math.max(maxError, error);
            assert.ok(
              error < 1e-7,
              `dpi ${dpi}, frame ${i}, ${key}: ${m[key]} != ${value}`,
            );
          } else assert.equal(m[key], value);
        }
      }
    }
    assert.equal(row, 2700);
  },
);
