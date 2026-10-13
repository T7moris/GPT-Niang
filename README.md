# GPT-Niang（GPT 娘）

让一只白发紫瞳的小龙娘，陪你看 Codex 的剩余额度。

**Windows / macOS 桌面挂件 · 自动识别套餐与额度窗口 · 中文语录 · 当前正式版 1.3.4**

1.3.4 按 PR #20 的只移动窗口方案整合 Windows DPI 修复，并补齐 Business 个人额度的双平台兼容。交互以 Windows 为基准：Mac 连续点击不再打开设置，支持相同的大小范围、桌面置顶开关和独立位置保存；保留 SwiftUI／AppKit 原生实现及双平台自动更新、回滚与历史版本清理。

[**下载最新版**](https://github.com/T7moris/GPT-Niang/releases/latest) · [Windows 安装](#windows-安装) · [macOS 安装](#macos-安装) · [更新记录](更新记录.md) · [反馈问题](https://github.com/T7moris/GPT-Niang/issues/new)

<img src="gpt-niang-usage/assets/gpt-dragon-niang-bust.png" alt="无嘴巴的白发龙娘半身形象" width="240">

## 能做什么

- **点角色看额度**：按接口实际返回的窗口显示剩余百分比，例如 5 小时、每周、30 天；单个窗口在原气泡内居中，横条越满，剩余额度越多。成功查询时折叠未返回的整条窗口；查询失败会显示异常，重置时间为空时仍保留百分比。
- **点气泡看语录**：再点收起，显示完成约 5 秒后也会自动收起；支持编辑自己的语录。
- **按压与回弹**：半身角色、分段气泡动画和轻提示音，可调整音量或静音。
- **拖动与缩放**：靠近左右边缘吸附，角色面向窗口内侧，文字保持正向。
- **跟随主窗口**：失去焦点时保留；其他窗口覆盖主窗口时，也会覆盖挂件。最小化或隐藏主窗口后挂件隐藏。Windows 和 Mac 均可在设置中关闭跟随，让挂件留在桌面。
- **登录启动**：Windows 安装器默认配置自动启动和主窗口重开后的恢复；Mac 需要自行开启设置中的「登入 Mac 時自動開啟」。
- **Mac 聊天速度面板**：从菜单栏打开，显示本地统计区间内的输出平均速度，包含推理、网络和工具等待，**不代表模型实时生成速度**。

这是独立的桌面挂件；Windows 同时提供额度查询插件，Mac 为原生应用，不注册 MCP 插件。它读取当前 Codex 登录账户的额度，**不会为读取额度创建聊天或调用模型**。它不是 OpenAI 或 DeepSeek 的官方项目。


### 两端一致的操作

| 操作 | Windows / macOS 1.3.4 行为 |
| --- | --- |
| 单击、双击、连续点击角色 | 普通点击：看额度／续时；开启点击切换选项后切换语录与收起；均有按压和回弹 |
| 点击气泡 | 额度 → 语录 → 收起；刷新按钮单独执行刷新 |
| 右键角色 | 原生菜单；不会把连续点击转换为设置操作 |
| 调整大小 | 60%–250%；80%、100%、140% 预设；拖动和定位只移动窗口 |
| 桌面模式 | 跨屏自由拖动；置顶默认关闭，仅此模式可切换；与窗口模式分别保存位置 |
| 刷新与语录 | 刷新不强制打开气泡；支持 `3 | 语录` 权重，恢复前备份自定义文件 |
| Business | 个人额度优先，另显示最短时间窗口；其余窗口在详情中保留；个人额度不是公司总余额 |

Mac 设置使用 SwiftUI，菜单、窗口与拖动使用 AppKit；没有运行 PowerShell、WPF 或 Windows 更新器。界面可选择跟随系统、简体中文或繁体中文，切换语言不会改写自定义语录。安装／登录启动入口、Windows MCP 插件和 Mac 聊天速度面板保持各平台现有支持范围。

### Windows 形象选择与显示改进（源码）

以下改进目前提供于源码，现有 1.3.4 正式安装包尚未包含：

- **形象选择**：在「外观设置」中选择挂件形象，重新启动后保留选择。
- **自定义图片**：添加自己的图片，或移除已添加的形象；内置默认形象为「龙娘1」。推荐使用透明背景 PNG，详细操作见[形象选择指南](docs/WINDOWS-CUSTOMIZATION.md)。
- **更平滑的缩放**：改善挂件缩小时的锯齿，让不同尺寸的形象显示更自然。
- **更易读的额度气泡**：突出百分比，简化重置提示；修复 Pro 账号仅显示一行周额度时的刷新按钮错位。
- **音量修复**：重新打开挂件后，保留之前设置的音量。
- **连续点击音效修复**：修复连续点击后音效只播放后半段或不再出声的问题。

形象选择和上述界面、音效改进目前仅支持 Windows；macOS 继续使用原生界面，两端共用内置语录。

## 套餐适配与自动检测

Windows 与 macOS 共用按实际返回值解析的后端。自动识别 Free、Go、Plus、Pro、Team、Business、Enterprise、Edu；遇到未来套餐保留其标识。**套餐名称不决定显示哪些窗口，也不代表额外授予接口权限**。Go 的 30 天窗口是 `43200` 分钟；其他合法时长也会显示为小时、天或分钟，不再被白名单过滤。`primary` / `secondary` 只是接口槽位，窗口按自身时长识别并排序；`43800` 等非 30 天时长同样可显示。整合 PR #9 时沿用当前代码和准确时长标签，因此 Go 保持「30 天」，单个窗口仍居中。两个平台保留原来的气泡外观、单行居中、刷新、重置时间和动画行为。

Windows 双击根目录 `检测套餐.cmd`，或执行 `powershell.exe -NoProfile -File .\gpt-niang-usage\Detect-Plan.ps1 -Json`。从源码检查 Windows / macOS 均可执行：

```sh
node gpt-niang-usage/runtime/detect-plan.mjs --json
```

Mac 已安装应用也可执行（将应用路径替换为自己的安装位置）：

```sh
node /Applications/GPTNiangMac.app/Contents/Resources/Backend/runtime/detect-plan.mjs --json
```

脚本通过同一套只读 `account/read` 与 `account/rateLimits/read` 自动读取套餐标识，优先使用额度桶中的 `planType`，未提供时使用账号返回的套餐；不读取或输出令牌、邮箱和聊天。切换套餐后下一次刷新会重新识别，套餐变化会使旧快照失效。API Key 登录、未登录、接口查询失败和成功但没有额度窗口会分别提示，成功但没有窗口不被当成网络错误。

[PR #8](https://github.com/T7moris/GPT-Niang/pull/8) 的 Go 实测表明原接口已经成功返回 30 天窗口，原后端的 `[300,10080]` 白名单和 Windows 固定按分钟数查找两行才是显示失败的原因。切换套餐可能改变 `planType`、窗口时长、窗口数量和重置时刻；额度读取方法仍是同一个。实际 HTTP／登录错误应根据返回错误单独检查，不能仅凭套餐名称判断。协议字段见 [OpenAI App Server 文档](https://learn.chatgpt.com/docs/app-server)。

## 安装

两边都需要 **Node.js 20 或更新版本**，以及已安装并用 ChatGPT 账号登录的 **Codex 桌面端**。下载包不附带 Node.js；缺少时请先从 [Node.js 官方网站](https://nodejs.org/) 安装。

在 [Release 下载页](https://github.com/T7moris/GPT-Niang/releases/latest) 的 **Assets** 中选择自己的系统：

| 系统 | v1.3.4 安装包 | 安装入口 |
| --- | --- | --- |
| Windows 10 / 11 | [gpt-niang-usage-widget-v1.3.4-windows.zip](https://github.com/T7moris/GPT-Niang/releases/download/v1.3.4/gpt-niang-usage-widget-v1.3.4-windows.zip) | 解压后运行 `安装GPT娘.cmd` |
| macOS 13+，Apple Silicon / Intel | [gpt-niang-usage-widget-v1.3.4-macos-universal.zip](https://github.com/T7moris/GPT-Niang/releases/download/v1.3.4/gpt-niang-usage-widget-v1.3.4-macos-universal.zip) | 解压后打开 `GPTNiangMac.app` |

GitHub 自动附带的 **Source code** 和 **Code → Download ZIP** 是源码，不是上述安装包。Mac 下载包内已包含通用应用，不需要 Swift 或 Xcode；Intel 和较旧 macOS 的实际界面表现仍需真机验证。尚无 Linux 版本。

### Windows 安装

1. 下载 Windows ZIP，将压缩包**完整解压**到准备长期保留的位置；保留 `.agents` 与 `gpt-niang-usage` 文件夹。
2. 双击根目录的 **`安装GPT娘.cmd`**，等待安装完成。**不需要管理员权限，也不需要 git**。
3. 打开 Codex 主窗口，龙娘会自动出现。额度查询工具可在新建的聊天中使用。

安装器会查找 Node.js 与 Codex，注册一个本地路径插件市场及其中的只读额度查询工具，在当前用户的启动文件夹创建快捷方式，并注册登录时自动启动的用户级计划任务。偏好与额度快照写入 `%LOCALAPPDATA%\GPTNiangUsage\state`。它不写注册表、不安装系统服务、不修改系统安全策略。

### macOS 安装

1. 下载 Mac ZIP，解压后把 **`GPTNiangMac.app`** 移入「应用程序」或其他准备长期保留的位置。
2. 打开应用，再打开 Codex 主窗口。Mac 不使用 `.cmd` 或 PowerShell 安装器。
3. 右键角色打开原生菜单，从「设置」进入原生设置窗口，也可从悬停按钮或菜单栏进入。双击和连续点击角色与 Windows 一样执行普通点击，不再打开设置。需要登录启动时，再开启 **「登入 Mac 時自動開啟」**；系统可能要求在「登录项」中批准。
4. 在菜单栏选择 **「聊天速度…」**，可打开独立的本地速度面板。

Mac 包仅有本地签名（ad-hoc），未使用 Apple Developer ID 签名、未经过 Apple 公证。首次打开可能被系统阻止；确认来源并核对下面的 SHA256 后，按 [Apple 官方说明](https://support.apple.com/102445) 在「系统设置 → 隐私与安全性」确认打开。

Mac 的位置跟随目标为 60 Hz，仍使用轮询，不能保证拖动时零延迟；多窗口选择、快速拖动和旧系统的表现仍需真机验证。完整功能、源码构建和诊断说明见 [macOS 使用说明](macos/README.md)。

### 安装包校验（建议）

同一 [v1.3.4 Release](https://github.com/T7moris/GPT-Niang/releases/tag/v1.3.4) 的 **[SHA256SUMS.txt](https://github.com/T7moris/GPT-Niang/releases/download/v1.3.4/SHA256SUMS.txt)** 包含两个包的校验值。下载后计算自己的安装包哈希，与文件中**同名文件**的一行比较。

Windows，在 PowerShell 中运行：

```powershell
Get-FileHash .\gpt-niang-usage-widget-v1.3.4-windows.zip -Algorithm SHA256
```

macOS，在终端中进入下载目录后运行：

```sh
shasum -a 256 gpt-niang-usage-widget-v1.3.4-macos-universal.zip
```

十六进制字母大小写不影响比较。哈希不一致说明下载文件与 Release 校验值不一致，可能是下载损坏或内容被改动，请不要安装。请只从本仓库的 Release 页面下载；第三方加速镜像不能当作可信来源。

## 让 AI 帮你装

把对应系统的这段发给能在你电脑上执行命令的 AI。

**Windows：**

> 从 https://github.com/T7moris/GPT-Niang/releases/latest 下载 Windows 安装包与 SHA256SUMS.txt，先核对来源和哈希，再完整解压到长期保留的位置（例如 `%LOCALAPPDATA%\Programs\GPTNiangUsage`），运行 `安装GPT娘.cmd` 并告诉我结果。先检查 Node.js 20+ 和 Codex 的 ChatGPT 登录状态。

**macOS：**

> 从 https://github.com/T7moris/GPT-Niang/releases/latest 下载 macOS 通用安装包与 SHA256SUMS.txt，先核对来源和哈希，再解压并将 `GPTNiangMac.app` 放入「应用程序」。检查 Node.js 20+ 和 Codex 的 ChatGPT 登录状态，打开应用并告诉我结果。若系统要求首次打开确认，请告诉我具体提示，由我在系统设置中确认。

## 使用

| 操作 | 效果 |
| --- | --- |
| 点角色 | 查看剩余额度；已在额度页时重新计时 |
| 点额度气泡 | 切换到随机语录 |
| 再点语录气泡 | 收起气泡 |
| 拖动角色 | 跟随模式调整主窗口内位置；桌面模式可拖到其他显示器 |
| 右键角色 | 打开设置，调整大小、声音、语录与位置 |
| Windows：双击 `打开GPT娘.cmd` | 手动恢复显示；重复打开不会叠加第二只 |
| Windows：菜单选择「退出 GPT 娘」 | 跟随模式本次主窗口会话中退出；桌面模式暂停自动恢复，运行「打开GPT娘.cmd」可重新打开 |
| Windows：双击 `停用GPT娘.cmd` | 停用自动显示，移除任务、启动项与插件登记，保留程序文件与偏好 |
| Mac：右键菜单、悬停按钮或菜单栏进入设置 | 调整外观、显示模式、桌面置顶和登录启动；连续点击不打开设置 |
| Mac：菜单选择「退出 GPT 娘」 | 退出应用和后台 helper；需重新打开 `.app` 才会再次显示 |

Windows / macOS 1.3.4：右键角色，从原生菜单／设置进入「显示与位置」，选择「仅在 Codex 窗口内」或「整个桌面自由拖动」。桌面模式中挂件会在聊天窗口最小化或关闭后继续显示，并按默认间隔刷新额度；仅此模式显示「始终置顶」。切回窗口内立即取消桌面置顶，并隐藏该选项；桌面置顶偏好保留，默认关闭。两种模式分别保存位置，原有大小、声音与语录设置保留。「外观设置」统一调整大小与按钮显示，「声音与点击」调整音效、音量和点击行为。

Windows 启动时先检查 Codex 的输入或导航控件是否可用，连续两次确认主界面就绪后才显示挂件；加载画面中的原生窗口本身不会触发显示。已启动的桌面模式继续独立显示。

源码内置 **45 句**语录，保留原有台词并补充龙娘日常语录，Windows 与 macOS 共用。现有 1.3.4 正式安装包仍包含此前的 33 句；下载时请核对对应版本的 `SHA256SUMS.txt`。

升级会保留各台电脑的自定义语录。若要使用这份内置台词池，在语录设置里选择「恢复内置语录」（Mac 为「恢复默认」）；恢复前请备份自行添加的句子，Windows会自动保留旧列表备份。自定义文件只保存在本机，不会随账户同步到另一台电脑。

语录变色彩蛋默认按每句独立抽取：全挂件变色 **0.5%**、仅文字变色 **3%**、原色 **96.5%**。

## 数据与隐私

- 额度通过本机 Codex App Server 查询。项目没有自己的云服务器、遥测或外部上传功能。
- 不保存登录凭据、邮箱或对话正文；状态文件保存额度数字、时间、显示偏好、运行状态，以及用于隔离账号快照的身份哈希。无法确认账号时清空旧额度；同账号刷新失败时明确标记旧快照。
- Mac 聊天速度面板会只读本机线程索引和会话日志，提取标题、输出计数和时间戳，不输出或保存对话正文。仅在面板打开时运行，每 3 秒更新；关闭面板或退出应用时停止。Codex 内部日志格式变化可能使指标不可用。
- 当前账号识别使用邮箱和套餐，无法可靠区分同邮箱、同套餐下的组织切换；切换组织后应手动刷新额度。
- 超过 3 分钟的数据标为旧快照；重置时间已到时等待新数据，不擅自把额度补为 100%。
- 使用 API Key 登录或接口不可用时显示读取异常；成功查询但没有相应额度窗口时折叠该窗口，不根据套餐名称猜测支持情况。
- 两边共用单实例额度 worker 实现，可见时默认每 60 秒查询一次，隐藏时暂停。Windows 的界面、MCP 与控制命令复用此 worker；Mac 原生应用启动自己的 worker，不注册 MCP 插件。
- Windows 的位置跟随使用事件更新和每秒兜底检测；Mac 对选定窗口按目标 60 Hz 采样、每秒 4 次重新发现窗口。提高位置更新频率不会同时提高额度查询频率。

默认数据位置：

| 系统 | 目录 |
| --- | --- |
| Windows | `%LOCALAPPDATA%\GPTNiangUsage\state` |
| macOS | `~/Library/Application Support/GPTNiangUsage` |

`installation.json` 由本机生成，不随安装包分发。本仓库不包含本机安装配置、账户快照或聊天截图；只发布作者确认的内置语录，不上传用户数据目录里的自定义文件。

## 更新、移动与卸载

### Windows

在设置菜单的「更新」中可手动「检查并更新」，也可关闭或开启自动更新。自动更新默认开启，启动 30 秒后检查，此后每 24 小时检查；下载在后台进行，安装会等待挂件空闲。仅安装官方 GitHub Release 的更高正式版，预发布及同版本重新打包不更新。Git 源码目录请继续使用 Git 更新。

更新保留安装路径、位置、缩放、声音、自定义语录及自动更新开关。下载后校验 SHA256 和包结构；哈希验证不能防止发布者账号被攻破，也不等同源码安全审查。更新不读取 GitHub/OpenAI 登录凭据，不支持镜像或自定义下载源。

安装期间额度查询会提示稍后重试。安装失败会恢复旧程序，重启时会先处理未完成的更新。新版注册与后台心跳确认成功，或旧版回滚成功后，自动清理对应的旧版备份、失败版本、临时目录与下载缓存；取消下载后的安装也会清理缓存。文件被占用导致清理失败时，下次启动会重试，即使已关闭自动更新也会执行清理；清理完成前不继续下载新版本，避免历史文件累积。清理只处理本次更新记录及带有当前安装归属记录的缓存，不删除用户偏好。安装目录旁的个人截图、手动下载包和其他非程序文件会在替换前校验并保留；同名冲突会在关闭挂件前取消更新。

若恢复失败，恢复所需文件继续保留，请保留上一版备份和 `%LOCALAPPDATA%\GPTNiangUsage\update-agent` 中的 `update-diagnostic.txt`，修复占用或权限问题后再处理，程序不会继续自动重试。清理失败的原因记录在同目录的 `update-cleanup-error.txt`。

手动升级时，在**原目录**覆盖新版文件，再运行 `安装GPT娘.cmd`；安装器保留原有数据目录和偏好。安装前请先备份自定义内容。

需要移动文件夹时，先在原目录运行 `停用GPT娘.cmd`，等待停用完成，再移动并重新安装。安装器允许已停用、旧路径已不存在的目录迁移，并保留原数据目录与偏好。复制仍存在的旧安装目录或直接移动运行中的目录会被拒绝。

要彻底移除：

1. 运行 `停用GPT娘.cmd`，移除计划任务、启动快捷方式、插件与市场登记并停止进程。
2. 删除整个程序目录。
3. 如需清除偏好、自定义语录和额度快照，再删除 `%LOCALAPPDATA%\GPTNiangUsage`。

停用脚本在偏好目录已被删除时也能完成停用。直接在任务管理器中结束挂件会被守护进程恢复；要停用请使用上述脚本。

### macOS

1.3.3 起，在原生设置的「版本与更新」中检查更新、查看版本或关闭自动更新；菜单栏也提供「检查更新」。启动 30 秒后自动检查，此后每 24 小时一次，默认开启。仅安装官方 Release 的更高正式版。

下载与 SHA256、包结构、应用签名和双架构校验通过后，等待拖动、刷新、菜单和设置／聊天速度窗口结束，再由独立 Swift 助手替换原位置的 `.app`。新版窗口与额度后台完成启动确认后，自动清理上一版与下载缓存；失败时先退出新版、恢复并重开旧版。恢复未完成时保留恢复文件，诊断位于数据目录的 `mac-update-diagnostic.txt`。关闭自动更新仍会在下次启动重试已经完成的更新清理。

偏好、自定义语录和额度数据保留在 `.app` 外的用户数据目录中。更新不调用 Windows PowerShell 更新器，也不要求安装 Swift／Xcode。请将应用放到当前用户可写的应用程序目录，先退出应用再移动；源码目录使用 Git 更新。

1.3.2 及更早版本尚无内置更新，需要先退出 GPT 娘，再手动替换原位置的 `.app`，首次升级到 1.3.3 后即可使用内置更新。本版仍为 ad-hoc 签名、尚未 Apple 公证，签名完整性检查不等同 Developer ID 身份验证；系统要求打开确认时需由用户按系统提示操作。

移动应用前先关闭登录启动，退出应用，移到新位置后重新打开，需要时再开启登录启动。

卸载时先关闭登录启动，退出应用，再删除 `.app`。这会保留个人数据；如需一并清除，再删除 `~/Library/Application Support/GPTNiangUsage`。不要删除 Codex 自己的登录或会话目录。

## 常见问题

**看不到角色？** 确认 Codex 主窗口已打开且没有最小化。Windows 可运行 `打开GPT娘.cmd`；Mac 确认 GPT 娘应用正在运行，可在设置中关闭跟随以检查桌面显示。如果其他应用盖住主窗口，跟随模式下挂件也会被盖住。

**额度数字不更新？** 点击气泡里的刷新按钮，检查 Codex 的 ChatGPT 登录状态；Mac 也可从菜单栏刷新。成功查询但账户未提供的窗口会整条折叠；读取异常时显示 `—` 或明确标记为上次同账号的额度。

**Codex 更新之后额度一直显示 `—`？** 挂件会重新寻找当前 Codex 可执行文件。Windows 可重跑 `安装GPT娘.cmd`；Mac 可退出并重开 GPT 娘，检查 Node.js 和 Codex 登录状态。原有偏好会保留。

**Mac 提示找不到 Node.js？** 下载包不附带 Node.js。安装 Node.js 20+ 后退出并重新打开 GPT 娘；自定义 Node 路径及开发启动方式见 [macOS 使用说明](macos/README.md)。

**Mac 无法打开应用？** 本版未经过 Apple 公证。先检查下载来源和 SHA256，再按 [Apple 官方说明](https://support.apple.com/102445) 查看「隐私与安全性」中的提示。

**Mac 聊天速度显示 `—`？** 至少需要两笔有效计数记录，且 Codex 本机日志格式必须兼容。面板显示的是统计区间平均值；不是实时测速，也不是缺少数据时自动估算。

**Windows 旧安装占用了自动启动任务？** 先从旧目录运行停用脚本，再安装新版。安装器会拒绝覆盖不属于当前目录的启动项。

**使用挂件会有封号风险吗？** 查询使用 [Codex 官方 App Server 文档](https://learn.chatgpt.com/docs/app-server) 中的 `account/read` 与 `account/rateLimits/read`，由本机 Codex 复用现有登录；这条查询链不创建聊天、不发起模型生成、不共享登录凭据，也不绕过额度限制。默认可见时每 60 秒查询一次，隐藏时暂停。但官方未对第三方额度挂件给出免封承诺；[使用条款](https://openai.com/policies/terms-of-use/) 对自动化提取数据、账号共享及绕过限制均有约束，成功读取不能证明永久合规或零风险。请保留默认查询频率，接口拒绝访问时不要改为绕过认证或限制。

**Windows 杀毒软件或 SmartScreen 报警？** Windows 包里没有 exe / dll，使用 PowerShell、VBS 与 Node 脚本。由于安装链使用 `-ExecutionPolicy Bypass`、隐藏窗口常驻并注册登录任务，未签名脚本包可能被启发式规则误报。请先核对 Release 的 SHA256 和来源，再决定是否放行；设备策略不允许运行脚本时请不要绕过策略。

**Windows 系统或企业策略阻止脚本？** Windows 版依赖 PowerShell / WPF、Windows Script Host 和当前用户计划任务。请遵循设备管理策略；项目不会修改系统安全策略。

## 开发与验证

无需安装 npm 依赖。两边都可在仓库根目录运行共享运行时测试：

```sh
cd gpt-niang-usage
node --test tests/*.test.mjs
```

Windows 上继续运行安装、生命周期与 WPF 测试：

```powershell
npm run test:windows
```

只检查 Windows 安装条件，不创建任务、不安装插件（在仓库根目录运行）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\gpt-niang-usage\Install.ps1 -CheckOnly
```

Mac 上在仓库根目录运行：

```sh
swift test --package-path macos
./script/build_and_run.sh --build-only
codesign --verify --deep --strict dist/GPTNiangMac.app
```

打包与发布流程见 `.github/workflows/release.yml`。两个平台测试、构建与校验都通过后，才发布同一个 Release 和两个独立安装包。

Windows 界面使用 PowerShell / WPF，Mac 界面使用 SwiftUI / AppKit，额度查询使用共享 Node.js 后端。窗口识别与接口依赖当前 Codex 桌面端实现，后续客户端更新可能需要适配。实际拖动、多窗口切换及 Intel / 较旧 macOS 的界面行为仍需真机验证，CI 通过不等于完成所有桌面交互测试。

## 反馈与参与

遇到问题可以 [提交中文问题反馈](https://github.com/T7moris/GPT-Niang/issues/new)。请说明操作系统、CPU 架构（Mac）、Codex 与挂件版本、复现步骤以及期望效果；截图请裁去对话、账号和其他私人信息。不要上传登录文件或整个状态目录。

欢迎改进窗口兼容性、安装流程和可读性；改动后请运行相应平台的检查。角色为静态半身配合按压动画，不包含完整桌宠动作。

## 致谢与许可

以下按 GitHub 用户名排列，记录代码、方案、审查、问题复现与功能建议。感谢每一位参与者；已合并代码、待审方案和开放建议分别标明状态。

状态核对日期：2026-10-12。后续进展见对应 PR／Issue。

| 贡献者 | 具体贡献与关联 PR／Issue | 当前状态 |
| --- | --- | --- |
| [@Admilkk](https://github.com/Admilkk) | [PR #1](https://github.com/T7moris/GPT-Niang/pull/1)：动态额度展示、账号快照隔离、单实例刷新、进程恢复与安装／生命周期回归；[PR #16](https://github.com/T7moris/GPT-Niang/pull/16)：Windows 内置更新、校验、失败回滚和中断事务恢复，整合于 [PR #17](https://github.com/T7moris/GPT-Niang/pull/17)；[PR #20](https://github.com/T7moris/GPT-Niang/pull/20)：修复 Windows 拖动与定位时原生尺寸回写导致的持续放大，改为只移动窗口、由 WPF 管理尺寸，并补充窗口内／桌面模式及不同 DPI 的连续拖动回归；[PR #12 审查](https://github.com/T7moris/GPT-Niang/pull/12#pullrequestreview-5484203142)：指出个人额度的空分钟数会破坏 macOS 解码，并建议补充混合额度兼容测试。 | PR #1／#16／#20 已合并；PR #12 个人额度兼容审查已在 1.3.4 补齐 |
| [@FusaishiHaruaki-afk](https://github.com/FusaishiHaruaki-afk) | [PR #8](https://github.com/T7moris/GPT-Niang/pull/8)：真实 Go 账号的 30 天窗口复现、后端／Mac 适配及可选 `GPT_NIANG_SDK` 构建参数；[PR #9](https://github.com/T7moris/GPT-Niang/pull/9)：按窗口自身时长分类，覆盖槽位互换、月度边界与未知时长，并提供 Go 回归及 Swift 标题验证；相关实现与回归由 [PR #10](https://github.com/T7moris/GPT-Niang/pull/10) 整合。 | PR #8／#9 已合并；当前标签沿用整合后的精确时长显示 |
| [@gyb13451576](https://github.com/gyb13451576) | [Issue #11](https://github.com/T7moris/GPT-Niang/issues/11)：提供 v1.3.1 混合 DPI 双屏环境中重启 Codex 后窗口塌缩为 2×2 的复现、DPI 反馈循环分析、固定设计尺寸与 DIP／物理像素换算方案，以及自动测试和实际 HWND 采样验证；关联 [Issue #2](https://github.com/T7moris/GPT-Niang/issues/2)。 | 问题报告保持开放；PR #20 已合入拖动／定位的尺寸回写修复，重启后的 2×2 塌缩仍待验证 |
| [@insightlacyrina](https://github.com/insightlacyrina) | [Issue #14](https://github.com/T7moris/GPT-Niang/issues/14)：建议增加可持久化的「双击角色打开设置」开关，保留其他设置入口，并提出 macOS 简体中文界面建议；描述了连续点击被设置窗口打断的场景。 | 1.3.4 按维护者最新要求取消双击设置；简／繁体与跟随系统选择已实现 |
| [@JCyxMio](https://github.com/JCyxMio) | [PR #12](https://github.com/T7moris/GPT-Niang/pull/12)：提出 Windows 多屏／混合 DPI 修复、Business `individualLimit` 个人额度显示，以及套餐标题、刷新按钮布局和命中修复；提供重复尺寸、额度解析及 WPF 验证。 | 方案整合于 1.3.4；DPI 定位以 PR #20 为准，并补齐 macOS 个人额度解码与显示 |
| [@maolilup](https://github.com/maolilup) | [PR #13](https://github.com/T7moris/GPT-Niang/pull/13)：针对 [Issue #2](https://github.com/T7moris/GPT-Niang/issues/2)，提出使用固定设计宽高计算跟随／拖动尺寸以避免 DPI 尺寸漂移，并提供不同设计画布、缩放与目标 DPI 下的连续原生尺寸回归。 | 固定设计尺寸与回归已适配到 1.3.4；原生调用保持只移动 |
| [@meaqua9420](https://github.com/meaqua9420) | [PR #3](https://github.com/T7moris/GPT-Niang/pull/3)：SwiftUI／AppKit 原生 macOS 挂件、原有气泡／动画／配色／音效移植、窗口跟随与原生点击设置、菜单栏和可选登录启动；新增只读本地聊天速度面板、Mac CLI 与 worker 锁支持、应用构建及双平台 CI。 | 已合并 |
| [@ShiroasabaMio](https://github.com/ShiroasabaMio) | [Issue #2](https://github.com/T7moris/GPT-Niang/issues/2)：报告 v1.2.3 跨不同 DPI 显示器移动时挂件放大、跳动与错位，提供 120／144 DPI 复现、尺寸反馈循环分析、固定设计尺寸与统一 DPI 上下文建议及本机修复结果。 | 问题报告保持开放；PR #20 已合入拖动修复，跨屏场景继续验证，其他方案见 PR #12／#13 |
| [@T7moris](https://github.com/T7moris) | 项目创作、维护、集成与发布。[PR #5](https://github.com/T7moris/GPT-Niang/pull/5)：Mac 跟随采样、限频与多窗口选择；[PR #6](https://github.com/T7moris/GPT-Niang/pull/6)：1.3.0 双平台安装包、版本与发布校验；[PR #7](https://github.com/T7moris/GPT-Niang/pull/7)：下载、安装、退出、迁移和卸载说明；[PR #10](https://github.com/T7moris/GPT-Niang/pull/10)：套餐自动识别与动态额度整合；[PR #17](https://github.com/T7moris/GPT-Niang/pull/17)：双平台内置更新、自动清理和 Mac 原生回退；[PR #18](https://github.com/T7moris/GPT-Niang/pull/18)：MIT 代码许可、素材使用边界及文档名称统一；[PR #21](https://github.com/T7moris/GPT-Niang/pull/21)：以 PR #20 为准整合 DPI、Business 个人额度、原生 Mac 交互与语言，补齐回归、旧偏好迁移和 1.3.4 双平台发布。 | 前述维护与整合 PR 已合并；PR #21 为 1.3.4 的统一整合 |
| [@TheRuabit](https://github.com/TheRuabit) | [PR #4](https://github.com/T7moris/GPT-Niang/pull/4)：安装器直接按 UTF-8 解码插件列表 JSON，避免 Windows 默认编码造成中文安装路径乱码。 | 已合并 |
| [@wzc20090621-gif](https://github.com/wzc20090621-gif) | [PR #15](https://github.com/T7moris/GPT-Niang/pull/15)：Windows 独立桌面模式、跨屏拖动和两种模式的位置保存，解除主窗口归属／裁切并支持桌面置顶；增加本机管道额度通信与文件队列回退，修复安装后的 Node／MCP 绝对路径配置。 | 已合并 |

本次完整致谢记录由 [@T7moris](https://github.com/T7moris) 在 [PR #19](https://github.com/T7moris/GPT-Niang/pull/19) 中补充。

交互参考 [@MeteorNOX](https://github.com/MeteorNOX) 的 [DeepSeek-Balance-Whale-Widget](https://github.com/MeteorNOX/DeepSeek-Balance-Whale-Widget)，感谢其公开的交互参考与 7 句上游语录来源。Windows WPF 与 Mac 原生界面分别实现，语录包含原创、用户提供及上游文本，来源和 MIT 许可见 [语录许可](gpt-niang-usage/assets/quotes-LICENSE.txt)。使用合成提示音，没有打包 DSH 原角色、动图或音效。具体对照见 [功能对照](gpt-niang-usage/DSH功能对照.md)。

## 许可与素材使用

Copyright © 2026 T7moris 及项目贡献者。代码和一般文档采用 [MIT License](LICENSE)，允许使用、修改、分发和商用，分发时应保留版权声明与许可文本。

| 内容 | 使用许可 |
| --- | --- |
| 代码与一般文档 | MIT License，可修改、分发及商用，保留版权与许可声明 |
| 龙娘图片、派生角色图标及图片副本 | 不属于代码的 MIT 授权范围；仅允许在本项目及其非商业副本中作为挂件或项目说明展示和分发，保留素材声明；商业用途需另行取得相关权利人许可 |
| 内置语录中的 7 句上游文本 | 按 [语录许可](gpt-niang-usage/assets/quotes-LICENSE.txt) 保留 MeteorNOX 的原始 MIT 版权与许可声明 |

龙娘图由 ImageGen 根据用户提供的角色参考生成，并非本项目对参考图或参考角色的版权声明。**参考图、角色设计及相关第三方素材的权利归各自权利人所有，代码开源不代表图片或角色可以随意商用。** 未经相关权利人授权，不得将角色或图片用于商业产品、广告、周边销售、收费素材包等用途，也不得作为独立素材包分发。需要商业使用代码时，可替换为具有适当授权的图片。

完整范围与使用条件见 [角色与图片素材声明](gpt-niang-usage/assets/CHARACTER-NOTICE.txt)，生成来源见 [素材说明](gpt-niang-usage/assets/生成说明.md)。
