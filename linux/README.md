# GPT娘 Linux KDE 预览版

独立的 Quickshell / Qt Quick 前端，复用上游 v1.3.4 的 Node.js 只读额度后端和角色素材。桌面模式、窗口跟随、额度与语录气泡、按压回弹、音效、拖动、缩放、设置和登录启动均有 Linux 实现。无需运行 plasmashell，也可用于 KWin + KOS / Quickshell 等定制桌面。

这是当前分支的 Linux 预览适配，尚未纳入上游 Windows / macOS 正式发布。代码许可和角色素材许可分别沿用上游，分发时保留 `CHARACTER-NOTICE.txt`、`quotes-LICENSE.txt` 和素材来源说明。

## 兼容范围

**仅在 Fedora KDE / KOS 环境做过桌面实测。Debian / Ubuntu、Arch 等其他发行版的 KDE 未做实际桌面测试；由于共用 KWin 6 / Qt / Node.js 接口，理论上可兼容，但不保证可用。** 下表描述实现目标，不代表各发行版均已通过验证。容器内后端回归不能替代 KDE 桌面实测，详细记录见 [验证记录](VALIDATION.md)。

| 环境 | 实现范围 |
| --- | --- |
| KDE Plasma / KWin 6，Wayland | 桌面模式和 Codex 窗口跟随；Fedora KDE 为本机验证环境 |
| KWin 6 + KOS / 其他定制桌面 | 使用相同桥接，不导入、不替换桌面 Shell 配置 |
| Debian / Ubuntu / Arch 系 KDE | 理论兼容，未做实际桌面测试；需安装目标发行版对应的依赖和 Quickshell |
| Plasma 6 的 X11 会话 | 代码路径可用，真实 X11 桌面尚需验收 |
| Plasma 5、GNOME、其他窗口管理器 | 不在本版本支持范围 |

最低依赖：Node.js 20、Quickshell 0.2.1、Qt 6 的 Qt Quick Controls / Qt Multimedia、Python 3 的 D-Bus / GLib 绑定、`flock`（util-linux），以及使用 ChatGPT 账号登录的 Codex CLI。推荐 Quickshell 0.3+。不能把某台 Fedora 的 Quickshell 二进制直接复制给 Debian 或 Arch；应安装目标发行版对应的包，避免 Qt ABI 不匹配。

KWin 6.5+ 使用窗口叠放约束；较早的 KWin 6 使用按原叠放次序恢复的兼容路径。跟随模式下不强制全局置顶，其他应用覆盖 Codex 时也能覆盖挂件。不同版本、窗口特效、全屏、多屏混合缩放的实际效果需分别验收。

## 安装依赖

Fedora 44 KDE：

```sh
sudo dnf install nodejs quickshell qt6-qtmultimedia python3-dbus python3-gobject util-linux
```

