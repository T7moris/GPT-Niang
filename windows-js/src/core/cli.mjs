import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { resolveCodexExecutable } from "../../runtime/usage.mjs";

export function resolveInstallCli(
  configured,
  { execute = spawnSync, env = process.env } = {},
) {
  const directory = path.join(env.LOCALAPPDATA ?? "", "OpenAI", "Codex", "bin"),
    candidates = [
      env.CODEX_CLI_PATH,
      configured,
      resolveCodexExecutable(configured),
    ];
  if (fs.existsSync(directory)) {
    const files = fs
      .readdirSync(directory)
      .map((name) => path.join(directory, name, "codex.exe"))
      .filter((file) => fs.existsSync(file))
      .sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs);
    candidates.push(...files);
  }
  for (const file of new Set(candidates.filter(Boolean))) {
    if (!fs.existsSync(file)) continue;
    const supported = [
      ["plugin", "marketplace", "add"],
      ["plugin", "add"],
      ["plugin", "list"],
    ].every((args) => {
      const result = execute(file, [...args, "--help"], {
        windowsHide: true,
        timeout: 8000,
        encoding: "utf8",
      });
      return (
        !result.error &&
        result.status === 0 &&
        /--json\b/.test(result.stdout) &&
        (args.at(-1) !== "list" || /--marketplace\b/.test(result.stdout))
      );
    });
    if (supported) return file;
  }
  throw Error("没有找到支持插件安装的 Codex 命令程序。");
}
