import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import { listRolloutFiles } from "../../runtime/completion-monitor.mjs";
import {readSessionMetadata} from '../../runtime/session-header.mjs';
import {
  newUsageState,
  acceptUsageRecord,
  localDay,
} from "../../runtime/session-usage.mjs";
import { estimateCost } from "./usage-pricing.mjs";
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const identity = (stat) => `${stat.dev}:${stat.ino}`;
function header(file) {
  const result=readSessionMetadata(file),id=result.metadata?.id;
  if(result.status!=='ok'||typeof id!=='string'||!id||id.length>200)return null;
  return {id,metadata:result.metadata};
}
function boundary(file, offset) {
  if (!offset) return "";
  let fd;
  try {
    fd = fs.openSync(file, "r");
    const length = Math.min(64, offset),
      bytes = Buffer.alloc(length);
    return fs.readSync(fd, bytes, 0, length, offset - length) === length
      ? hash(bytes)
      : null;
  } catch {
    return null;
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}
const sumColumns =
  "SUM(input) input,SUM(cached) cached,SUM(cache_write) cacheWrite,SUM(output) output,SUM(reasoning) reasoning";
export class UsageLedger {
  constructor({ dataDir, codexHome }) {
    this.home = path.resolve(codexHome);
    this.scope =
      process.platform === "win32" ? this.home.toLowerCase() : this.home;
    fs.mkdirSync(dataDir, { recursive: true });
    this.db = new DatabaseSync(path.join(dataDir, "usage-ledger.sqlite"));
    this.db
      .exec(`PRAGMA busy_timeout=1500;PRAGMA journal_mode=DELETE;PRAGMA synchronous=NORMAL;
   CREATE TABLE IF NOT EXISTS files(home TEXT NOT NULL,id TEXT NOT NULL,path TEXT NOT NULL,identity TEXT NOT NULL,offset INTEGER NOT NULL,boundary TEXT NOT NULL,state TEXT NOT NULL,updated INTEGER NOT NULL,PRIMARY KEY(home,id));
   CREATE INDEX IF NOT EXISTS files_path ON files(home,path);
   CREATE TABLE IF NOT EXISTS events(home TEXT NOT NULL,id TEXT NOT NULL,thread TEXT NOT NULL,provider TEXT NOT NULL,model TEXT NOT NULL,day TEXT NOT NULL,input INTEGER NOT NULL,cached INTEGER NOT NULL,cache_write INTEGER NOT NULL,output INTEGER NOT NULL,reasoning INTEGER NOT NULL,PRIMARY KEY(home,id));
   CREATE INDEX IF NOT EXISTS events_thread ON events(home,thread);
   CREATE INDEX IF NOT EXISTS events_day ON events(home,day);`);
    this.byPath = this.db.prepare(
      "SELECT * FROM files WHERE home=? AND path=?",
    );
    this.byId = this.db.prepare("SELECT * FROM files WHERE home=? AND id=?");
    this.save = this.db.prepare(
      "INSERT INTO files VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(home,id) DO UPDATE SET path=excluded.path,identity=excluded.identity,offset=excluded.offset,boundary=excluded.boundary,state=excluded.state,updated=excluded.updated",
    );
    this.add = this.db.prepare(
      "INSERT OR IGNORE INTO events VALUES(?,?,?,?,?,?,?,?,?,?,?)",
    );
    this.paths = [];
    this.discoveredAt = 0;
    this.cursor = 0;
    this.pendingBytes = 0;
    this.error = null;
    this.closed = false;
    this.titles = new Map();
    this.titlesAt = 0;
  }
  scan({ budget = 4 * 1024 * 1024, now = Date.now() } = {}) {
    if (this.closed) return;
    if (now - this.discoveredAt >= 1000 || !this.discoveredAt) {
      this.paths = listRolloutFiles(this.home)
        .map((file) => {
          try {
            return { file, stat: fs.statSync(file) };
          } catch {
            return null;
          }
        })
        .filter(Boolean)
        .sort((a, b) => b.stat.mtimeMs - a.stat.mtimeMs);
      this.discoveredAt = now;
      this.cursor %= Math.max(1, this.paths.length);
    }
    let remaining = budget,
      pending = 0;
    const deadline = Date.now() + 100;
    let nextCursor = this.cursor;
    for (let step = 0; step < this.paths.length; step++) {
      const index = (this.cursor + step) % this.paths.length,
        { file } = this.paths[index];
      let stat;
      try {
        stat = fs.statSync(file);
      } catch {
        continue;
      }
      let row = this.byPath.get(this.scope, file),
        initial;
      if (remaining <= 0 || Date.now() > deadline) {
        pending += Math.max(0, stat.size - (row?.offset ?? 0));
        continue;
      }
      nextCursor = (index + 1) % this.paths.length;
      if (!row) {
        initial = header(file);
        if (!initial) continue;
        row = this.byId.get(this.scope, initial.id);
      }
      let state,
        offset = 0;
      if (row) {
        try {
          state = JSON.parse(row.state);
        } catch {}
        const verified = boundary(file, row.offset) === row.boundary;
        if (
          state &&
          row.identity === identity(stat) &&
          stat.size >= row.offset &&
          verified
        ) {
          offset = row.offset;
        } else state = null;
      }
      if (!state) {
        initial ??= header(file);
        if (!initial) continue;
        state = newUsageState(initial.id, initial.metadata);
      }
      if (stat.size <= offset) continue;
      if (remaining <= 0 || Date.now() > deadline) {
        pending += stat.size - offset;
        continue;
      }
      const amount = Math.min(stat.size - offset, remaining, 1024 * 1024),
        bytes = Buffer.alloc(amount);
      let fd, count;
      try {
        fd = fs.openSync(file, "r");
        count = fs.readSync(fd, bytes, 0, amount, offset);
      } catch {
        continue;
      } finally {
        if (fd !== undefined) fs.closeSync(fd);
      }
      remaining -= count;
      const chunk = bytes.subarray(0, count),
        last = chunk.lastIndexOf(10);
      let consumed = last + 1;
      if (!consumed) {
        // Do not store partial message bodies in the database. Oversized lines are
        // skipped as bytes; valid small accounting records after them still work.
        if (count === 1024 * 1024) {
          state.discardLine = true;
          consumed = count;
        } else continue;
      }
      const events = [],
        lines =
          last < 0
            ? []
            : chunk.subarray(0, consumed).toString("utf8").split("\n");
      lines.pop();
      for (const line of lines) {
        if (state.discardLine) {
          state.discardLine = false;
          continue;
        }
        if (
          line.length > 1024 * 1024 ||
          !/(?:token_count|turn_context|session_meta|task_started|task_complete|turn_complete|turn_aborted)/.test(
            line,
          )
        )
          continue;
        try {
          const event = acceptUsageRecord(state, JSON.parse(line));
          if (event) events.push(event);
        } catch {}
      }
      offset += consumed;
      const proof = boundary(file, offset);
      if (proof === null) continue;
      this.db.exec("BEGIN IMMEDIATE");
      try {
        for (const e of events)
          this.add.run(
            this.scope,
            e.id,
            e.thread,
            e.provider,
            e.model,
            e.day,
            e.input,
            e.cached,
            e.cacheWrite,
            e.output,
            e.reasoning,
          );
        this.save.run(
          this.scope,
          state.id,
          file,
          identity(stat),
          offset,
          proof,
          JSON.stringify(state),
          Math.max(state.at || 0, stat.mtimeMs),
        );
        this.db.exec("COMMIT");
      } catch (error) {
        this.db.exec("ROLLBACK");
        throw error;
      }
      pending += stat.size - offset;
    }
    this.cursor = nextCursor;
    this.pendingBytes = pending;
  }
  snapshot({ rules = [], selectedId = "", provider = "*" } = {}) {
    if (Date.now() - this.titlesAt > 5000) {
      this.titlesAt = Date.now();
      let index;
      try {
        const names = fs
          .readdirSync(this.home)
          .filter((name) => /^state_\d+\.sqlite$/.test(name))
          .sort(
            (a, b) => Number(b.match(/\d+/)[0]) - Number(a.match(/\d+/)[0]),
          );
        if (names.length) {
          index = new DatabaseSync(path.join(this.home, names[0]), {
            readOnly: true,
          });
          index.exec("PRAGMA busy_timeout=50");
          this.titles = new Map(
            index
              .prepare(
                "SELECT id,title FROM threads ORDER BY updated_at DESC LIMIT 500",
              )
              .all()
              .map((row) => [
                row.id,
                String(row.title ?? "")
                  .replace(/[\x00-\x1f\x7f]/g, "")
                  .slice(0, 160),
              ]),
          );
        }
      } catch {
      } finally {
        index?.close();
      }
    }
    const rows = this.db
      .prepare(
        `SELECT state FROM files WHERE home=? AND json_extract(state,'$.subagent')!=1 ${provider === "*" ? "" : "AND json_extract(state,'$.provider')=?"} ORDER BY updated DESC LIMIT 200`,
      )
      .all(this.scope, ...(provider === "*" ? [] : [provider]))
      .map((row) => {
        try {
          const state = JSON.parse(row.state);
          return { ...state, title: this.titles.get(state.id) || state.title };
        } catch {
          return null;
        }
      })
      .filter(Boolean);
    const threads = rows.filter(
      (row) => !row.subagent && (provider === "*" || row.provider === provider),
    );
    const selected =
      (selectedId ? rows.find((row) => row.id === selectedId) : null) ??
      threads[0] ??
      null;
    const group = (extra = "", args = []) =>
      this.db
        .prepare(
          `SELECT provider,model,${sumColumns} FROM events WHERE home=? ${provider === "*" ? "" : "AND provider=?"} ${extra} GROUP BY provider,model`,
        )
        .all(this.scope, ...(provider === "*" ? [] : [provider]), ...args);
    const all = group(),
      today = group("AND day=?", [localDay()]),
      detail = selected ? group("AND thread=?", [selected.id]) : [];
    const totals = (list) =>
      list.reduce(
        (result, row) => {
          for (const key of [
            "input",
            "cached",
            "cacheWrite",
            "output",
            "reasoning",
          ])
            result[key] += row[key];
          return result;
        },
        { input: 0, cached: 0, cacheWrite: 0, output: 0, reasoning: 0 },
      );
    return {
      at: Date.now(),
      home: this.home,
      scanning: this.pendingBytes > 0,
      pendingBytes: this.pendingBytes,
      sourceFiles: this.paths.length,
      providers: this.db
        .prepare(
          "SELECT DISTINCT provider FROM events WHERE home=? ORDER BY provider",
        )
        .all(this.scope)
        .map((row) => row.provider),
      provider,
      selectedId,
      threads: threads.map(
        ({ id, title, at, provider, model, total, phase }) => ({
          id,
          title,
          at,
          provider,
          model,
          total,
          phase,
        }),
      ),
      selected: selected
        ? { ...selected, cost: estimateCost(detail, rules) }
        : null,
      all: { ...totals(all), cost: estimateCost(all, rules) },
      today: { ...totals(today), cost: estimateCost(today, rules) },
      error: this.error,
    };
  }
  close() {
    if (!this.closed) {
      this.closed = true;
      this.db.close();
      this.paths = [];
    }
  }
}
