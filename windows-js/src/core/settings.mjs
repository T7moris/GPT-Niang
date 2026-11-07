import { readJson, writeJson } from "./storage.mjs";
import {validAutoQuoteSeconds} from './auto-quote-interval.mjs';
export const defaults = Object.freeze({
  layoutVersion: 2,
  right: 0,
  left: null,
  bottom: 0,
  anchor: "right",
  side: "right",
  scale: 1,
  bubbleScale: 1,
  collapsed: true,
  soundOn: true,
  soundVolume: 0.9,
  bubbleTapAdvance: false,
  characterQuoteRepeat: false,
  hideMenu: false,
  colorMode: "mixed",
  colorChance: 0.5,
  colorTextChance: 3,
  colorPaused: false,
  followHost: true,
  desktopTopmost: false,
  desktopLeft: null,
  desktopTop: null,
  characterId: "gpt-dragon",
  autoQuoteEnabled: false,
  autoQuoteIntervalSeconds: 300,
  taskCompletionBubble: false,
});
const finite = (value, limit = 100000) =>
  value !== null &&
  value !== "" &&
  Number.isFinite(Number(value)) &&
  Math.abs(Number(value)) <= limit;
export function normalizeSettings(saved) {
  const s = { ...defaults };
  if (!saved || typeof saved !== "object" || Array.isArray(saved)) return s;
  for (const key of ["right", "bottom", "desktopLeft", "desktopTop"])
    if (finite(saved[key])) s[key] = Number(saved[key]);
  for (const key of ["scale", "bubbleScale"])
    if (Number(saved[key]) >= 0.6 && Number(saved[key]) <= 2.5)
      s[key] = Number(saved[key]);
  if (!(Number(saved.bubbleScale) >= 0.6 && Number(saved.bubbleScale) <= 2.5))
    s.bubbleScale = s.scale;
  const enumValue = value => typeof value === 'string' ? value.toLowerCase() : value;
  if (saved.layoutVersion === 2 || saved.layoutVersion === '2') {
    if (finite(saved.left)) s.left = Number(saved.left);
    if (["left", "right", "free"].includes(enumValue(saved.anchor)))
      s.anchor = enumValue(saved.anchor);
    if (["left", "right"].includes(enumValue(saved.side))) s.side = enumValue(saved.side);
  } else {
    s.bottom = 0;
    if (s.right > 18) s.anchor = "free";
  }
  for (const key of [
    "soundOn",
    "bubbleTapAdvance",
    "characterQuoteRepeat",
    "hideMenu",
    "colorPaused",
    "followHost",
    "desktopTopmost",
  ])
    if (saved[key] != null) s[key] = saved[key] === true;
  for (const key of ["autoQuoteEnabled", "taskCompletionBubble"])
    if (typeof saved[key] === "boolean") s[key] = saved[key];
  if (finite(saved.soundVolume, Number.MAX_VALUE))
    s.soundVolume = Math.max(0, Math.min(1, Number(saved.soundVolume)));
  if (
    [
      "original",
      "linked",
      "rainbow",
      "surprise",
      "rare",
      "special",
      "mixed",
    ].includes(enumValue(saved.colorMode))
  )
    s.colorMode = enumValue(saved.colorMode);
  for (const key of ["colorChance", "colorTextChance"])
    if (
      finite(saved[key]) &&
      Number(saved[key]) >= 0 &&
      Number(saved[key]) <= 30
    )
      s[key] = Number(saved[key]);
  if (validAutoQuoteSeconds(Number(saved.autoQuoteIntervalSeconds)))
    s.autoQuoteIntervalSeconds = Number(saved.autoQuoteIntervalSeconds);
  if (typeof saved.characterId === "string") s.characterId = saved.characterId;
  return s;
}
export class SettingsStore {
  constructor(file) {
    this.file = file;
    this.raw = readJson(file);
    this.loadFailed = this.raw === null;
    this.value = normalizeSettings(this.raw);
  }
  save(patch = {}) {
    const value={...this.value,...patch,layoutVersion:2},raw={...(this.raw||{}),...value};
    if(this.loadFailed||JSON.stringify(raw)!==JSON.stringify(this.raw))writeJson(this.file,raw);
    this.value=value;this.raw=raw;
    this.loadFailed = false;
    return this.value;
  }
}
