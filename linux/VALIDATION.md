# Linux KDE 验证记录

日期：2026-10-18（Asia/Shanghai）。基线为上游 v1.3.4 / `b92159a93c131bd5ba4722d7f507ee04d633d5db`。以下为本地验证记录；GitHub CI 执行状态以 PR 的实际检查结果为准。

**仅在 Fedora KDE / KOS 环境做过桌面实测。Debian / Ubuntu、Arch 等其他发行版的 KDE 未做实际桌面测试，兼容性目前仅为理论判断，不保证可用。** 下文的 Debian / Arch 容器回归仅覆盖后端和脚本，不表示这些发行版的完整 KDE 环境已验证。

## 已实现和本机部署

- 独立 Qt Quick / Quickshell 界面：角色、额度、语录、音效、按压回弹、拖动、60%–250% 缩放、设置和登录启动。
- KWin 窗口跟随：应用 ID 识别、几何跟随、真实叠放、最小化 / 桌面 / Activity 可见状态、窗口关闭清理。KWin 6.5+ 使用叠放约束，较早 KWin 6 有兼容路径。
- Linux 后台的内核锁、SIGKILL 后 socket 恢复、并发重启和 UTF-8 长路径处理。
- 用户级命令、应用菜单、自启动开关、卸载入口及独立 XDG 用户数据目录。
- 在用户主目录启动账号查询后台，安装时保存 Node.js / Codex CLI 路径，适配桌面会话的精简 PATH。
- 已注册 `~/.local/bin/gpt-niang` 和 `org.gptniang.KDE.desktop`，挂件独立运行于本机 KOS 桌面。

## 回归结果

| 环境 / 检查 | 结果 | 边界 |
| --- | --- | --- |
| Fedora 44，本机 Node 24.21.0 | 96 项：94 通过，2 跳过，0 失败 | 两项跳过为 Windows 专用场景 |
| Debian trixie-slim，发行版 Node 20.19.2 | 当时的 94 项：92 通过，2 跳过，0 失败 | 在后续异步窗口引用和错误分类修复前执行；不是最终 96 项桌面验收 |
| Arch Linux base，固定 Node 24.21.0 | 96 项：94 通过，2 跳过，0 失败 | 使用挂载的固定 Node 二进制验证 Arch 用户空间；未安装发行版 Node 26 包或运行完整 KDE 桌面 |
| Python D-Bus / GLib | Fedora、Debian 导入通过 | Arch 原生 Python 依赖安装受软件包镜像超时影响，尚未完成该项验证 |
| QML 依赖检查 | Fedora 上通过 | Quickshell 0.3.1、Qt 6.11.2，Controls / Multimedia 均加载成功 |
| 安装入口 | 命令、desktop 文件检查通过 | 登录启动开关已有实现；本次未注销重登 |
| 精简 PATH 启动 | `/usr/bin:/bin` 环境下依赖检查和重新启动通过，实时读取两个额度窗口 | 复用了安装时保存的 Node.js / Codex CLI 路径 |
| Linux 包 | 显式白名单构建、解压后 doctor 通过 | 不捆绑 Node.js、Quickshell、Qt 或 Python |

Node 回归命令：

```sh
node --test --test-reporter=spec gpt-niang-usage/tests/*.test.mjs linux/tests/*.test.mjs
```

Arch 软件包下载的失败原因是默认镜像连接超时 / 下载过慢；没有关闭包签名检查，也没有在宿主机更换软件源。以上 Arch 结果只代表固定运行时下的后端和脚本逻辑回归。

## 真实 KWin 验收

本机为 KWin 6.7.5、Wayland、KOS / Quickshell；单块 eDP 显示器，逻辑分辨率 1536×960，物理分辨率 1920×1200（125%）。

`GDK_BACKEND=wayland python3 linux/tests/live-kde.py` 的六项实际窗口检查全部通过：

1. 识别临时 Codex 应用 ID。
2. 移动 / 调整临时目标窗口后，挂件在逻辑坐标中正确跟随且无窗口装饰。
3. 挂件位于目标窗口之上、其他覆盖应用之下。
4. 最小化目标后，挂件实际窗口隐藏。
5. 恢复目标后，挂件实际窗口恢复。
6. 关闭目标后，清理旧目标并重新选择有效窗口。

验收发现并修复了异步 D-Bus 返回期间目标 / 挂件窗口被销毁时的陈旧 QObject 引用问题；已增加对应回归。临时窗口和测试脚本在完成时退出，原显示模式恢复。

## 额度接口

当前账号的 5 小时和每周窗口均已多次通过原只读 App Server 协议实测成功；没有创建聊天或调用模型。中途也实际出现过 `workspace routing discovery timed out`，所以不能把某次成功等同于外部服务持续可用。

此错误现在会被分类为 `WORKSPACE_ROUTING_UNAVAILABLE`，显示「Codex 工作区路由服务暂不可用，请稍后刷新」，不输出原始 RPC 详情。过期、未验证账号和查询失败的快照处理仍沿用上游隔离规则。

## 尚未进行真实桌面验收的项目

- Debian / Ubuntu / Arch 的完整 KDE 桌面、原生发行版 Quickshell 组合。
- 多块显示器、热插拔、不同缩放比例混用、全屏游戏 / 特效组合。
- Plasma X11 会话、较早 KWin 6 的真实叠放兼容路径。
- 真实鼠标逐项输入验收、注销重登后的自启动、长期运行稳定性。

Plasma 5、GNOME 和其他窗口管理器不在本预览版的支持范围。相关 CI 工作流已经加入仓库；其执行状态以 PR 的实际检查结果为准。
