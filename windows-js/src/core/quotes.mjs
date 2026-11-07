import fs from "node:fs";
import {validAutoQuoteSeconds} from './auto-quote-interval.mjs';
import path from "node:path";
import { readJson, writeJson } from "./storage.mjs";
import { normalizeQuotes } from './quote-values.mjs';
export { normalizeQuotes, parseQuoteLines } from './quote-values.mjs';
export class QuoteStore {
  constructor(dataDir, assetsDir, random = Math.random) {
    this.custom = path.join(dataDir, "quotes.json");
    this.builtin = path.join(assetsDir, "quotes.json");
    this.random = random;
    this.last = "";
    this.files=new Map();
  }
  readFile(file) {
    const stat=fs.statSync(file,{bigint:true});
    if (stat.size > 1048576n)
      throw new Error("语录文件超过 1 MB，请精简后重试。");
    const revision=stat.size+':'+stat.mtimeNs+':'+stat.ctimeNs,cached=this.files.get(file);
    if(cached?.revision===revision)return cached.rows.map(row=>({...row}));
    const rows = normalizeQuotes(
      JSON.parse(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, "")),
    );
    if (rows.length > 5000)
      throw new Error("语录条数超过 5000，请精简后重试。");
    this.files.set(file,{revision,rows});
    return rows.map(row=>({...row}));
  }
  list() {
    let rows = [],
      error = null,
      source = "built-in";
    if (fs.existsSync(this.custom)) {
      try {
        rows = this.readFile(this.custom);
        if (rows.length) source = "custom";
        else error = "自定义语录没有有效条目，已使用内置语录。";
      } catch {
        error = "自定义语录无法读取，已使用内置语录。";
      }
    }
    if (!rows.length)
      try {
        rows = this.readFile(this.builtin);
      } catch {}
    if (!rows.length) {
      source = "fallback";
      rows = [
        { text: "Ciallo～ 今天也请多关照。", weight: 1 },
        { text: "我在这儿，慢慢来就好。", weight: 1 },
      ];
    }
    return { source, quotes: rows, error };
  }
  next() {
    const { quotes } = this.list();
    let rows = quotes.filter((row) => row.text !== this.last);
    if (!rows.length) rows = quotes;
    let draw = this.random() * rows.reduce((sum, row) => sum + row.weight, 0),
      selected = rows.at(-1);
    for (const row of rows) {
      draw -= row.weight;
      if (draw < 0) {
        selected = row;
        break;
      }
    }
    this.last = selected.text;
    return selected.text;
  }
  save(value) {
    const quotes = normalizeQuotes(value);
    if (!quotes.length)
      throw new Error(
        "请至少填写一条有效语录；每条最多 200 字，权重须大于 0 且不超过 1000。",
      );
    if(quotes.length>5000)throw Error('语录条数超过 5000，请精简后重试。');
    if(Buffer.byteLength(JSON.stringify({version:1,quotes},null,2)+'\n','utf8')>1048576)throw Error('语录文件超过 1 MB，请精简后重试。');
    writeJson(this.custom, { version: 1, quotes });
    return this.list();
  }
  reset() {
    if (fs.existsSync(this.custom)) {
      fs.copyFileSync(this.custom, this.custom + ".bak");
      fs.unlinkSync(this.custom);
      this.files.delete(this.custom);
    }
    return this.list();
  }
}
export class AutoQuoteSchedule {
  constructor(settings, now = Date.now()) {
    this.enabled = settings.autoQuoteEnabled;
    this.seconds = settings.autoQuoteIntervalSeconds;
    this.count = 0;
    this.reset(now);
  }
  reset(now = Date.now()) {
    this.next = this.enabled ? now + this.seconds * 1000 : 0;
    this.last = now;
    this.eligible = false;
  }
  configure(enabled, seconds, now = Date.now()) {
    if (!validAutoQuoteSeconds(seconds))
      throw new Error("自动语录间隔须在 10 秒至 24 小时之间。");
    this.enabled = enabled;
    this.seconds = seconds;
    this.reset(now);
  }
  due(now, visible, busy) {
    const gap = now - this.last,
      restart = this.last <= 0 || !this.eligible || gap < 0 || gap > 5000;
    if (!this.enabled || !visible || busy) {
      this.reset(now);
      return false;
    }
    if (restart) {
      this.reset(now);
      this.eligible = true;
      return false;
    }
    this.last = now;
    if (now < this.next) return false;
    this.next = now + this.seconds * 1000;
    this.count++;
    return true;
  }
}
