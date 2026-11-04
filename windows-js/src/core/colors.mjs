import { normalizeQuotes } from './quote-values.mjs';
export const palettes = {
  rainbow: ["#D773AD", "#9A79DC", "#579DCF", "#43AE94", "#DBA15C", "#D773AD"],
  creeper: ["#45986A", "#90A84B", "#58A897", "#749E69", "#B3AA54", "#45986A"],
  token: ["#D39B28", "#E97869", "#C9609E", "#956CDA", "#E49B41", "#D39B28"],
  deepsea: ["#368CCA", "#37B5BD", "#548BE0", "#826BC5", "#47B2CC", "#368CCA"],
  claude: ["#C17A4C", "#D89864", "#CA776B", "#B06F96", "#DEAA70", "#C17A4C"],
  gemini: ["#507BDB", "#8370E4", "#BE74CF", "#529AD9", "#57B5B2", "#507BDB"],
};
export class Colors {
  constructor(settings, triggers = ["Token来，Token来"], random = Math.random) {
    this.settings = settings;
    this.triggers = triggers;
    this.random = random;
    this.key = "";
    this.scope = "none";
  }
  get triggers() { return this.triggerQuotes; }
  set triggers(value) {
    this.triggerQuotes=normalizeQuotes(value??['Token来，Token来']).map(row=>row.text);
    this.triggerKeys=new Set(this.triggerQuotes.map(text=>text.toLocaleLowerCase()));
  }
  scene(scene) {
    const s = this.settings,
      key = scene.revision + "|" + scene.text;
    if (this.key !== key) {
      this.key = key;
      this.roll = this.random();
    }
    let scope = "none";
    if (s.colorMode === "mixed") {
      if (!scene.collapsed && scene.mode === "quote")
        scope =
          this.roll < s.colorChance / 100
            ? "full"
            : this.roll < (s.colorChance + s.colorTextChance) / 100
              ? "text"
              : "none";
    } else if (["linked", "rainbow"].includes(s.colorMode)) scope = "full";
    else if (
      s.colorMode !== "original" &&
      !scene.collapsed &&
      scene.mode === "quote"
    ) {
      const special = this.triggerKeys.has(String(scene.text??'').toLocaleLowerCase());
      scope = (
        s.colorMode === "special"
          ? special
          : (s.colorMode === "surprise" && special) ||
            this.roll < s.colorChance / 100
      )
        ? "full"
        : "none";
    }
    const text = scene.text ?? "";
    const name =
      s.colorMode === "rainbow" || scene.mode !== "quote"
        ? "rainbow"
        : resolvePalette(text);
    return { scope, palette: palettes[name], paused: s.colorPaused };
  }
}
export function resolvePalette(text) {
  if (
    [
      /Claude|克劳德/i,
      /Gemini|双子/i,
      /DeepSeek|鲸|肥鱼|白饭/i,
      /GPT|ChatGPT/i,
    ].filter((p) => p.test(text)).length >= 2
  )
    return "rainbow";
  for (const [name, pattern] of [
    ["claude", /Claude|克劳德|压缩|失忆|重构/i],
    ["gemini", /Gemini|双子|吃醋|竞品/i],
    ["deepsea", /DeepSeek|鲸|肥鱼|白饭|接住|等等/i],
    ["creeper", /苦力怕|甘蔗|土豆|打怪|存档|嘶——|屠龙/i],
    ["token", /token|额度|余额|充值/i],
  ])
    if (pattern.test(text)) return name;
  return "rainbow";
}
