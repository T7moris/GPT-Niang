import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { readJson, writeJson, inside } from "./storage.mjs";
import { normalizeWave } from "../../runtime/audio-import.mjs";
function validPreferences(p) {
  return !!p && typeof p === "object" && !Array.isArray(p) &&
    p.version === 1 && ["builtin", "custom"].includes(p.mode) &&
    ["press", "release"].every((s) => p[s] == null ||
      (typeof p[s] === "object" && /^[a-f0-9]{32}\.wav$/.test(p[s].file) &&
       typeof p[s].name === "string" && p[s].name.length <= 255));
}
function savedPreferences(file) {
  try {
    if (fs.statSync(file).size > 16384) return null;
    const value = readJson(file);
    return validPreferences(value) ? value : null;
  } catch { return null; }
}
export class AudioStore {
  constructor(appDir, dataDir) {
    this.assets = path.join(appDir, "assets");
    this.dataDir = dataDir;
    this.file = path.join(dataDir, "audio-preferences.json");
    this.reload();
  }
  reload() {
    const defaults = {
      version: 1,
      mode: "builtin",
      press: null,
      release: null,
    };
    if (!fs.existsSync(this.file)) {
      this.preferences = defaults;
      return;
    }
    const p = readJson(this.file);
    if (fs.statSync(this.file).size > 16384 || !validPreferences(p)) {
      this.preferences = {
        ...defaults,
        mode: "custom",
        loadError: "音效设置无法读取，请重新选择音效。",
      };
      return;
    }
    this.preferences = { ...defaults, ...p };
  }
  save(value = this.preferences) {
    const { loadError, ...p } = value;
    const previousBackup = savedPreferences(this.file + ".bak");
    writeJson(this.file, p);
    this.preferences = p;
    // Only a superseded, valid backup can nominate a file for retirement.
    // Never sweep unrelated files; retain every current and backup reference.
    try {
      const backup = savedPreferences(this.file + ".bak");
      if (!previousBackup || !backup) return;
      const directory = path.join(this.dataDir, "sounds"),
        keep = new Set([p.press?.file, p.release?.file, backup.press?.file, backup.release?.file]);
      for (const name of new Set([previousBackup.press?.file, previousBackup.release?.file]))
        if (typeof name === "string" && /^[a-f0-9]{32}\.wav$/.test(name) && !keep.has(name))
          try { fs.unlinkSync(inside(directory, name)); } catch {}
    } catch {} // A cleanup failure cannot invalidate a committed preference.
  }
  mode(value) {
    if (!["builtin", "custom"].includes(value)) throw Error("无效的音效模式");
    this.save({ ...this.preferences, mode: value });
  }
  clear(slot) {
    checkSlot(slot);
    this.save({ ...this.preferences, mode: "custom", [slot]: null });
  }
  import(slot, source) {
    checkSlot(slot);
    if (fs.statSync(source).size > 10 * 1024 * 1024)
      throw Error("音效文件超过10MiB。");
    let normalized;
    try {
      normalized = normalizeWave(fs.readFileSync(source));
    } catch (error) {
      throw Error(
        {
          too_long: "音效超过5秒，请选择不超过5秒的文件。",
          too_large: "音效文件超过10MiB，请选择较小的文件。",
          unsupported: "不支持这种WAV编码，请选择其他音效文件。",
          io: "无法读取或保存音效，请检查文件和个人目录。",
        }[error.code] ?? "WAV文件损坏或不完整，无法导入。",
      );
    }
    const file = randomUUID().replaceAll("-", "") + ".wav",
      dir = path.join(this.dataDir, "sounds");
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(inside(dir, file), normalized.bytes);
    try {
      this.save({
        ...this.preferences,
        mode: "custom",
        [slot]: { file, name: path.basename(source).slice(0, 255) },
      });
    } catch (error) {
      fs.unlinkSync(inside(dir, file));
      throw error;
    }
  }
  payload() {
    const slots = {},
      previewSlots = {},
      load = (file) =>
        file
          ? (() => {
              if (fs.statSync(file).size > 10 * 1024 * 1024)
                throw Error("音效文件超过10MiB。");
              return (
                "data:audio/wav;base64," +
                fs.readFileSync(file).toString("base64")
              );
            })()
          : null;
    const errors = {};
    for (const slot of ["press", "release"]) {
      try {
        const custom = this.preferences[slot]
          ? inside(
              path.join(this.dataDir, "sounds"),
              this.preferences[slot].file,
            )
          : null;
        previewSlots[slot] = load(custom);
      } catch {
        previewSlots[slot] = null;
        errors[slot] = "自定义音效无法读取，请重新选择文件。";
      }
      try {
        slots[slot] =
          this.preferences.mode === "builtin"
            ? load(path.join(this.assets, slot + ".wav"))
            : previewSlots[slot];
      } catch {
        slots[slot] = null;
      }
    }
    return {
      preferences: { ...this.preferences, errors },
      slots,
      previewSlots,
    };
  }
}
function checkSlot(slot) {
  if (!["press", "release"].includes(slot)) throw Error("无效的音效位置");
}
