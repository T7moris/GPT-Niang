import { quotaWindowLabel } from "../../runtime/plan.mjs";
export function resetCountdown(seconds) {
  if (seconds <= 0) return "重置已到 · 等待刷新";
  const minutes = Math.ceil(seconds / 60);
  if (minutes < 60) return `${minutes} 分钟后重置`;
  if (minutes < 1440) {
    const h = Math.floor(minutes / 60),
      m = minutes % 60;
    return m ? `${h} 小时 ${m} 分后重置` : `${h} 小时后重置`;
  }
  const d = Math.floor(minutes / 1440),
    h = Math.floor((minutes % 1440) / 60);
  return h ? `${d} 天 ${h} 小时后重置` : `${d} 天后重置`;
}
const pad = (x) => String(x).padStart(2, "0");
export function resetFixed(timestamp, now = Date.now() / 1000) {
  if (timestamp <= now) return "重置已到，等待更新";
  const date = new Date(timestamp * 1000),
    today = new Date(now * 1000),
    tomorrow = new Date(now * 1000);
  tomorrow.setDate(tomorrow.getDate() + 1);
  const key = (d) => `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
  const day =
    key(date) === key(today)
      ? "今日"
      : key(date) === key(tomorrow)
        ? "明日"
        : `${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
  return `${day} ${pad(date.getHours())}:${pad(date.getMinutes())} 重置`;
}
export function quotaRows(status) {
  const windows = (status?.windows ?? [])
    .filter(Boolean)
    .toSorted((a, b) => (a.minutes ?? 0) - (b.minutes ?? 0));
  const individual = windows.find((w) => w.kind === "individual");
  let short, week;
  if (individual) {
    short = individual;
    week = windows.find((w) => w.kind !== "individual");
  } else {
    short = windows.find((w) => w.minutes === 300);
    week = windows.find((w) => w.minutes === 10080);
    const other = windows.filter((w) => ![300, 10080].includes(w.minutes));
    let n = 0;
    if (!short) short = other[n++];
    if (!week) week = other[n];
  }
  return [
    {
      prefix: "Short",
      window: short,
      label:
        short?.kind === "individual"
          ? "个人额度"
          : short
            ? quotaWindowLabel(short.minutes)
            : "5 小时",
    },
    {
      prefix: "Week",
      window: week,
      label:
        week?.kind === "individual"
          ? "个人额度"
          : week
            ? quotaWindowLabel(week.minutes)
            : individual
              ? "其他额度"
              : "每周",
    },
  ];
}
export function formatQuota(status, mode = "countdown", now = Date.now()) {
  const seconds = Math.floor(now / 1000),
    age = status?.observedAt
      ? seconds - Math.floor(status.observedAt / 1000)
      : 0;
  const at = status?.observedAt
    ? new Date(status.observedAt).toLocaleTimeString("zh-CN", { hour12: false })
    : "";
  const text = !status
    ? "正在读取订阅额度…"
    : !status.ok
      ? status.error
      : status.error
        ? `刷新未成功 · 上次 ${at}`
        : age > 180
          ? `${Math.floor(age / 60)} 分钟前的额度 · 点击 ↻ 刷新`
          : `${at} 更新 · 实时订阅额度`;
  const header = !status
    ? "正在读取"
    : !status.ok
      ? "暂无法读取"
      : status.error || age > 180
        ? "上次剩余额度"
        : "剩余额度";
  const rows = quotaRows(status).map(({ prefix, window: q, label }) => {
    if (!q)
      return {
        prefix,
        label,
        visible: status?.queryOk !== true,
        usedText: "已用 —",
        leftText: "—",
        resetText:
          status && status.queryOk !== true ? "额度读取异常" : "暂无额度数据",
        bar: 0,
        valueColor: "#95889F",
      };
    const reset = Number(q.resetsAt) > 0,
      expired = reset && q.resetsAt <= seconds;
    const number = (x) => Number(Number(x).toFixed(1));
    const date = new Date(q.resetsAt * 1000),
      offset = -date.getTimezoneOffset(),
      tz = `${offset >= 0 ? "+" : "-"}${pad(Math.floor(Math.abs(offset) / 60))}:${pad(Math.abs(offset) % 60)}`;
    return {
      prefix,
      label,
      visible: true,
      usedText: `${expired ? "上次" : "已用"} ${number(q.used)}%`,
      leftText: expired ? "—" : `${number(q.remaining)}%`,
      resetText: reset
        ? mode === "fixed" || expired
          ? resetFixed(q.resetsAt, seconds)
          : resetCountdown(q.resetsAt - seconds)
        : "未提供重置时间",
      tooltip: reset
        ? `本机时间 ${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())} ${tz} 重置 · ${resetCountdown(q.resetsAt - seconds)}`
        : "",
      bar: expired ? 0 : q.remaining,
      barColor: expired
        ? "#B3A7C0"
        : q.used >= 90
          ? "#D77659"
          : q.used >= 75
            ? "#D0A051"
            : "#9B86C1",
      valueColor: expired
        ? "#95889F"
        : q.used >= 90
          ? "#B74839"
          : q.used >= 75
            ? "#A06C1C"
            : "#745A98",
    };
  });
  const parts = status?.planLabel ? [`当前套餐：${status.planLabel}`] : [],
    chosen = quotaRows(status);
  rows.forEach((row, index) => {
    if (!row.visible) return;
    parts.push(
      `${row.label}：${row.usedText}，${row.tooltip || row.resetText}`,
    );
    const q = chosen[index].window;
    if (q?.kind === "individual") {
      parts.push("公司工作区内的个人限额（非公司总余额）");
      if (q.total != null && q.amountUsed != null)
        parts.push(
          `额度上限 ${Number(Number(q.total).toFixed(2))} · 已用 ${Number(Number(q.amountUsed).toFixed(2))} · 剩余 ${Number(Number(q.amountRemaining).toFixed(2))}`,
        );
    }
  });
  for (const q of status?.windows ?? []) {
    if (!q || chosen.some((r) => r.window === q)) continue;
    parts.push(
      `${quotaWindowLabel(q.minutes)}：已用 ${Number(Number(q.used).toFixed(1))}%，${q.resetsAt ? resetFixed(q.resetsAt, seconds) : "未提供重置时间"}`,
    );
  }
  return {
    header,
    headerTooltip: status?.planLabel
      ? `当前套餐：${status.planLabel} · 重置时间按本机时间显示`
      : "重置时间按本机时间显示",
    status: text,
    tooltip: [...parts, text].join("\n"),
    dot:
      !status || !status.ok || status.error || age > 180
        ? "#C5A96F"
        : "#9B86C1",
    rows,
  };
}
