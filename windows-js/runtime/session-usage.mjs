import { createHash } from "node:crypto";

const fields = [
  "input",
  "cached",
  "cacheWrite",
  "output",
  "reasoning",
  "total",
];
export const emptyUsage = () =>
  Object.fromEntries(fields.map((key) => [key, 0]));
const count = (value) => Number.isSafeInteger(value) && value >= 0;
const label = (value) =>
  typeof value === "string"
    ? value
        .replace(/[\x00-\x1f\x7f]/g, "")
        .trim()
        .slice(0, 160)
    : "";
export function normalizeTokenUsage(raw) {
  if (!raw || !count(raw.input_tokens) || !count(raw.output_tokens))
    return null;
  const value = {
    input: raw.input_tokens,
    cached: raw.cached_input_tokens ?? 0,
    cacheWrite: raw.cache_write_input_tokens ?? 0,
    output: raw.output_tokens,
    reasoning: raw.reasoning_output_tokens ?? 0,
    total: raw.input_tokens + raw.output_tokens,
  };
  return fields.every((key) => count(value[key])) &&
    value.cached + value.cacheWrite <= value.input &&
    value.reasoning <= value.output
    ? value
    : null;
}
export const sameUsage = (a, b) =>
  Boolean(a && b && fields.every((key) => a[key] === b[key]));
export function usageDifference(next, previous) {
  const value = Object.fromEntries(
    fields.map((key) => [key, next[key] - previous[key]]),
  );
  return fields.every((key) => count(value[key])) &&
    value.cached + value.cacheWrite <= value.input &&
    value.reasoning <= value.output
    ? value
    : null;
}
export function localDay(at = Date.now()) {
  const date = new Date(at);
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}
export function newUsageState(id, metadata = {}) {
  return {
    id,
    provider: label(metadata.model_provider) || "unknown",
    model: "unknown",
    subagent: Boolean(
      metadata.source === "subagent" || metadata.source?.subagent,
    ),
    title: label(metadata.title),
    total: null,
    turnUsage: null,
    turnId: null,
    phase: "unknown",
    at: 0,
    missingBaseline: false,
    counterReset: false,
    inherited: Boolean(
      metadata.forked_from_id || metadata.forked_from_session_id,
    ),
  };
}
// Only counters and public model/session metadata are retained. Message bodies,
// credentials, request headers and model responses are never part of the ledger.
export function acceptUsageRecord(state, record) {
  const payload = record?.payload;
  const at =
    typeof record?.timestamp === "number"
      ? record.timestamp
      : Date.parse(record?.timestamp);
  if (record?.type === "session_meta") {
    state.provider = label(payload?.model_provider) || state.provider;
    state.subagent =
      payload?.source === "subagent" || Boolean(payload?.source?.subagent);
    state.title = label(payload?.title) || state.title;
    state.inherited ||= Boolean(
      payload?.forked_from_id || payload?.forked_from_session_id,
    );
    return null;
  }
  if (record?.type === "turn_context") {
    state.model = label(payload?.model) || state.model;
    state.provider = label(payload?.model_provider) || state.provider;
    const turn = label(payload?.turn_id);
    if (turn && turn !== state.turnId) {
      state.turnId = turn;
      state.turnUsage = state.total ? emptyUsage() : null;
    }
    return null;
  }
  if (record?.type !== "event_msg") return null;
  if (payload?.type === "task_started") {
    const turn = label(payload.turn_id) || String(at);
    if (turn !== state.turnId) {
      state.turnId = turn;
      state.turnUsage = state.total ? emptyUsage() : null;
    }
    state.phase = "running";
    return null;
  }
  if (
    ["task_complete", "turn_complete", "turn_aborted"].includes(payload?.type)
  ) {
    state.phase = "idle";
    return null;
  }
  if (payload?.type !== "token_count") return null;
  const next = normalizeTokenUsage(payload.info?.total_token_usage);
  if (!next || !Number.isFinite(at) || at <= 0 || at > 253402300799000)
    return null;
  if (sameUsage(state.total, next)) return null; // rate-limit-only notifications repeat usage
  const last = normalizeTokenUsage(payload.info?.last_token_usage);
  let delta;
  if (!state.total) {
    // Resume/fork may begin with inherited spending and no original request. Its
    // baseline is displayed, but must not be charged to the new log or model.
    delta = !state.inherited && sameUsage(next, last) ? next : null;
    if (next.total && !delta) state.missingBaseline = true;
  } else delta = usageDifference(next, state.total);
  if (state.total && !delta) {
    state.counterReset = true;
    state.turnUsage = null;
  }
  state.total = next;
  state.at = Math.max(state.at, at);
  if (!delta || !delta.total) return null;
  if (!state.turnUsage && !state.missingBaseline && !state.counterReset)
    state.turnUsage = emptyUsage();
  if (state.turnUsage) {
    const sum = Object.fromEntries(
      fields.map((key) => [key, state.turnUsage[key] + delta[key]]),
    );
    state.turnUsage = fields.every((key) => count(sum[key])) ? sum : null;
  }
  const identity = [at, state.turnId, next, last];
  return {
    id: createHash("sha256").update(JSON.stringify(identity)).digest("hex"),
    thread: state.id,
    provider: state.provider,
    model: state.model,
    day: localDay(at),
    at,
    ...delta,
  };
}
