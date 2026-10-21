# GPT-Niang（GPT 娘）Windows 插件

这是 Windows 插件与桌面挂件目录，其中的 Node.js 运行时也由 Mac 原生应用复用。安装、使用、更新和隐私说明请看[项目主页](../README.md)。

代码、审查、问题复现及功能建议的作者与对应 PR／Issue，统一记录在[完整贡献致谢](../README.md#致谢与许可)。

- `Install.ps1`：检查依赖并安装；`-CheckOnly` 只检查，不修改系统。
- `widget.ps1` / `widget.xaml`：Windows WPF 挂件与界面。
- `runtime/sharp-text.ps1`：使用字形几何绘制文字，避免整段文字位图在缩放后产生毛刺；中文使用随附的霞鹜文楷，百分比使用 Segoe UI。
- `runtime/mcp.mjs`：Windows 插件的只读额度查询工具。
- `runtime/plan.mjs` / `runtime/detect-plan.mjs`：自动识别套餐并检测实际额度窗口；根目录「检测套餐.cmd」可直接运行。
- `runtime/watch.mjs` / `runtime/worker-state.mjs`：双平台共享的额度刷新与单实例 worker。
- `runtime/thread-speed.mjs`：Mac 聊天速度面板的本地计数 helper，不代表实时模型速度。
- `runtime/supervisor.ps1`：识别主窗口并自动恢复角色。
- `runtime/host-layer.ps1`：主窗口归属与遮挡顺序。
- `assets/quotes.json`：内置中文语录。
- `tests/`：额度解析、刷新队列、Windows 安装与生命周期，以及本地线程计数测试。

`installation.json` 在本机安装时生成，不包含在仓库中。Windows 默认个人数据位于 `%LOCALAPPDATA%\GPTNiangUsage\state`，停用后保留。Mac 数据位于 `~/Library/Application Support/GPTNiangUsage`；下载与安装说明见 [Mac README](../macos/README.md)。

Windows 额度气泡在原有尺寸内以两条横向额度行显示周期、剩余百分比、进度条和重置时间。只有一个额度窗口时，该行居中。展开动画结束后，前 2 秒显示简写倒计时（如「3时10分后」），后 3 秒显示时刻或日期（如「05:05 重置」「10/20 重置」），然后自动收起；再次点击角色或气泡内刷新时重新计时；菜单刷新不主动打开气泡。重置时间和更新时间均按当前 Windows 机器的本地时间显示；悬停气泡可查看完整日期、时区偏移与倒计时。缺少重置时间时会明确提示，过期的额度等待刷新。

标题右侧的刷新图标平时隐藏，鼠标移入气泡后淡淡显现，指向图标时加深。刷新和设置图标使用圆角矢量线段。中文字体从安装目录的 `assets/fonts` 加载，不安装或修改系统字体；其来源与授权见[字体说明](assets/fonts/README.md)。角色原图及其授权不变。

交互实现范围见[DSH功能对照](DSH功能对照.md)，图片生成来源见[素材说明](assets/生成说明.md)。

## 许可

代码与一般文档采用 [MIT License](LICENSE)，允许修改、分发及商用，须保留版权声明与许可文本。龙娘图片与派生角色图标不属于 MIT 授权范围，仅用于本项目及其非商业副本的挂件和项目说明展示，商业用途需另行取得相关权利人许可。详见 [角色与图片素材声明](assets/CHARACTER-NOTICE.txt)；上游语录继续按 [语录许可](assets/quotes-LICENSE.txt) 使用。

随附的霞鹜文楷字体采用 [SIL Open Font License 1.1](assets/fonts/OFL.txt)，不属于 MIT 授权范围。
