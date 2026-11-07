let draft = null,
  saved = null,
  dirty = false,
  selectedId = "",
  provider = "*";
const number = (value) =>
  typeof value === "number" && Number.isFinite(value)
    ? value.toLocaleString("zh-CN")
    : "—";
const name = (value) => (value === "unknown" ? "日志未标注" : value);
const costs = (value) =>
  value?.amounts?.length
    ? value.amounts
        .map((row) => `${row.currency === "CNY" ? "¥" : "$"}${row.amount}`)
        .join(" + ")
    : value?.unpricedTokens
      ? "未设单价"
      : "暂无费用记录";
export function buildUsage({ el, button, command }, state) {
  const usage = state.usage ?? {},
    snapshot = usage.snapshot,
    prefs = usage.preferences ?? { codexHome: null, rules: [] },
    signature = JSON.stringify(prefs);
  if (!draft || (!dirty && signature !== saved)) {
    draft = structuredClone(prefs);
    saved = signature;
    dirty = false;
  }
  const top = el("div");
  top.className = "usage-heading";
  el("h2", "用量与记账", top);
  el(
    "p",
    "本地 token 用量与费用估算；不代表订阅额度百分比或平台账单。",
    top,
  ).className = "hint";
  const source = el("div");
  source.className = "usage-source";
  el("strong", "Codex 数据目录", source);
  el("div", snapshot?.home ?? "正在识别…", source).className = "usage-path";
  const actions = el("div", undefined, source);
  actions.className = "actions";
  button("选择目录…", "usage-folder", undefined, actions);
  button("恢复自动识别", "usage-home-auto", undefined, actions);
  el(
    "p",
    "可使用不同名称、中文或带空格的目录。仅读取所选目录的日志，不混合其他账号目录。",
    source,
  ).className = "hint";
  if (usage.error) el("p", usage.error).className = "usage-warning";
  if (!snapshot) {
    el("p", "正在读取本地用量…").className = "hint";
    return;
  }
  if (snapshot.scanning)
    el("p", "正在补读历史记录，累计数据仍在更新…").className = "usage-warning";
  if (!snapshot.sourceFiles)
    el(
      "p",
      "尚未找到对话日志。可选择正确的数据目录，或先在 Codex 中进行一次对话。",
    ).className = "hint";
  selectedId = snapshot.selectedId ?? selectedId;
  provider = snapshot.provider ?? provider;
  const selectRow = el("div");
  selectRow.className = "usage-filters";
  const select = (title, options, value, onchange) => {
    const label = el("label", title, selectRow),
      input = el("select", undefined, label);
    for (const [id, text] of options) {
      const option = el("option", text, input);
      option.value = id;
    }
    input.value = value;
    input.onchange = () => onchange(input.value);
    return input;
  };
  const choose = () => command("usage-select", { id: selectedId, provider });
  select(
    "服务商",
    [["*", "全部服务商"], ...snapshot.providers.map((p) => [p, name(p)])],
    provider,
    (value) => {
      provider = value;
      selectedId = "";
      void choose();
    },
  ).dataset.focusKey = "usage:provider";
  const threads = [
    ["", "自动跟随最近活动对话"],
    ...snapshot.threads.map((row) => [
      row.id,
      `${row.title || "对话 " + row.id.slice(0, 8)} · ${name(row.model)}`,
    ]),
  ];
  select("对话", threads, selectedId, (value) => {
    selectedId = value;
    void choose();
  }).dataset.focusKey = "usage:thread";
  const cards = el("div");
  cards.className = "usage-cards";
  const card = (title, tokens, cost) => {
    const box = el("section", undefined, cards);
    el("h3", title, box);
    el(
      "strong",
      tokens
        ? number(tokens.input + tokens.output) + " tokens"
        : "暂无可靠计数",
      box,
    );
    if (tokens)
      el(
        "p",
        `输入 ${number(tokens.input)} · 输出 ${number(tokens.output)} · 缓存读取 ${number(tokens.cached)}`,
        box,
      ).className = "hint";
    if (cost) {
      el("div", "估算 " + costs(cost), box).className = "usage-cost";
      if (cost.unpricedTokens)
        el(
          "div",
          `${number(cost.unpricedTokens)} tokens 尚未配置单价`,
          box,
        ).className = "hint";
    }
  };
  card("所选对话累计", snapshot.selected?.total, snapshot.selected?.cost);
  card("所选对话最近一轮", snapshot.selected?.turnUsage, null);
  card("今日已记录", snapshot.today, snapshot.today.cost);
  card("账本累计", snapshot.all, snapshot.all.cost);
  if (snapshot.selected?.missingBaseline || snapshot.selected?.counterReset)
    el(
      "p",
      "这条日志包含继承用量或计数重置；无法验证的部分没有计入费用。",
    ).className = "usage-warning";
  el(
    "p",
    "对话卡片显示该对话自身计数。账本包含已读到的子代理请求；复制或派生日志中的重复用量只记一次。输入已包含缓存，输出已包含推理，不会重复相加。",
  ).className = "hint";
  const price = el("section");
  price.className = "usage-prices";
  el("h3", "第三方 API 单价", price);
  el(
    "p",
    "单位：每百万 tokens。按服务商和模型匹配，* 表示通用；缓存项留空按普通输入单价。价格请以你的平台为准。",
    price,
  ).className = "hint";
  const rows = el("div", undefined, price);
  const rerender = () => {
    rows.replaceChildren();
    for (const [index, rule] of draft.rules.entries()) {
      const row = el("div", undefined, rows);
      row.className = "usage-price-row";
      for (const [key, title] of [
        ["provider", "服务商"],
        ["model", "模型"],
        ["input", "普通输入"],
        ["cached", "缓存读取"],
        ["cacheWrite", "缓存写入"],
        ["output", "输出"],
      ]) {
        const label = el("label", title, row),
          input = el("input", undefined, label);
        input.value = rule[key] ?? "";
        input.dataset.focusKey = `usage:price:${index}:${key}`;
        input.maxLength = key === "provider" || key === "model" ? 160 : 20;
        if (!["provider", "model"].includes(key)) input.inputMode = "decimal";
        input.oninput = () => {
          draft.rules[index][key] = input.value;
          dirty = true;
        };
      }
      const label = el("label", "币种", row),
        currency = el("select", undefined, label);
      for (const value of ["CNY", "USD"]) {
        const option = el("option", value, currency);
        option.value = value;
      }
      currency.value = rule.currency;
      currency.dataset.focusKey = `usage:price:${index}:currency`;
      currency.onchange = () => {
        rule.currency = currency.value;
        dirty = true;
      };
      const remove = el("button", "移除", row);
      remove.type = "button";
      remove.onclick = () => {
        draft.rules.splice(index, 1);
        dirty = true;
        rerender();
      };
    }
  };
  rerender();
  const priceActions = el("div", undefined, price);
  priceActions.className = "actions";
  const add = el("button", "添加单价", priceActions);
  add.type = "button";
  add.dataset.action = "usage-add-price";
  add.onclick = () => {
    if (draft.rules.length >= 100) return;
    draft.rules.push({
      provider: "*",
      model: "*",
      currency: "CNY",
      input: "",
      cached: "",
      cacheWrite: "",
      output: "",
    });
    dirty = true;
    rerender();
  };
  const save = el("button", "保存单价", priceActions);
  save.type = "button";
  save.dataset.action = "usage-save";
  save.onclick = async () => {
    save.disabled = true;
    try {
      const result = await command("usage-save", structuredClone(draft));
      if (result) {
        dirty = false;
        draft = null;
      }
    } finally {
      if (save.isConnected) save.disabled = false;
    }
  };
  el(
    "p",
    "费用仅按日志和自定义单价估算；平台折扣、倍率、退款、计费取整和日志未记录的请求不在其中。不会读取或上传 API 密钥。",
    price,
  ).className = "hint";
  button("关闭", "close-panel");
}
export function usageDraftState() {
  return { dirty, rules: draft?.rules.length ?? 0 };
}
