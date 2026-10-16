"""Build the Windows script bundle from tracked repository files."""
import hashlib
import json
import re
import subprocess
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
package = json.loads((root / "gpt-niang-usage/package.json").read_text(encoding="utf-8"))
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
credits = (root / 'README.md').read_text(encoding='utf-8-sig').split('## 致谢与许可\n\n', 1)[1].split('\n\n交互参考', 1)[0]
tracked = subprocess.check_output(
    ["git", "ls-files", "-z"], cwd=root
).decode("utf-8").split("\0")
files = sorted(p for p in tracked if p and not p.startswith((".github/", "scripts/", ".codex/", "macos/", "script/")))
required = {
    "LICENSE", "gpt-niang-usage/LICENSE",
    "gpt-niang-usage/assets/CHARACTER-NOTICE.txt",
    ".agents/plugins/marketplace.json", manifest_path,
    "安装GPT娘.cmd", "停用GPT娘.cmd", "打开GPT娘.cmd", "重启GPT娘.cmd",
    "检测套餐.cmd", "gpt-niang-usage/Detect-Plan.ps1",
    "gpt-niang-usage/runtime/plan.mjs", "gpt-niang-usage/runtime/detect-plan.mjs",
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
if not required.issubset(files):
    raise SystemExit("Required runtime files missing from the bundle")
private_names = {
    "installation.json", "settings.json", "runtime.json", "presence.json", "status.json",
    "update-preferences.json", "update-status.json", "update-transaction.json", "binding.json", "update-idle.json", "update-installing.json",
}
for name in files:
    path = Path(name)
    if any(part in {"node_modules", ".test-state", "dist"} for part in path.parts):
        raise SystemExit(f"Unexpected generated directory: {name}")
    if path.name in private_names or path.suffix in {".flag", ".tmp", ".bak", ".zip"}:
        raise SystemExit(f"Unexpected local state: {name}")
dist = root / "dist"
dist.mkdir(exist_ok=True)
archive_name = f"gpt-niang-usage-widget-v{version}-windows.zip"
archive_path = dist / archive_name
prefix = "GPT娘额度挂件/"
with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for name in files:
        info = zipfile.ZipInfo(prefix + name, date_time=(2026, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o100644 << 16
        archive.writestr(info, (root / name).read_bytes())
with zipfile.ZipFile(archive_path) as archive:
    if archive.testzip() is not None:
        raise SystemExit("Archive integrity check failed")
    packed_manifest = json.loads(archive.read(prefix + manifest_path).decode("utf-8"))
    if packed_manifest["version"] != version:
        raise SystemExit("Archive version verification failed")
digest = hashlib.sha256(archive_path.read_bytes()).hexdigest().upper()
(dist / "SHA256SUMS.txt").write_text(f"{digest}  {archive_name}\n", encoding="utf-8")
notes = (
    f"## {version}\n\n{changes}\n\n"
    "### 下载与更新\n\n"
    f"下载 **`{archive_name}`**，完整解压后运行根目录的 `安装GPT娘.cmd`。\n\n"
    "旧版用户请先备份自定义内容，在原目录覆盖新版文件，再运行安装器；保留原有偏好。\n\n"
    "仅支持 Windows 10 / 11，需要 Node.js 20 或更新版本及已登录的 Codex 桌面端。\n\n"
    f"SHA256：`{digest}`（同时提供 `SHA256SUMS.txt`）。\n\n"
    f"### 致谢\n\n{credits}\n"
)
(dist / "release-notes.md").write_text(notes, encoding="utf-8")
print(f"Built {archive_name}: {len(files)} files; SHA256 {digest}")
