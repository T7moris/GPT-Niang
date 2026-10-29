"""Build the Windows script bundle from tracked repository files."""

import argparse
import hashlib
import json
import re
import subprocess
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    "--startup-mode",
    choices=("automatic", "manual"),
    default="automatic",
    help="automatic keeps logon startup; manual requires opening the widget yourself",
)
parser.add_argument("--output-dir", type=Path, default=root / "dist")
args = parser.parse_args()
package = json.loads(
    (root / "gpt-niang-usage/package.json").read_text(encoding="utf-8")
)
version = package["version"]
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    raise SystemExit("Expected a stable major.minor.patch version")
manifest_path = "gpt-niang-usage/.codex-plugin/plugin.json"
manifest = json.loads((root / manifest_path).read_text(encoding="utf-8"))
if manifest["version"] != version:
    raise SystemExit("Package and plugin versions differ")
changelog = (root / "更新记录.md").read_text(encoding="utf-8")
heading = f"## {version}\n"
if heading not in changelog or changelog.split("## ", 1)[1].splitlines()[0] != version:
    raise SystemExit("The first changelog entry must match the release version")
changes = changelog.split(heading, 1)[1].split("\n## ", 1)[0].strip()
credits = (
    (root / "README.md")
    .read_text(encoding="utf-8-sig")
    .split("## 致谢与许可\n\n", 1)[1]
    .split("\n\n交互参考", 1)[0]
)
tracked = (
    subprocess.check_output(["git", "ls-files", "-z"], cwd=root)
    .decode("utf-8")
    .split("\0")
)
# Keep maintainer docs in Git. The updater preserves an existing docs directory
# as personal data, so shipping another docs tree would collide on upgrade.
excluded_prefixes = (
    ".github/",
    "scripts/",
    ".codex/",
    "macos/",
    "script/",
    "docs/",
    "gpt-niang-usage/tests/",
)
excluded_files = {
    ".gitignore",
    "gpt-niang-usage/runtime/thread-speed.mjs",
    "gpt-niang-usage/安装GPT娘.cmd",
    "gpt-niang-usage/打开GPT娘.cmd",
    "gpt-niang-usage/停用GPT娘.cmd",
}
files = sorted(
    p
    for p in tracked
    if p and not p.startswith(excluded_prefixes) and p not in excluded_files
)
required = {
    "LICENSE",
    "gpt-niang-usage/LICENSE",
    "gpt-niang-usage/assets/CHARACTER-NOTICE.txt",
    ".agents/plugins/marketplace.json",
    manifest_path,
    "安装GPT娘.cmd",
    "停用GPT娘.cmd",
    "打开GPT娘.cmd",
    "检测套餐.cmd",
    "gpt-niang-usage/Detect-Plan.ps1",
    "gpt-niang-usage/runtime/audio-import.mjs",
    "gpt-niang-usage/runtime/characters.ps1",
    "gpt-niang-usage/runtime/character-gallery.ps1",
    "gpt-niang-usage/assets/characters.json",
    "gpt-niang-usage/runtime/plan.mjs",
    "gpt-niang-usage/runtime/detect-plan.mjs",
    "gpt-niang-usage/runtime/start-widget.ps1",
    "gpt-niang-usage/runtime/refresh-client.mjs",
    "gpt-niang-usage/runtime/worker-state.mjs",
    "gpt-niang-usage/runtime/update.mjs",
    "gpt-niang-usage/runtime/update-helper.ps1",
    "gpt-niang-usage/runtime/update-agent.ps1",
    "gpt-niang-usage/runtime/update-common.ps1",
    "gpt-niang-usage/runtime/update-lock.ps1",
    "gpt-niang-usage/runtime/update-ui.ps1",
    "gpt-niang-usage/runtime/install-preflight.ps1",
    "gpt-niang-usage/runtime/install-files.json",
    "gpt-niang-usage/runtime/agent-launch.vbs",
    "gpt-niang-usage/runtime/agent-supervisor.vbs",
    "gpt-niang-usage/assets/gpt-dragon-niang-bust.png",
}
required.update(
    "gpt-niang-usage/" + name
    for name in json.loads(
        (root / "gpt-niang-usage/runtime/install-files.json").read_text(
            encoding="utf-8"
        )
    )
)
missing = sorted(
    name for name in required if name not in files or not (root / name).is_file()
)
if missing:
    raise SystemExit(
        "Required runtime files missing from the bundle: " + ", ".join(missing)
    )
