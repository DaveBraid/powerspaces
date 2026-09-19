# PowerSpaces 协作指南

本文件适用于整个仓库。面向本 fork 的开发与维护；执行任务时以用户当前需求为准，保持最小、增量、可回退的改动。

## 项目目标与当前范围

- 核心目标：让 macOS 多桌面的窗口操作稳定、可预期，尽量在当前桌面完成聚焦和新建窗口，减少意外跳转，接近 Windows 11 的虚拟桌面体验。
- 保留上游已实现的原生 Spaces、Mission Control、手势、多显示器和按应用配置策略等能力。
- 当前优化方向：支持简体中文，提升自带 Dock 的视觉与交互品质，以 macOS 原生 Dock 为体验参照。
- 当前范围：已完成 `English / 简体中文`；用户已授权将程序坞和设置窗口升级为原生 Liquid Glass。
- 主要适配与实机验证环境为 macOS 27；不因本机版本而无故提高最低部署版本。
- 用户已于 2026-09-19 授权：后续修改通过必要的构建与检查后，默认自动更新 `/Applications/Powerspaces.app` 并重新启动，无需重复询问。正常退出旧进程后替换，保留用户配置及可回退的上一版；不自动授予系统权限。用户随后授权：完成修改后自行提交 Git，阶段性推送；用一句话汇报操作。
- 开发经验集中维护于 `docs/development-experience.md`，只记录重要、可复用且有依据的结论；优先更新现有文档，不随意新增审查报告或过程记录。
- 每次功能、构建或安装流程变化时，同步更新对应文档；本 fork 的本地化与切换安装说明见 `docs/zh-CN.md`。
- 优先维护现有可用行为。中文化、视觉改造、窗口策略变更分别推进，避免在外观修改中夹带行为重写。
- 系统 Dock 点击增强、将其他 Space 的窗口移到当前桌面，属于此前讨论过的候选方案，尚未实现，也不自动纳入每次改进任务。

## 仓库事实与入口

初次扫描基准：`a448cbc`（v1.2.4）。以下路径是导航，具体行为以当前代码为准。

- 使用 Swift Package Manager；`Package.swift` 声明 Swift tools 6.0、Swift 5 语言模式、StrictConcurrency 检查及最低 macOS 14。
- 应用采用 AppKit + SwiftUI；无需完整 Xcode 即可按上游流程使用 Command Line Tools 构建。
- Swift 包当前无外部包依赖。Raycast 扩展单独使用 TypeScript / React 与 npm。
- 项目内没有 XCTest 测试 target；测试入口是独立可执行程序 `spacekit-tests`。

| 路径 | 职责与修改入口 |
| --- | --- |
| `Sources/SpaceKit/` | 共享模型、状态分类、启动决策、策略执行、窗口操作和持久化 |
| `Sources/SpaceKit/AppState.swift`、`LaunchEngine.swift` | 从窗口快照分类，再以纯函数决定聚焦、启动或新建策略 |
| `Sources/SpaceKit/SpaceProviding.swift`、`CGSSpaceProvider.swift` | 可替换的数据接口与真实 Space / 窗口快照读取 |
| `Sources/SpaceKit/Launcher*.swift` | 执行决策、新建窗口、Finder 特例和启动原语 |
| `Sources/SpaceKit/CGSPrivate.swift`、`WindowAX.swift` | CGS / SkyLight 私有符号绑定及 Accessibility 窗口操作 |
| `Sources/SpaceKit/DockModel.swift`、`DockRefresher.swift` | 根据快照和固定项生成 Dock 内容 |
| `Sources/SpaceKit/StrategyConfig.swift` | 应用策略枚举、默认值、配置加载与信任检查 |
| `Sources/PowerspacesApp/AppDelegate.swift` | 应用生命周期、多屏 Dock 编排、启动队列、通知及轮询 |
| `Sources/PowerspacesApp/DockPanel*.swift` | Dock 面板、布局、增删动画、自动隐藏及右键菜单 |
| `Sources/PowerspacesApp/DockButton.swift`、`DockDropView.swift` | 图标绘制、鼠标交互和拖放 |
| `Sources/PowerspacesApp/Preferences*.swift`、`PreferenceTypes.swift` | 设置模型、窗口及 SwiftUI 设置页 |
| `Sources/PowerspacesApp/DockTint.swift`、`DesktopIndicatorView.swift` | 桌面颜色及桌面指示器 |
| `Sources/PowerspacesApp/StatusItemController.swift`、`*WindowController.swift`、`HUD.swift` | 菜单栏、辅助窗口与提示文案 |
| `Sources/PowerspacesApp/AppleDockController.swift` | 系统 Dock 隐藏及相关偏好设置处理；没有智能点击拦截 |
| `Sources/CSpaceSwitch/`、`Sources/PowerspacesApp/FasterDesktopSwitch.swift` | C 层私有事件字段与快速切桌面封装 |
| `Sources/powerspaces/main.swift` | CLI 入口，与应用共享 SpaceKit |
| `Sources/SpaceKitTestRunner/main.swift` | 自建测试框架、假数据提供器及只读 CGS 冒烟检查 |
| `raycast-extension/` | 调用 CLI 的独立 Raycast 扩展 |
| `scripts/`、`VERSION` | 构建、打包、安装与版本号 |

