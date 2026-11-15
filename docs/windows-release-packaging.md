# Windows发布包

在仓库根目录直接运行以下命令。没有必填参数，在IDE中运行打包脚本也默认生成原自动启动版。

```powershell
python scripts/build-release.py
python scripts/build-release.py --startup-mode automatic
python scripts/build-release.py --startup-mode manual
```

`--output-dir`可指定输出目录，默认是仓库的`dist/`。

| 模式 | ZIP名称 | 启动方式 |
|---|---|---|
| `automatic` | `gpt-niang-usage-widget-v<版本>-windows.zip` | 沿用原安装器、登录启动和守护任务 |
| `manual` | `gpt-niang-usage-widget-v<版本>-windows-manual.zip` | 手动安装并打开，不配置开机启动或守护任务 |

自动启动版沿用`SHA256SUMS.txt`和`release-notes.md`。手动启动版分别输出`SHA256SUMS-manual.txt`和`release-notes-manual.md`，两种构建不会覆盖彼此的压缩包、校验文件和说明。

手动启动版只在发布ZIP中替换安装脚本和根目录入口，不修改仓库中的原`Install.ps1`。它继续检查Node.js、Codex和运行文件，注册本地额度插件，并可移除已确认属于本安装的旧登录启动和守护任务。安装完成后，双击根目录的`打开GPT娘.cmd`显示挂件。退出或重启后，需要再次手动打开。

手动启动版设置`startupMode=manual`，关闭内置更新，并禁止从界面重新启用，避免更新成自动启动版。更新时请下载新的手动启动包，备份偏好后按说明手动替换。

此模式用于减少不需要的自动常驻行为，不是杀毒软件认证的“安全版”，也不保证其他机器不会报毒。它不修改系统执行策略或杀毒软件配置。系统策略阻止脚本运行时，应由使用者处理信任与策略问题。

两种发布包均排除开发测试、Git忽略规则、Mac聊天速度辅助脚本和子目录重复CMD入口；这些文件仍保留在仓库中。运行文件、插件市场和所有许可与素材来源说明继续随包保留。
