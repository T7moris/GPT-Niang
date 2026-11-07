import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { UsageLedger } from "../src/core/usage-ledger.mjs";
function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "gpt-usage-ledger-")),
    ledgers = [];
  t.after(() => {
    for (const ledger of ledgers) ledger.close();
    assert.equal(path.dirname(root), path.resolve(os.tmpdir()));
    fs.rmSync(root, { recursive: true, force: true });
  });
  const home = path.join(root, "任意名称 & (账号 A)"),
    dataDir = path.join(root, "state");
  fs.mkdirSync(path.join(home, "sessions"), { recursive: true });
  return {
    root,
    home,
    dataDir,
    track: (ledger) => {
      ledgers.push(ledger);
      return ledger;
    },
  };
}
const stamp = "2026-11-05T05:00:00.000Z";
const header = (id) => ({
  type: "session_meta",
  payload: { id, model_provider: "relay", source: "cli" },
});
const context = {
  type: "turn_context",
  payload: { model: "model-a", turn_id: "turn-a" },
};
const usage = (input = 1000, output = 100) => ({
  type: "event_msg",
  timestamp: stamp,
  payload: {
    type: "token_count",
    info: {
      total_token_usage: {
        input_tokens: input,
        cached_input_tokens: input / 2,
        output_tokens: output,
      },
      last_token_usage: {
        input_tokens: input,
        cached_input_tokens: input / 2,
        output_tokens: output,
      },
    },
  },
});
const write = (file, ...records) =>
  fs.writeFileSync(
    file,
    records.map((row) => JSON.stringify(row)).join("\n") + "\n",
  );
test("SQLite ledger deduplicates fork history, resumes after restart, and follows archive moves", (t) => {
  const f = fixture(t),
    file = path.join(f.home, "sessions/a.jsonl"),
    fork = path.join(f.home, "sessions/b.jsonl");
  write(file, header("a"), context, usage());
  write(fork, header("b"), context, usage());
  let ledger = f.track(
    new UsageLedger({ dataDir: f.dataDir, codexHome: f.home }),
  );
  ledger.scan();
  let snapshot = ledger.snapshot();
  assert.equal(snapshot.all.input, 1000);
  assert.equal(snapshot.threads.length, 2);
  ledger.close();
  fs.mkdirSync(path.join(f.home, "archived_sessions"));
  fs.renameSync(file, path.join(f.home, "archived_sessions/a.jsonl"));
  ledger = f.track(new UsageLedger({ dataDir: f.dataDir, codexHome: f.home }));
  ledger.scan();
  snapshot = ledger.snapshot();
  assert.equal(snapshot.all.input, 1000);
  assert.equal(snapshot.threads.length, 2);
  fs.appendFileSync(
    fork,
    JSON.stringify({
      ...usage(2000, 200),
      timestamp: "2026-11-05T05:01:00.000Z",
    }) + "\n",
  );
  ledger.scan();
  assert.equal(ledger.snapshot().all.input, 2000);
});
test("partial records commit only after a newline; message bodies and auth files are absent from the ledger", (t) => {
  const f = fixture(t),
    file = path.join(f.home, "sessions/a.jsonl");
  write(file, header("a"), context, {
    type: "event_msg",
    payload: { type: "user_message", message: "PRIVATE_PROMPT_DO_NOT_PERSIST" },
  });
  fs.writeFileSync(path.join(f.home, "auth.json"), "PRIVATE_KEY_DO_NOT_READ");
  fs.appendFileSync(file, JSON.stringify(usage()));
  const ledger = new UsageLedger({ dataDir: f.dataDir, codexHome: f.home });
  ledger.scan();
  assert.equal(ledger.snapshot().all.input, 0);
  fs.appendFileSync(file, "\n");
  ledger.scan();
  assert.equal(ledger.snapshot().all.input, 1000);
  ledger.close();
  const bytes = fs.readFileSync(path.join(f.dataDir, "usage-ledger.sqlite"));
  assert.equal(bytes.includes("PRIVATE_PROMPT_DO_NOT_PERSIST"), false);
  assert.equal(bytes.includes("PRIVATE_KEY_DO_NOT_READ"), false);
});
test("different home names and profiles share one compact database without mixing their records", (t) => {
  const f = fixture(t),
    other = path.join(f.root, "另一个名字");
  fs.mkdirSync(path.join(other, "sessions"), { recursive: true });
  write(path.join(f.home, "sessions/a.jsonl"), header("a"), context, usage());
  write(
    path.join(other, "sessions/b.jsonl"),
    header("b"),
    context,
    usage(4000, 400),
  );
  for (const [home, expected] of [
    [f.home, 1000],
    [other, 4000],
    [f.home, 1000],
  ]) {
    const ledger = new UsageLedger({ dataDir: f.dataDir, codexHome: home });
    ledger.scan();
    assert.equal(ledger.snapshot().all.input, expected);
    ledger.close();
  }
  assert.deepEqual(fs.readdirSync(f.dataDir), ["usage-ledger.sqlite"]);
});
test("chat titles come from the selected home index in read-only mode", (t) => {
  const f = fixture(t),
    indexPath = path.join(f.home, "state_99.sqlite"),
    index = new DatabaseSync(indexPath);
  index.exec(
    "CREATE TABLE threads(id TEXT,title TEXT,updated_at INTEGER);INSERT INTO threads VALUES('a','可辨认的聊天标题',123)",
  );
  index.close();
  const before = fs.readFileSync(indexPath);
  write(path.join(f.home, "sessions/a.jsonl"), header("a"), context, usage());
  const ledger = f.track(
    new UsageLedger({ dataDir: f.dataDir, codexHome: f.home }),
  );
  ledger.scan();
  assert.equal(ledger.snapshot().threads[0].title, "可辨认的聊天标题");
  assert.deepEqual(fs.readFileSync(indexPath), before);
});
test("bounded scans make progress across many independent chats and oversized message lines", (t) => {
  const f = fixture(t);
  for (let n = 0; n < 40; n++)
    write(
      path.join(f.home, "sessions", n + ".jsonl"),
      header("chat-" + n),
      { ...context, payload: { ...context.payload, turn_id: "turn-" + n } },
      usage(),
      {
        type: "event_msg",
        payload: { type: "user_message", message: "x".repeat(2000) },
      },
    );
  const ledger = f.track(
    new UsageLedger({ dataDir: f.dataDir, codexHome: f.home }),
  );
  for (let n = 0; n < 100; n++) {
    ledger.scan({ budget: 4096 });
    if (ledger.snapshot().all.input === 40000 && ledger.pendingBytes === 0)
      break;
  }
  assert.equal(ledger.snapshot().all.input, 40000);
  assert.equal(ledger.pendingBytes, 0);
  const giant = path.join(f.home, "sessions/giant.jsonl");
  write(
    giant,
    header("giant"),
    {
      type: "event_msg",
      payload: { type: "user_message", message: "PRIVATE_BODY".repeat(200000) },
    },
    { ...context, payload: { ...context.payload, turn_id: "giant-turn" } },
    usage(),
  );
  for (let n = 0; n < 8; n++) ledger.scan({ now: Date.now() + 2000 + n });
  assert.equal(ledger.snapshot().all.input, 41000);
  assert.ok(
    fs.statSync(path.join(f.dataDir, "usage-ledger.sqlite")).size < 250000,
  );
});
