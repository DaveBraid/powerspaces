# macOS 27 中文与 Liquid Glass 适配

本 fork 优先解决 macOS 多桌面操作的不确定性。已添加英文／简体中文支持，并将程序坞与设置窗口升级为 Apple 原生 Liquid Glass；保留现有窗口策略和交互行为。

## 语言设置

打开菜单栏 **设置… → 系统 → 语言 → 界面语言**，选择 `English` 或 `简体中文`。

- 切换立即生效，并保存到 `~/.config/powerspaces/preferences.json` 的 `language` 字段。
- 尚未选择时，根据系统首选语言匹配；不支持的语言回退到英文。
- 覆盖设置页及搜索、菜单栏、程序坞右键菜单和工具提示、应用启动器、桌面指示器、欢迎页、快捷键说明、权限和操作提示。
- 设置搜索同时保留英文关键词和中文匹配；应用名称、窗口标题等外部内容保留其原始名称。
- CLI 的默认英文输出、JSON 键和策略枚举值保持兼容。Raycast 扩展自身的界面及安装终端脚本仍沿用上游英文。
- 系统权限弹窗、系统错误详情及标准颜色选择器等由 macOS 控制语言，未必跟随应用内选择。应用包已附带中英文自动化权限说明。
- 已显示的临时警告或系统模态弹窗不会在切换时重建；下次显示时使用新语言。

## Liquid Glass

已验证的 Apple Silicon / macOS 27.0（26A428）程序坞使用 DesignLibrary `.dock` 原生配方；仅覆盖 SwiftUI 材质的窗口活跃外观，不改变 AppKit 焦点。系统构建、ABI 或渲染验证不通过时自动回退现有公开玻璃。设置窗口保持公开材质。

- macOS 26 及以上使用 AppKit 的 `NSGlassEffectView`，由系统绘制玻璃折射、边缘和明暗适配；macOS 14–15 回退原有模糊材质。
- **程序坞 → 布局** 分别设置“背景材质”（液态玻璃／纯色）、“背景明暗”（跟随系统／浅色／深色）、玻璃的“着色强度”或纯色的“背景不透明度”（0–100%）。材质与明暗不再混为一个选项，自定义颜色不会覆盖明暗模式。
- 设置窗口与程序坞共用原生玻璃及 contentView 承载方式；设置窗口使用适合密集文字的 regular 材质，程序坞使用 clear 材质；设置窗口的材质效果跟随系统，不再提供独立透明度滑块，旧 `settingsOpacity` 字段不再使用。系统“降低透明度”优先。
- **程序坞 → 布局 → 玻璃透光率**：macOS 27 上可独立减弱原生玻璃的模糊与底色，默认 65%；0% 恢复系统背景模糊与底色（原生边缘高光保持不变），100% 最大程度减弱背景。百分比表示减弱程度，并非测量得到的物理透射率。着色强度仍单独控制所选颜色。
- 透光调节使用隔离的私有 `glassBackground` 滤镜参数，不修改图标与折射参数；原生高光宽度与强度保持不变，也不改系统 Liquid Glass 全局设置。仅在 macOS 27 且参数探测成功时生效，其他系统回退原生玻璃；系统“降低透明度”优先。系统更新后需重新验证。
- 旧 `hud`／`lighter`／`darker`／`solid` 配置继续兼容；已有颜色 alpha 与强度共同控制着色；清透玻璃保留完整边缘光效，系统默认且未染色时禁用无作用的强度滑块。
- 保留圆角、描边、透明度、每桌面颜色和四向停靠。图标独立于背景，不裁切悬停放大，不改变拖拽与自动隐藏。
- 设置页隐藏滚动区域的底色，让玻璃背景可见；系统“降低透明度”启用时改用实色背景。
- 只需预览外观时运行 `swift run --build-system native PowerspacesApp --preview-appearance`：静态示例程序坞与设置页使用临时配置，不启动正式桌面管理。正式安装更新仍按下文切换步骤操作。

## 构建与检查

主要适配环境：macOS 27.0（26A428）、Apple Silicon、Swift 6.4 / macOS 27 SDK。最低部署要求仍为 macOS 14；这不代表每个系统版本均已实机验证。

```bash
cd /Users/ethanlee/projects/powerspaces
swift build --build-system native
swift run spacekit-tests
swift run --build-system native PowerspacesApp --check-localization
./scripts/make-app.sh
```

生成的应用为仓库根目录下的 `Powerspaces.app`。打包脚本会附带本地化资源、CLI、Raycast 扩展源码和许可文件，并进行临时签名。该签名与上游发行版的 Developer ID 签名、公证不同。

当前 macOS 27 Command Line Tools 的 SDK 声明了新的 `State` 宏，但未提供对应插件。项目用 `ViewState` 别名继续使用原有 SwiftUI 属性包装器，保留现有状态行为。打包路径通过 SwiftPM 查询，兼容新工具链的构建产物目录。

只检查界面，无需卸载现有版本：

```bash
swift run --build-system native PowerspacesApp --preview-settings
```

此模式只打开设置窗口，配置写入独立临时目录；不会启动正式的桌面管理、系统 Dock 隐藏或快捷键接管。不要在预览中执行安装、卸载、权限重置等系统操作；这些按钮仍是实际操作。关闭预览窗口后进程退出并清理临时配置。

## 从 Homebrew 版本切换

**本地版本构建成功前，不必卸载现有应用。** 不建议直接覆盖 Homebrew 管理的应用，以免后续升级混淆版本来源。