### 已知文档偏差

- 旧说明中的单窗口应用 `focusOnly` 默认值已过时：Messages、系统设置等目前默认使用 `warn`；逐项核对 `StrategyConfig.defaults`。
- `focusOnly` 仍然表示直接激活应用，可能跳到其他桌面；不要悄悄改变该配置值的含义。
- `placeNewWindowHere()` 调整已经属于当前 Space 的新窗口的屏幕位置；它没有实现跨 Space 搬运已有窗口。
- `docs/design-principles.md` 中“没有后台线程”“不修改系统 defaults”等描述不能当作完整现状：代码已有串行启动队列和可选系统设置修改。
- 不根据最低部署版本或旧讨论断言特定 macOS 版本兼容；私有 API 行为需要实机验证。

## 架构与行为约束

- 保留“读取快照 → 分类 → 纯决策 → 执行副作用”的分层。新决策放入 SpaceKit，使用 `SpaceSnapshot` 和假 `SpaceProviding` 验证，避免 UI 和 CLI 各写一套规则。
- UI 更新遵守主线程 / MainActor 约束；沿用现有启动队列执行可能阻塞的操作，避免在绘制、鼠标回调中轮询窗口或执行外部进程。
- 多屏操作必须区分显示器 UUID、Space ID、Space UUID 与窗口 ID；按点击所属屏幕确定目标桌面，避免直接套用主显示器状态。
- 新增 CGS / SkyLight 窗口私有绑定集中在 `CGSPrivate.swift` 或明确隔离的底层封装；保留 `CSpaceSwitch` 现有 C 层边界，不在视图中散布私有调用。
- 延续通知优先、有限轮询、空闲退避、睡眠暂停和内容未变不重建的机制。不要为美化引入持续高频计时器、窗口截图或无界缓存。
- 保留 Accessibility 检查、超时和失败提示；AppleScript 策略可能涉及自动化权限。日常增强不应要求关闭 SIP。
- 不把策略失败改成无提示地跳桌面、退出应用或丢失用户状态。`quitReopen` 继续保持显式选择及现有确认流程。

## 中文化要求

