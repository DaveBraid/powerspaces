# macOS 27 汉化版

本 fork 优先解决 macOS 多桌面操作的不确定性。本轮仅添加英文／简体中文支持，保留原有程序坞外观、窗口策略和默认行为。

## 语言设置

打开菜单栏 **设置… → 系统 → 语言 → 界面语言**，选择 `English` 或 `简体中文`。

- 切换立即生效，并保存到 `~/.config/powerspaces/preferences.json` 的 `language` 字段。
- 尚未选择时，根据系统首选语言匹配；不支持的语言回退到英文。
- 覆盖设置页及搜索、菜单栏、程序坞右键菜单和工具提示、应用启动器、桌面指示器、欢迎页、快捷键说明、权限和操作提示。
- 设置搜索同时保留英文关键词和中文匹配；应用名称、窗口标题等外部内容保留其原始名称。
- CLI 的默认英文输出、JSON 键和策略枚举值保持兼容。Raycast 扩展自身的界面及安装终端脚本仍沿用上游英文。
- 系统权限弹窗、系统错误详情及标准颜色选择器等由 macOS 控制语言，未必跟随应用内选择。应用包已附带中英文自动化权限说明。
- 已显示的临时警告或系统模态弹窗不会在切换时重建；下次显示时使用新语言。

## 构建与检查

主要适配环境：macOS 27.0（26A428）、Apple Silicon、Swift 6.4 / macOS 27 SDK。最低部署要求仍为 macOS 14；这不代表每个系统版本均已实机验证。

```bash
cd /Users/ethanlee/projects/powerspaces
swift build
swift run spacekit-tests
swift run PowerspacesApp --check-localization
./scripts/make-app.sh
```

生成的应用为仓库根目录下的 `Powerspaces.app`。打包脚本会附带本地化资源、CLI、Raycast 扩展源码和许可文件，并进行临时签名。该签名与上游发行版的 Developer ID 签名、公证不同。

当前 macOS 27 Command Line Tools 的 SDK 声明了新的 `State` 宏，但未提供对应插件。项目用 `ViewState` 别名继续使用原有 SwiftUI 属性包装器，保留现有状态行为。打包路径通过 SwiftPM 查询，兼容新工具链的构建产物目录。

只检查界面，无需卸载现有版本：

```bash
swift run PowerspacesApp --preview-settings
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

## 后续维护

- 英文和中文资源的键保持一致，动态内容使用完整句子和 `%@` 参数，不拼接译文片段。
- 修改文案后运行 `--check-localization`，检查资源完整性、参数数量、语言持久化和旧配置兼容。
- `InfoPlist.strings` 放在 `packaging/`，由打包脚本复制到主应用的语言目录。
- 发布前同时验证打包后的 `Powerspaces.app/Contents/MacOS/Powerspaces --check-localization`，避免只验证开发目录里的资源。

## 本轮验证记录（2026-09-18）

- macOS 27.0 上完成 release 构建、应用打包和签名完整性校验。
- 打包后的应用通过 559 条中英文资源及语言持久化检查。
- `spacekit-tests`：247 项断言通过；真实 CGS 冒烟项因测试进程无法读取窗口服务器而跳过，未据此宣称跨桌面操作已实机验证。
- 使用临时配置进行设置窗口实机检查：简体中文 → English → 简体中文即时切换、窗口标题与独立设置行刷新、英文界面输入“圆角”命中 `Corner radius`；截图检查了中英文布局。
- 保留现有 Homebrew 安装，未执行卸载、安装替换或辅助功能授权变更。正式切换步骤见上文。
