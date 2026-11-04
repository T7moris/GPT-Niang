import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { alphaRectangles } from "../ui/shape.mjs";
import { CloakTransition } from "../src/core/occlusion.mjs";
import {
  readPause,
  sessionPaused,
  shouldLaunch,
} from "../src/core/lifecycle.mjs";
test("alpha masks preserve every opaque point and vertically merge identical runs", () => {
  const w = 20,
    h = 17,
    bytes = new Uint8ClampedArray(w * h * 4);
  for (let y = 0; y < h; y++)
    for (let x = 0; x < w; x++)
      bytes[(y * w + x) * 4 + 3] =
        (x >= 2 && x < 8 && y >= 1 && y < 15) ||
        (x >= 12 && x < 18 && y >= 5 && y < 10)
          ? 255
          : 10;
  const rects = alphaRectangles(bytes, w, h);
  assert.equal(rects.length, 2);
  for (let y = 0; y < h; y++)
    for (let x = 0; x < w; x++)
      assert.equal(
        rects.some((r) => x >= r[0] && x < r[2] && y >= r[1] && y < r[3]),
        bytes[(y * w + x) * 4 + 3] > 10,
      );
});
test(
  "native GDI regions match mirrored, resized and compressed hit masks",
  { skip: process.platform !== "win32" },
  async () => {
    const { probeTransformedRegion } = await import("../src/windows/shape.mjs");
    const source = {
      width: 40,
      height: 50,
      rects: [
        [2, 3, 12, 10],
        [2, 10, 35, 30],
        [15, 30, 29, 46],
      ],
    };
    let compared = 0;
    for (const mirror of [-1, 1])
      for (const dpi of [0.75, 1, 1.25, 1.5, 2])
        for (const squash of [0.6, 0.88, 1, 1.16]) {
          const a = mirror * dpi,
            d = dpi * squash,
            e = mirror < 0 ? 120.25 : 10.25,
            f = 14.4,
            points = [],
            expected = [];
          for (let y = 0; y < 130; y += 2)
            for (let x = 0; x < 150; x += 2) {
              const sx = (x - e) / a,
                sy = (y - f) / d;
              const near = source.rects.some(
                (r) =>
                  Math.min(
                    Math.abs(x - (a * r[0] + e)),
                    Math.abs(x - (a * r[2] + e)),
                    Math.abs(y - (d * r[1] + f)),
                    Math.abs(y - (d * r[3] + f)),
                  ) < 1.4,
              );
              if (near) continue;
              points.push([x, y]);
              expected.push(
                source.rects.some(
                  (r) => sx >= r[0] && sx < r[2] && sy >= r[1] && sy < r[3],
                ),
              );
            }
          assert.deepEqual(
            probeTransformedRegion(source, [a, 0, 0, d, e, f], points),
            expected,
          );
          compared += points.length;
        }
    assert.ok(compared > 100000);
  },
);
test("occlusion recovery retains the settling burst and restores only after a stable uncovered sample", () => {
  const t = new CloakTransition();
  t.begin(0);
  assert.equal(t.sample(0, true), 1);
  assert.equal(t.sample(16, true), 0);
  assert.equal(t.active, true);
  assert.equal(t.sample(32, false), 0);
  assert.equal(t.sample(63, false), 0);
  assert.equal(t.sample(64, false), -1);
  assert.equal(t.active, false);
  assert.equal(t.cloaked, false);
});
test("exit-once checks HWND, PID and exact 64-bit creation ticks; desktop pause waits for explicit resume", () => {
  const host = {
      handle: 123,
      pid: 44,
      started: "639285889726264264",
      visible: true,
    },
    pause = { host: 123, hostPid: 44, hostStarted: "639285889726264264" };
  assert.equal(sessionPaused(pause, [host]), true);
  assert.equal(
    sessionPaused(pause, [{ ...host, started: "639285889726264265" }]),
    false,
  );
  assert.equal(sessionPaused(pause, [{ ...host, pid: 45 }]), false);
  assert.equal(sessionPaused({ desktop: true }, []), true);
  assert.equal(
    shouldLaunch({
      hosts: [host],
      settings: { followHost: true },
      pause,
      running: false,
      pending: false,
      now: 100,
      nextLaunch: 0,
    }),
    false,
  );
  assert.equal(
    shouldLaunch({
      hosts: [],
      settings: { followHost: false },
      pause: null,
      running: false,
      pending: false,
      now: 100,
      nextLaunch: 0,
    }),
    true,
  );
});
test("legacy numeric tick serialization is recovered without JavaScript precision loss", (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "gpt-js-pause-")),
    file = path.join(dir, "pause.json");
  t.after(() => {
    if (!path.resolve(dir).startsWith(path.resolve(os.tmpdir()) + path.sep))
      throw Error("Unexpected cleanup");
    fs.rmSync(dir, { recursive: true, force: true });
  });
  fs.writeFileSync(file, '{"host":123,"hostStarted":639285889726264264}');
  assert.equal(readPause(file).hostStarted, "639285889726264264");
});