- 建立可维护的本地化资源与统一取词方式，保留英文回退；不要把英文字符串直接批量替换成中文，也不要按语言复制整套视图。
- 界面资源位于 `Sources/PowerspacesApp/Resources/{en,zh-Hans}.lproj/Localizable.strings`；统一使用 `L10n.string` / `L10n.format`，英文键作为回退。修改时同步更新两份资源。
- 语言选择持久化到 `preferences.json` 的 `language` 字段，值为 `en` / `zh-Hans`，缺省跟随系统支持的语言。通过 `.appLanguageDidChange` 刷新界面，不触发系统设置修改。
- SwiftPM 资源由 `Package.swift` 注册，并由 `scripts/make-app.sh` 复制到应用资源目录；权限说明位于 `packaging/*/InfoPlist.strings`。系统权限弹窗语言由 macOS 决定。
- 参数预设、设置搜索表及持久化键保留稳定原文，在显示和搜索时翻译；不要把启动时翻译结果缓存进静态表。
- 覆盖设置页、搜索关键词、菜单栏、Dock 右键菜单、工具提示、欢迎页、权限说明、错误提示及辅助功能标签；系统权限说明还要考虑 `InfoPlist.strings`。
- 配置键、策略枚举 raw value、bundle ID、CLI 子命令及供程序解析的输出保持稳定，只翻译面向用户的显示内容。
- 统一术语：Space / Desktop 在普通界面称“桌面”，Dock 称“程序坞”；涉及接口和诊断时保留准确技术名称。
- 支持中文宽度、动态应用名与参数插值；避免拼接零碎译文，检查截断、换行、搜索命中和中英文切换后的布局。
- 用户未指定时跟随系统语言；不为中文化强制改变系统语言或无关默认偏好。

## Dock 视觉与交互要求

- 优先改进现有 AppKit 面板，macOS 26 起使用 `NSGlassEffectView`，旧系统回退 `NSVisualEffectView`，复用图标、布局和动画机制；不为视觉效果重写成 WebView 或引入大型依赖。
- 关注材质、圆角、描边、阴影、间距、图标比例、运行状态、悬停反馈和动效节奏；在清晰度、响应速度和能耗之间取舍。
- 外观参数放入现有偏好模型，注明单位、范围和默认值，避免散落魔法数字。
- 保留点击聚焦 / 最小化、强制新建修饰键、右键菜单、拖拽排序、固定项及自动隐藏语义。
- 检查亮色 / 暗色、减少动态效果、降低透明度、多显示器缩放、左 / 右 / 底部停靠、空列表和图标拥挤场景。
- 调整动画时遵守现有拖拽、菜单展开和动画期间的刷新保护，防止闪烁、图标重排或焦点被抢。
- 视觉改动交付前检查实际应用界面；截图应说明状态，无法实机检查时明确未验证项。

## 后续窗口策略实验

仅在任务明确涉及这些能力时实施：

- 跨桌面移窗使用新增策略（例如 `moveHere`），保留 `focusOnly` 的历史语义与旧配置兼容。
- 固定目标显示器和桌面，选择具体窗口，执行移窗，重新读取归属确认成功，再恢复 / 聚焦；处理中途切桌面、窗口关闭和重复点击。
- 私有能力需要探测与失败处理；全屏、分屏及特殊 Space 单独验证，不宣称普通窗口实验覆盖所有场景。
- 系统 Dock 点击增强需要独立的事件识别与拦截层；单纯隐藏自带 Dock 不会增强系统 Dock。
- 若实现拦截，应保留右键、拖放、长按等原生交互，并处理事件监听失效；不要依赖“先跳过去再切回来”掩盖竞态。

## 配置、代码与协作风格

- 状态路径统一由 `PowerspacesPaths` 管理：`~/.config/powerspaces/` 下的 `config.json`、`pins.json`、`preferences.json`、`dock-colors.json`。
- 新配置兼容旧文件和缺省字段，保留原子写入、读取失败处理与策略配置权限检查。测试数据使用临时目录，避免污染真实设置。
- 最小修改，保留现有接口、默认行为和上游可合并性；不顺手全仓格式化、改名或重构。
- 遵循 `.swift-format`：4 空格缩进、110 字符行宽及现有局部风格。不要在功能补丁里直接切换 Swift 6 语言模式。
- 新增或实质修改的函数用简短中文说明作用、实现思路、输入和输出；Swift 使用声明前的 `///` 文档注释，C / TypeScript 使用相应合法注释。若新增 Python 工具，则在 `def` 后使用 `'''...'''` 文档字符串。
- 关键逻辑、配置、超时、轮询频率、动画时长和参数优先使用简短中文行内注释，每条解释一个意图；不为统一语言改写所有旧注释。
- 保留版权头、GPL-3.0-only 标识和第三方声明。向上游提交时遵循 `CONTRIBUTING.md` 的 DCO 签署要求，不虚构身份。
- 中文汇报结论、改动、验证结果和必要限制，保持精炼；仅当任务确需才展开技术细节。