1. 先通过菜单栏正常退出当前 PowerSpaces，让它恢复所接管的系统设置。
2. 备份配置并移除 Homebrew 管理的应用，然后复制已构建版本：

```bash
# 配置目录存在时才备份；每次生成独立备份，避免覆盖旧备份。
if [ -d "$HOME/.config/powerspaces" ]; then
    cp -R "$HOME/.config/powerspaces" "$HOME/.config/powerspaces-backup-$(date +%Y%m%d-%H%M%S)"
fi

# 普通卸载保留设置。不要添加 --zap，也不要使用应用内的“全部删除”。
brew uninstall --cask powerspaces

# 使用本轮已构建的应用，无需再次编译。
ditto /Users/ethanlee/projects/powerspaces/Powerspaces.app /Applications/Powerspaces.app
open /Applications/Powerspaces.app
```

若复制时提示 `/Applications` 权限不足，可只为复制命令添加 `sudo`；不要用 sudo 构建整个项目。配置目录由新旧版本共享，固定项和启动规则可继续使用。保留 Homebrew tap 即可，无需重新 tap 或 trust。

3. 在 **系统设置 → 隐私与安全性 → 辅助功能** 中检查新应用授权。签名变化可能使旧授权失效；若开关已开启但操作仍失败，先移除旧条目，再添加 `/Applications/Powerspaces.app` 并开启。
4. 打开 **设置 → 系统 → 语言** 选择 `简体中文`。不要同时运行上游版和自行构建版的桌面管理进程。

## 回退到 Homebrew 版

正常退出自行构建版，将 `/Applications/Powerspaces.app` 移到废纸篓，再执行：

```bash
brew install --cask sebastianpdw/tap/powerspaces
open /Applications/Powerspaces.app
```

保留配置目录即可恢复原有设置；上游会忽略新增的语言字段。必要时重新授予辅助功能权限。

程序坞右键与状态栏的“退出 PowerSpaces”共用正常退出入口；菜单展开期间暂停会打断菜单的 Dock 更新。已实测程序坞菜单退出后进程结束，系统 Dock 与快捷键恢复继续由统一的应用退出回调处理。开发回归入口为 `swift run --build-system native PowerspacesApp --check-quit`。

## 后续维护

- 英文和中文资源的键保持一致，动态内容使用完整句子和 `%@` 参数，不拼接译文片段。
- 修改文案后运行 `--check-localization`，检查资源完整性、参数数量、语言持久化和旧配置兼容。
- `InfoPlist.strings` 放在 `packaging/`，由打包脚本复制到主应用的语言目录。
- 发布前同时验证打包后的 `Powerspaces.app/Contents/MacOS/Powerspaces --check-localization`，避免只验证开发目录里的资源。

## 本机自动应用约定

用户已授权后续修改通过构建与必要检查后，默认更新 `/Applications/Powerspaces.app` 并重新启动。更新时正常退出旧进程、保留配置、将上一版备份到 `.build/install-backups/`，再替换并校验签名；不必每次重新执行 Homebrew 卸载。不自动修改辅助功能授权，Git 提交和推送仍按用户要求执行。

## 外观开发与验证

打包暂用 `--build-system native`，确认最终产物实际 SDK 为 27.0、最低部署版本为 14.0。设置页使用系统 Switch 控件。

- `--check-appearance`：旧配置兼容、材质与明暗独立、着色边界和持久化、玻璃前景与不透明回退的点击和可见性，以及原生滤镜透光调节、原值恢复、系统重建后重新应用和高光／折射参数不变。
- `--check-localization`：打包后的双语资源和语言持久化。
- `--check-quit`：程序坞和状态栏共用退出入口、异步退出与重复操作合并。
- `--preview-appearance`：独立设置窗口和静态示例程序坞，使用临时配置。
- `--preview-glass`：在非激活面板内对照同尺寸、同条纹背景的公开 clear 玻璃与真正 Dock 配方，均使用 80% 透光增强，同时检查背景感知标题，不启动桌面管理。

程序坞为光学效果预留 6 点边缘空间，使用玻璃自带阴影并启用 macOS 27 交互响应。设置窗口不启用整块背景的交互响应，控件维持系统行为。

自动检查不能代替真实多屏、辅助功能、拖拽和自动隐藏的实机回归。重要经验统一维护于[开发经验](development-experience.md)。


程序坞新增运行小圆点、固定项/当前桌面运行项分区和邻近图标连续缩放。无窗口应用的会话归属、标题最大宽度规则见 [中文 README](../README.zh-CN.md#程序坞分区与缩放)。

开发外观预览可追加 `--dock-only` 只显示静态示例程序坞，追加 `--magnified` 检查放大布局；均使用临时配置，不触发应用启动策略。

标题和分割线按各自区域的平均背景亮度整体切换纯黑／纯白，不再逐像素混色。分割线在玻璃横截面上居中，长度可调（基础图标尺寸的 20–100%，默认 65%）。运行圆点间距、分割线开关、长度与两侧留白位于“图标”页；“窗口”页设置标题最大宽度，短标题自动收缩。`--check-dock-layout` 使用临时配置检查四边停靠的缩放前后圆点坐标，不修改真实设置。

`--check-native-dock` 在独立非激活面板中核对 `.dock` 高光、明暗和尺寸重建、透光率与高光参数、前景点击命中及公开材质回退，不读取或修改真实配置。

“设置 → 图标 → 分割线粗细”可调 0.5–4 点，默认 1 点；与长度和两侧间距独立。

开启设置中的“高级”后显示玻璃透光率、着色强度及分割线粗细、长度、两侧留白；关闭“高级”仅隐藏控件，保留已保存的效果。
