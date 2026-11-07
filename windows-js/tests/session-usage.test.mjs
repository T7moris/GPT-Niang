import test from "node:test";
import assert from "node:assert/strict";
import {
  newUsageState,
  acceptUsageRecord,
  normalizeTokenUsage,
} from "../runtime/session-usage.mjs";
import {
  validateUsagePreferences,
  estimateCost,
  priceUnits,
  matchingPrice,
} from "../src/core/usage-pricing.mjs";
const at = "2026-11-05T05:00:00.000Z";
const counts = (input = 1000, cached = 500, output = 100) => ({
  input_tokens: input,
  cached_input_tokens: cached,
  output_tokens: output,
  reasoning_output_tokens: Math.min(20, output),
  total_tokens: input + output,
});
const token = (total, last = total, time = at) => ({
  type: "event_msg",
  timestamp: time,
  payload: {
    type: "token_count",
    info: { total_token_usage: total, last_token_usage: last },
  },
});
const state = () => newUsageState("chat", { model_provider: "relay" });
test("cached and reasoning counters remain subsets and context-only token estimates are not spending", () => {
  const s = state();
  const event = acceptUsageRecord(s, token(counts()));
  assert.equal(s.total.total, 1100);
  assert.equal(event.cached, 500);
  assert.equal(event.reasoning, 20);
  assert.equal(
    acceptUsageRecord(s, token(counts(), { ...counts(), total_tokens: 10000 })),
    null,
  );
  for (const raw of [
    counts(-1),
    { ...counts(), input_tokens: NaN },
    { ...counts(), cached_input_tokens: 1001 },
    { ...counts(), reasoning_output_tokens: 101 },
  ])
    assert.equal(normalizeTokenUsage(raw), null);
});
test("duplicate quota notifications do not repeat cost and new turns start from their own baseline", () => {
  const s = state();
  acceptUsageRecord(s, token(counts()));
  assert.equal(acceptUsageRecord(s, token(counts())), null);
  acceptUsageRecord(s, {
    type: "event_msg",
    timestamp: at,
    payload: { type: "task_started", turn_id: "next" },
  });
  assert.equal(s.turnUsage.total, 0);
  const event = acceptUsageRecord(s, token(counts(2000, 1000, 200), counts()));
  assert.equal(event.total, 1100);
  assert.equal(s.turnUsage.total, 1100);
  assert.equal(s.total.total, 2200);
});
test("inherited counters and decreasing counters are never invented as new API spending", () => {
  const s = state();
  assert.equal(
    acceptUsageRecord(s, token(counts(4000, 2000, 400), counts())),
    null,
  );
  assert.equal(s.missingBaseline, true);
  const event = acceptUsageRecord(s, token(counts(5000, 2500, 500), counts()));
  assert.equal(event.total, 1100);
  assert.equal(acceptUsageRecord(s, token(counts())), null);
  assert.equal(s.counterReset, true);
  assert.equal(s.turnUsage, null);
});
test("a fork inheriting just one previous request is not charged again on its first restored counter", () => {
  const s = newUsageState("fork", {
    model_provider: "relay",
    forked_from_id: "parent",
  });
  assert.equal(acceptUsageRecord(s, token(counts())), null);
  assert.equal(s.missingBaseline, true);
  assert.equal(
    acceptUsageRecord(s, token(counts(2000, 1000, 200), counts())).total,
    1100,
  );
});
test("fork copies retain stable event identities, while prompts and credentials never enter parser state", () => {
  const a = state(),
    b = newUsageState("fork", { model_provider: "relay" }),
    record = token(counts());
  assert.equal(
    acceptUsageRecord(a, record).id,
    acceptUsageRecord(b, record).id,
  );
  acceptUsageRecord(a, {
    type: "event_msg",
    payload: { type: "user_message", message: "PRIVATE_PROMPT_AND_KEY" },
  });
  assert.ok(!JSON.stringify(a).includes("PRIVATE_PROMPT_AND_KEY"));
});
const rule = (patch = {}) => ({
  provider: "relay",
  model: "*",
  currency: "CNY",
  input: "2.5",
  cached: "0.25",
  cacheWrite: "3",
  output: "10",
  ...patch,
});
test("costs use exact decimal arithmetic, split cache categories, and keep currencies separate", () => {
  const preferences = validateUsagePreferences({
    rules: [rule(), rule({ provider: "other", currency: "USD" })],
  });
  const row = {
    provider: "relay",
    model: "model-a",
    input: 1000,
    cached: 500,
    cacheWrite: 100,
    output: 100,
    reasoning: 20,
  };
  const result = estimateCost(
    [row, { ...row, provider: "other" }],
    preferences.rules,
  );
  assert.deepEqual(result.amounts, [
    { currency: "CNY", amount: "0.002425" },
    { currency: "USD", amount: "0.002425" },
  ]);
  assert.equal(estimateCost([row], []).unpricedTokens, 1100);
  assert.equal(priceUnits("0.000001"), 1n);
});
test("specific pricing wins over generic rules and malformed or duplicate prices are rejected", () => {
  const rules = [
    rule({ provider: "*" }),
    rule(),
    rule({ model: "model-a", input: "1" }),
  ];
  assert.equal(matchingPrice(rules, "relay", "model-a").input, "1");
  for (const price of ["-1", "NaN", "1e3", "1,000", "0.1234567"])
    assert.throws(() =>
      validateUsagePreferences({ rules: [rule({ input: price })] }),
    );
  assert.throws(
    () => validateUsagePreferences({ rules: [rule(), rule()] }),
    /只能/,
  );
  assert.throws(
    () => validateUsagePreferences({ codexHome: "relative", rules: [] }),
    /完整/,
  );
});
