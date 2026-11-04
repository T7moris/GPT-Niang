import fs from "node:fs";
export function readPause(file) {
  try {
    const raw = fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""),
      value = JSON.parse(raw);
    const ticks = raw.match(/"hostStarted"\s*:\s*(\d+)/);
    if (ticks) value.hostStarted = ticks[1];
    return value;
  } catch {
    return null;
  }
}
export function sessionPaused(pause, hosts) {
  if (!pause) return false;
  if (pause.desktop) return true;
  return hosts.some(
    (h) =>
      Number(pause.host) > 0 &&
      Number(h.handle) === Number(pause.host) &&
      (!Number(pause.hostPid) || Number(h.pid) === Number(pause.hostPid)) &&
      (!pause.hostStarted ||
        String(pause.hostStarted) === "0" ||
        String(h.started) === String(pause.hostStarted)),
  );
}
export function shouldLaunch({
  hosts,
  settings,
  pause,
  running,
  pending,
  now,
  nextLaunch,
}) {
  return (
    !sessionPaused(pause, hosts) &&
    (settings?.followHost === false || hosts.some((h) => h.visible)) &&
    !running &&
    !pending &&
    now >= nextLaunch
  );
}
