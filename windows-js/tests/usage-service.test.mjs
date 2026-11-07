import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { once } from "node:events";
import { UsageService } from "../src/core/usage-service.mjs";
test("accounting worker saves prices, preserves good preferences after errors, and releases SQLite on close", async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "gpt-usage-service-")),
    home = path.join(root, "自定义根目录"),
    dataDir = path.join(root, "data");
  fs.mkdirSync(path.join(home, "sessions"), { recursive: true });
  const service = new UsageService({ dataDir, codexHome: home });
  t.after(() => {
    service.close();
    assert.equal(path.dirname(root), path.resolve(os.tmpdir()));
    fs.rmSync(root, {
      recursive: true,
      force: true,
      maxRetries: 20,
      retryDelay: 50,
    });
  });
  const initial = await service.request("refresh");
  assert.equal(initial.snapshot.home, home);
  const rules = [
    {
      provider: "*",
      model: "*",
      currency: "CNY",
      input: "1",
      cached: "",
      cacheWrite: "",
      output: "2",
    },
  ];
  await service.request("save", { codexHome: null, rules });
  const file = path.join(dataDir, "usage-preferences.json"),
    before = fs.readFileSync(file, "utf8");
  assert.equal(JSON.parse(before).rules[0].cached, "1");
  await assert.rejects(
    service.request("save", {
      codexHome: null,
      rules: [{ ...rules[0], output: "-2" }],
    }),
    /单价/,
  );
  assert.equal(fs.readFileSync(file, "utf8"), before);
  const worker = service.worker,
    exited = once(worker, "exit");
  service.close();
  // Production close deliberately unrefs the worker. This test must keep its
  // exit observable even when Node 22 has no other referenced event-loop work.
  worker.ref();
  await exited;
  assert.equal(service.worker, null);
  assert.equal(service.pending.size, 0);
  assert.ok(
    fs.statSync(path.join(dataDir, "usage-ledger.sqlite")).size < 100000,
  );
});
