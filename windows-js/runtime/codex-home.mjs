import os from "node:os";
import path from "node:path";

// A Codex home is a location, not a directory name. Keep the selected home
// through Explorer launches, task startup and upgrades with a minimal env.
export function resolveCodexHome(configured, env = process.env) {
  const supplied =
    typeof configured === "string" && configured.trim()
      ? configured
      : env.CODEX_HOME;
  return path.resolve(
    supplied ||
      path.join(env.USERPROFILE || env.HOME || os.homedir(), ".codex"),
  );
}
export function applyCodexHomeArgument(args, env = process.env) {
  const index = args.indexOf("--codex-home");
  if (index < 0) return null;
  const value = args[index + 1];
  if (
    typeof value !== "string" ||
    !path.isAbsolute(value) ||
    /[\x00-\x1f]/.test(value)
  )
    throw Error("--codex-home 后需要填写完整的 Codex 数据目录");
  return (env.CODEX_HOME = path.resolve(value));
}