private_names = {
    "installation.json",
    "settings.json",
    "runtime.json",
    "presence.json",
    "status.json",
    "update-preferences.json",
    "update-status.json",
    "update-transaction.json",
    "binding.json",
    "update-idle.json",
    "update-installing.json",
}
for name in files:
    path = Path(name)
    if any(part in {"node_modules", ".test-state", "dist"} for part in path.parts):
        raise SystemExit(f"Unexpected generated directory: {name}")
    if path.name in private_names or path.suffix in {".flag", ".tmp", ".bak", ".zip"}:
        raise SystemExit(f"Unexpected local state: {name}")
contents = {name: (root / name).read_bytes() for name in files}
if args.startup_mode == "manual":
    contents["安装GPT娘.cmd"] = (
        '@echo off\r\npowershell.exe -NoProfile -STA -File "%~dp0gpt-niang-usage\\Install.ps1"\r\npause\r\n'
    ).encode("utf-8")
    contents["打开GPT娘.cmd"] = (
        '@echo off\r\npowershell.exe -NoLogo -NoProfile -STA -File "%~dp0gpt-niang-usage\\runtime\\start-widget.ps1"\r\nif errorlevel 1 pause\r\n'
    ).encode("utf-8")
    contents["gpt-niang-usage/Install.ps1"] = (
        (root / "scripts/manual-install.ps1")
        .read_text(encoding="utf-8-sig")
        .encode("utf-8-sig")
    )
    # A local install must not wait for the unrelated remote plugin catalog.
    preflight = contents["gpt-niang-usage/runtime/install-preflight.ps1"].decode(
        "utf-8-sig"
    )
    contents["gpt-niang-usage/runtime/install-preflight.ps1"] = preflight.replace(
        "Arguments='plugin list --json'",
        "Arguments='plugin list --marketplace gpt-niang-local --json'",
    ).encode("utf-8")
    notice = (
        "本包为手动启动版。运行安装入口后，再运行打开入口显示挂件。\n"
        "不创建开机启动或后台守护任务；内置更新关闭，请手动下载同类包更新。\n"
        "此方案只减少自动常驻行为，不保证不会被杀毒软件拦截。\n\n"
    )
    contents["README.md"] = (notice + contents["README.md"].decode("utf-8-sig")).encode(
        "utf-8"
    )
else:
    # Keep automatic builds deterministic even from a personal manual-start branch.
    contents["打开GPT娘.cmd"] = (
        '@echo off\r\nwscript.exe "%~dp0gpt-niang-usage\\launch.vbs"\r\n'.encode(
            "utf-8"
        )
    )

dist = args.output_dir
dist.mkdir(parents=True, exist_ok=True)
suffix = "-manual" if args.startup_mode == "manual" else ""
archive_name = f"gpt-niang-usage-widget-v{version}-windows{suffix}.zip"
archive_path = dist / archive_name
prefix = "GPT娘额度挂件/"
with zipfile.ZipFile(
    archive_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9
) as archive:
    for name, content in sorted(contents.items()):
        info = zipfile.ZipInfo(prefix + name, date_time=(2026, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o100644 << 16
        archive.writestr(info, content)
with zipfile.ZipFile(archive_path) as archive:
    if archive.testzip() is not None:
        raise SystemExit("Archive integrity check failed")
    packed_manifest = json.loads(archive.read(prefix + manifest_path).decode("utf-8"))
    if packed_manifest["version"] != version:
        raise SystemExit("Archive version verification failed")
digest = hashlib.sha256(archive_path.read_bytes()).hexdigest().upper()
sums_name = f"SHA256SUMS{suffix}.txt"
(dist / sums_name).write_text(f"{digest}  {archive_name}\n", encoding="utf-8")
startup_note = (
    "手动启动版不配置登录启动或守护任务。安装后运行`打开GPT娘.cmd`，退出或重启后需再次手动打开。内置更新关闭，请下载新的手动启动包更新。此方案不保证不会触发杀毒软件检测。\n\n"
    if args.startup_mode == "manual"
    else "本包沿用登录启动与后台守护任务。\n\n"
)
notes = (
    f"## {version}\n\n{changes}\n\n"
    "### 下载与更新\n\n"
    f"下载 **`{archive_name}`**，完整解压后运行根目录的 `安装GPT娘.cmd`。\n\n"
    f"{startup_note}"
    "旧版用户请先备份自定义内容，在原目录覆盖新版文件，再运行安装器；保留原有偏好。\n\n"
    "仅支持 Windows 10 / 11，需要 Node.js 20 或更新版本及已登录的 Codex 桌面端。\n\n"
    f"SHA256：`{digest}`（同时提供 `{sums_name}`）。\n\n"
    f"### 致谢\n\n{credits}\n"
)
(dist / f"release-notes{suffix}.md").write_text(notes, encoding="utf-8")
print(f"Built {archive_name}: {len(contents)} files; SHA256 {digest}")