Debian 13 KDE：先按 [Debian Backports 说明](https://backports.debian.org/Instructions/) 配置 `trixie-backports`，再安装：

```sh
sudo apt update
sudo apt install nodejs python3-dbus python3-gi util-linux qml6-module-qtmultimedia qml6-module-qtquick-controls qml6-module-qtquick-layouts qml6-module-qtquick-window qml6-module-qtqml-workerscript
sudo apt install -t trixie-backports quickshell
```

Debian testing / sid 已提供 `quickshell`；Ubuntu 的包源随版本不同，请按 [Quickshell 官方安装说明](https://quickshell.org/docs/v0.3.0/guide/install-setup/) 选择对应源，先检查 Plasma / Node.js 版本。

Arch 系 KDE（完整升级，避免部分升级造成 Qt ABI 不匹配）：

```sh
sudo pacman -Syu --needed nodejs quickshell qt6-multimedia python-dbus python-gobject util-linux
```

包源核对：[Fedora](https://packages.fedoraproject.org/pkgs/quickshell/quickshell/)、[Debian](https://packages.debian.org/search?keywords=quickshell)、[Arch](https://archlinux.org/packages/extra/x86_64/quickshell/)。包版本和仓库可能变化，以目标系统实际结果为准。

## 启动与安装入口

从仓库根目录或完整 Linux 包目录运行：

```sh
./linux/gpt-niang doctor
./linux/gpt-niang start
```

`doctor` 检查 Quickshell 版本、QML 模块、Python D-Bus、KWin 会话和 Codex CLI。不会修改登录配置，也不会发起模型请求。

确认依赖齐全后，注册应用菜单和命令行入口：

```sh
./linux/gpt-niang install
gpt-niang start
```

安装在当前目录原地注册，保留该目录；移动目录后重新执行 `install`。程序在单独进程里运行，默认桌面模式、默认不置顶。再次启动只显示气泡，不叠加第二只。右键角色或点击悬停齿轮打开设置。登录启动默认不主动开启；可在设置中开启，或执行 `gpt-niang autostart on`。

如果 Codex CLI 不在桌面会话的 PATH：

```sh
GPT_NIANG_CODEX_PATH=/absolute/path/to/codex ./linux/gpt-niang start
```

可用 `GPT_NIANG_NODE`、`GPT_NIANG_QUICKSHELL`、`GPT_NIANG_PYTHON` 显式指定运行时。安装器记住当前 Node.js 和 Codex CLI 路径，供桌面会话的精简 PATH 使用。

## 操作

| 操作 | 行为 |
| --- | --- |
| 点击角色 | 查看额度并延长气泡；开启点击切换后循环额度 / 语录 / 收起 |
| 点击气泡 | 额度 → 随机语录 → 收起 |
| 点击刷新 | 手动刷新；不会创建聊天或调用模型 |
| 右键 / 悬停齿轮 | 打开设置 |
| 拖动角色 | 桌面模式跨屏移动、靠边吸附；跟随模式调整左右位置和底部间距 |
| 滚轮 / 设置缩放 | 60%–250%，另有 80% / 100% / 140% 预设 |
| 跟随模式 | 跟随最近激活的 Codex 应用窗口；最小化、关闭、切换桌面 / Activity 时隐藏 |
| 退出 | 停止本挂件、桥接和所属后台，KOS 继续运行 |

跟随匹配应用 class / desktop ID，不按聊天标题或浏览器标题匹配。支持 `codex`、`com.openai.codex` 等标识，以及 Linux 桌面包的 `Chatgpt` class。Linux 包把 ChatGPT 与 Codex 放在同一应用窗口时，跟随的是这个应用窗口。

常用命令：

```sh
gpt-niang settings
gpt-niang mode follow
gpt-niang mode desktop
gpt-niang scale 0.8
gpt-niang refresh
gpt-niang quote
gpt-niang status
gpt-niang stop
```

## 数据、更新与卸载

偏好、用户语录、额度数字和运行状态位于 `${XDG_STATE_HOME:-$HOME/.local/state}/gpt-niang-usage`。调试可用 `GPT_NIANG_DATA_DIR` 覆盖。不会读取聊天正文，不保存邮箱、令牌或账户凭据；账号快照隔离沿用上游身份哈希机制。KWin 只向桥接发送目标窗口、挂件和显示器的几何 / 可见状态，不发送其他应用的标题或窗口列表。

额度可见时每分钟刷新，隐藏时暂停。过期窗口显示 `—`，旧快照和同账号查询失败明确标记。没有接口数据时不会推测剩余额度。小气泡优先显示前两个窗口；完整列表和重置时间位于设置页。网络或服务端错误直接显示上游的查询状态，可稍后手动刷新。

Linux 预览版使用 Git / 完整 Linux 包手动更新；不调用 Windows 或 macOS 自动更新器。更新前退出，在同一路径更新程序后再启动。个人数据在程序目录之外。

```sh
gpt-niang stop
gpt-niang uninstall
```

卸载移除应用菜单、命令入口和自启动，保留源码与个人偏好。需要清除个人数据时，单独删除上述 `gpt-niang-usage` 数据目录；不要删除 Codex 自己的登录或会话目录。

## 开发与验证

以下命令在完整源码检出中运行；运行包不包含测试源码。

```sh
node --test gpt-niang-usage/tests/*.test.mjs linux/tests/*.test.mjs
python3 -m py_compile linux/runtime/kwin-bridge.py
python3 scripts/build-linux.py
```

`linux/tests` 覆盖设置持久化、额度过期 / 旧快照、安装卸载、UTF-8 长路径、SIGKILL 后的竞争恢复，以及执行真实 KWin 脚本的最小化、虚拟桌面、Activity、遮挡顺序、负坐标显示器和旧版 API 分支。已配置 Fedora / Debian / Arch 容器 CI，检查后端与脚本逻辑；CI 执行状态以 PR 的实际检查结果为准。容器结果不能替代完整桌面验收。

在有 GTK4 / PyGObject 的 KDE 桌面上，还可执行 `GDK_BACKEND=wayland python3 linux/tests/live-kde.py`。它只创建并操纵自己的临时目标 / 遮挡窗口，验证真实 KWin 跟随、遮挡、最小化、恢复与关闭，并恢复原显示模式。

`./linux/gpt-niang start --dev` 可开启源码监听。常规启动关闭文件监听，避免编辑源码时重启挂件。Linux 包由显式文件白名单构建，不包含本机设置、账号快照、运行时路径、截图或缓存。