## 构建与验证

在仓库根目录执行：

```bash
swift build --build-system native    # 编译 Swift / C targets
swift run spacekit-tests             # 运行现有测试入口，成功退出码为 0
swift run --build-system native PowerspacesApp --check-localization # 校验资源、参数与语言持久化，仅写临时目录
swift run --build-system native PowerspacesApp --preview-settings   # 独立设置预览，不启动桌面管理或使用真实配置
swift run --build-system native PowerspacesApp --preview-appearance # 设置与静态示例程序坞，使用临时配置
./scripts/make-app.sh                # 按需构建 release 并组装本地 Powerspaces.app
```

- 修改状态分类、启动决策、Dock 模型、配置兼容等逻辑时，在现有测试运行器补充有意义的案例，并执行构建和测试；不要用 `swift test` 替代该入口。
- 测试末尾的 CGS 集成冒烟项允许在系统接口不可用时跳过；跳过不代表真实桌面交互已经通过验证。
- 纯文档修改检查内容、路径和 diff 即可；简单文案 / 外观改动不添加机械测试，但应进行对应的构建或视觉检查。
- 改动 Raycast 扩展时，使用其锁文件安装依赖，并在该目录运行 `npm run lint`、`npm run build`。
- 打包脚本会重建仓库内 `.app`、附带 CLI 和 Raycast 源码并签名；本机使用仓库外的固定代码签名证书，由 scripts/sign-app.py 读取，配置存在而不可用时禁止回退临时签名。本地构建不等于 Developer ID 签名或公证发布。
- 安装脚本会替换目标目录中的应用，可能调用 sudo；不要把安装、启动应用、修改系统 Dock 或运行卸载流程作为普通编译检查。用户已授权相关操作时按范围执行。
- 不通过 sudo 运行整套构建，不提交 `.build/`、`.app`、`node_modules/` 等生成物。
- macOS 27 的当前 Command Line Tools 缺少 `SwiftUIMacros` 插件；`ViewState` 显式引用原有 `SwiftUI.State<Value>` 属性包装器，避免选择同名宏。维护时不要无依据地改回 `@State`。
- 涉及窗口行为时按改动范围验证：当前桌面有窗口、仅其他桌面有窗口、进程无窗口、最小化 / 隐藏、重复点击、切桌面竞态、多屏及权限缺失。报告实际验证项，区分自动测试和实机结果。

- 本机默认 swiftbuild 后端误将 SDK 标记为 14.0；应用构建和预览暂用 `--build-system native`。交付前用 `xcrun vtool -show-build` 确认真正的 SDK 版本，最低部署版本仍保留 14.0；不要用修改 Mach-O 的方式伪造 SDK。
- macOS 27 程序坞透光调节隔离于 `GlassBackgroundTuning.swift`，使用经探测的私有玻璃滤镜参数；保留版本限制、原值恢复及失效回退，不修改系统全局设置或增加定时轮询。设置窗口不使用该调节。
- 外观设置分开维护材质、明暗与背景不透明度；运行 `--check-appearance` 检查旧配置兼容，系统“降低透明度”优先于应用滑块。

- 原生 Dock 配方封装于 `NativeDockMaterial.swift` / `CDockMaterial`；私有 ABI 当前仅验证 Apple Silicon、macOS 27.0 构建 26A428。扩展白名单前必须重新核对类型布局和后台渲染；保持动态符号探测、公开材质回退及非激活面板行为。`--check-native-dock` 验证这条路径。
