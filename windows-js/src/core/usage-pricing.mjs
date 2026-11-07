import path from "node:path";
const text = (value, max) =>
  typeof value === "string" &&
  value.trim().length <= max &&
  !/[\x00-\x1f\x7f]/.test(value)
    ? value.trim()
    : null;
export function priceUnits(value) {
  const raw = typeof value === "number" ? String(value) : value;
  if (typeof raw !== "string" || !/^\d{1,7}(?:\.\d{1,6})?$/.test(raw.trim()))
    throw Error("单价请填写非负数字，最多保留6位小数");
  const [whole, fraction = ""] = raw.trim().split(".");
  return BigInt(whole) * 1000000n + BigInt(fraction.padEnd(6, "0"));
}
export function validateUsagePreferences(value) {
  if (
    !value ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    !Array.isArray(value.rules) ||
    value.rules.length > 100
  )
    throw Error("记账设置无效，最多支持100条单价规则");
  const home = value.codexHome ?? null;
  if (
    home !== null &&
    (typeof home !== "string" ||
      !path.isAbsolute(home) ||
      home.length > 32700 ||
      /[\x00-\x1f]/.test(home))
  )
    throw Error("请使用完整的 Codex 日志目录路径");
  const seen = new Set(),
    rules = value.rules.map((row) => {
      const provider = text(row?.provider, 160),
        model = text(row?.model, 160),
        currency = row?.currency;
      if (!provider || !model || !["CNY", "USD"].includes(currency))
        throw Error("请填写服务商、模型及币种；* 表示通用规则");
      const key = JSON.stringify([provider, model]);
      if (seen.has(key)) throw Error("同一服务商和模型只能保留一条单价规则");
      seen.add(key);
      const rule = { provider, model, currency };
      for (const name of ["input", "cached", "cacheWrite", "output"]) {
        const optional = name === "cached" || name === "cacheWrite";
        const price =
          optional &&
          (row[name] === undefined || row[name] === null || row[name] === "")
            ? row.input
            : row[name];
        priceUnits(price);
        rule[name] = String(price).trim();
      }
      return rule;
    });
  return {
    schema: 1,
    codexHome: home === null ? null : path.resolve(home),
    rules,
  };
}
export const defaultUsagePreferences = () => ({
  schema: 1,
  codexHome: null,
  rules: [],
});
export function matchingPrice(rules, provider, model) {
  return (
    rules
      .filter(
        (rule) =>
          (rule.provider === "*" || rule.provider === provider) &&
          (rule.model === "*" || rule.model === model),
      )
      .sort(
        (a, b) =>
          (b.provider !== "*") * 2 +
          (b.model !== "*") -
          ((a.provider !== "*") * 2 + (a.model !== "*")),
      )[0] ?? null
  );
}
export function formatCost(units) {
  // Token counts times a price in millionths / one million tokens: 1e12
  // denominator. Keep exact integer arithmetic through summation and rounding.
  if (units > 0n && units < 1000000n) return "<0.000001";
  const rounded = (units + 500000n) / 1000000n;
  return (
    String(rounded / 1000000n) +
    "." +
    String(rounded % 1000000n).padStart(6, "0")
  );
}
export function estimateCost(rows, rules) {
  const money = new Map();
  let unpricedTokens = 0;
  for (const row of rows) {
    const rule = matchingPrice(rules, row.provider, row.model);
    if (!rule) {
      unpricedTokens += row.input + row.output;
      continue;
    }
    const charge =
      BigInt(row.input - row.cached - row.cacheWrite) * priceUnits(rule.input) +
      BigInt(row.cached) * priceUnits(rule.cached) +
      BigInt(row.cacheWrite) * priceUnits(rule.cacheWrite) +
      BigInt(row.output) * priceUnits(rule.output);
    money.set(rule.currency, (money.get(rule.currency) ?? 0n) + charge);
  }
  return {
    amounts: [...money].map(([currency, amount]) => ({
      currency,
      amount: formatCost(amount),
    })),
    unpricedTokens,
  };
}
