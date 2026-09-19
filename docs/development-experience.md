# 开发经验

只维护影响后续开发的重要、可复用结论，不记录过程流水账或未经验证的猜测。

## 原生玻璃

- `NSGlassEffectView` 应通过 `contentView` 承载前景。把玻璃当作独立背景层会绕开系统对内容的自适应处理；移动层级时必须复核图标悬停溢出、拖放和空白区菜单。
- `alphaValue` 淡化整个合成结果，边缘高光与前景也会受影响。需要保留光学轮廓时，使用原生材质与 `tintColor` 调节染色，并在界面中准确区分“着色强度”和“不透明度”。
- `.regular` 和 `.clear` 都是原生玻璃；前者强调内容可读性，后者更通透。不要把 `.regular` 称为普通模糊，也不要未经对照断言系统 Dock 的私有实现。
- 本机 macOS 27 SDK 没有公开透光率参数，但实测内部 `glassBackground` 的 `inputBlurRadius` 与 `inputFaceOpacity` 可独立减弱背景模糊和底色；保持折射和整层 alpha 原值；原生高光宽度与强度保持不变。私有实现集中于 `GlassBackgroundTuning.swift`，限定系统大版本、探测键与数值类型、复制滤镜再修改；记录系统原值避免滑块反复调整造成累积衰减。
- **高光根因修正（macOS 27.0 / 26A428）**：不能把背景滤镜 `inputKeyFillHighlightHeight`／`Amount` 的可写性当成原生 Dock 上下高光的因果证据。同一 clear 玻璃窗口的实机激活／失活对照显示：独立 `CASDFKeyFillHighlightEffect` 所在 `CASDFLayer.opacity` 从 1 变为 0，`keyColor`／`fillColor` 的 alpha 同时从 1 变为 0；视觉上上下高光随之消失。PS 使用 `.nonactivatingPanel`，仅调背景滤镜无法解决前景高光失活。正式实现已切换到 `.dock` 配方与渲染环境覆盖，保留非抢焦点行为。
- 系统 Dock 的静态构造链已核对：`ModernFloorLayer` → `GlassMaterialProvider.Configuration.dock` → `DLMaterialLayerController`，与公开 `.clear` 配方不同；渲染器支持独立 SDF 玻璃高光。二进制也有 legacy／其他组件的 rim 控制器，不能把所有 rim 符号都归到现代底栏。尚未读取系统 Dock 实时图层，不能声称掌握其完整光效参数。
- AppKit 会重建内部滤镜。通过布局后合并更新及滤镜变化观察重新应用，不能以持续轮询保活；0% 恢复当前系统原值，未知实现不写入。开发验收既要检查参数，也要固定背景做视觉对照。
- macOS 27 的 `effectIsInteractive` 控制交互响应，不是折射开关。单块玻璃不需要为了“效果齐全”而添加 `NSGlassEffectContainerView`。
- 光学验收应固定背景、尺寸、缩放与强度，观察高反差边界形变，再验证非激活窗口、悬停和四向停靠。编译成功与 API 可用均不能代替视觉验收。
- AppKit 的 `NSView.hitTest` 接受父视图坐标。跨容器转发时不要重复转换到子视图局部坐标；同时验证图标内与图标外的命中结果。
- 降低透明度时切换为不透明背景，前景必须继续显示；玻璃与纯色切换时要解除并恢复 `contentView` 归属，不能只隐藏整个玻璃视图。

## 构建与本地化

- 本机 Swift 6.4 默认 swiftbuild 后端曾把 SDK 标记写成部署版本 14.0，使控件回退旧外观。当前使用 native 后端；升级工具链后检查 `LC_BUILD_VERSION` 再移除兼容，不要修改二进制伪造 SDK。
- native 与 swiftbuild 的语言资源目录大小写不同；本地化查找兼容 `zh-Hans` 和 `zh-hans`，必须验证打包后的应用。
- 本机 CLT 未提供 SwiftUIMacros 插件，使用 `ViewState` 别名明确选择原有属性包装器。

依据：[Apple AppKit 接入说明](https://developer.apple.com/videos/play/wwdc2025/310/)、[Apple Liquid Glass 材质说明](https://developer.apple.com/videos/play/wwdc2025/219/)，以及本机 SDK 头文件。

## 应用生命周期

- 程序坞与状态栏的退出菜单共用 `ApplicationActions`，先结束菜单跟踪，再在主队列调用 `NSApp.terminate`。系统 Dock 和快捷键的恢复集中保留在 `applicationWillTerminate`，不要复制清理代码或使用强制结束代替正常退出。
- 原生菜单跟踪期间，冻结宿主 Dock 的列表重建、位置调整和自动隐藏，避免后台刷新拆掉菜单锚点，造成“点击无效”。菜单关闭后恢复正常刷新。

### 程序坞分区与无窗口归属

- 固定项的运行状态来自全局进程表，当前桌面的窗口列表单独维护，避免把其他桌面正在运行的固定项误画成未启动。
- 无窗口进程没有系统 Space 归属；按窗口编号记录桌面 UUID 归属并按进程启动身份持久化，退出清理；首次无历史的无窗口进程归入活动桌面。不能声称这是系统提供的精确归属。同一窗口移动要替换旧归属，不能累计“访问过的桌面”；关闭才保留最后归属。短暂快照缺失保留窗口编号，重新出现仍可修正；最多保留 256 个已关闭窗口编号，较旧记录压缩为桌面集合。候选列表必须包含已归属的所有存活进程，不能用“全局无窗口”过滤，否则其他桌面有窗口时会丢失本桌面图标；多进程应用按窗口 PID 记录归属、按应用键去重显示。
- `NSButtonCell` 的默认图文分配会受图片尺寸影响；明确实现 `imageRect` / `titleRect`，并按实际文本宽度分配按钮空间。图标缩放使用鼠标事件，距离基准固定在一次悬停开始时，避免扩容后重新取中心造成反馈抖动。
- 动态扩容必须同时更新窗口、玻璃和原生 contentView。实机曾测到外层宽 694 点、前景仅 629 点，造成右侧标题裁切；仅加宽按钮无法修复。
- 缩放时不能用变化中的玻璃中心定位图标组；应固定外侧边缘约束，圆点使用独立几何图形并按实际图标中心定位。四边停靠的实测应分别比较屏幕 y / x 坐标，避免字体字形基线造成假对齐。

### 原生 Dock 配方的正式接入（26A428）

- 独立原型及失活日志证实 `DesignLibrary.GlassMaterialProvider.Configuration.dock` 可通过 SwiftUI Material 渲染；关键是私有 `EnvironmentValues.windowAppearsActive = true`。普通 `appearsActive`、`materialActiveAppearance(.active)` 不等价；不得用激活 PS 或伪造 keyWindow 来补偿。
- `NativeDockMaterial.swift` 只托管背景。Swift 私有调用隔离在 `CDockMaterial`，使用 Clang 的 `swiftcall`、`swift_indirect_result`、`swift_context` 标注真实调用约定；所有函数动态解析，不静态绑定私有 setter。参见 [Clang 调用约定说明](https://clang.llvm.org/docs/AttributeReference.html#swiftcall)。初始化器消费输入值，释放原始存储时不能再次析构。
- 只启用 Apple Silicon / macOS 27.0 构建 `26A428`，同时检查完整元数据、Configuration 216 字节、Provider 328 字节、Material 17 字节／stride 24、EnvironmentValues 16 字节及 8 字节对齐、MaterialProvider 见证表、环境 false/true 回读。系统升级后先重新验证，不能只扩大版本条件。
- 渲染后再核对真实 `CASDFKeyFillHighlightEffect` 的图层 opacity、颜色 alpha 和背景滤镜，最多三次延后验证；失败则永久回退该视图的公开玻璃。背景滤镜和渲染树通过观察与布局事件维护，高光仅做只读验证，无持续轮询。
- 正式桥接实测：应用后台／非 key 窗口、480→580 点宽度、浅→深色后高光保持；透光率 0／40／80／100% 及恢复原值通过；原生高光强度和宽度不变、AppKit 命中、纯色切换与公开材质回退通过。此结论不等于取得系统 Dock 的完整实时参数。

- 从 `NSGlassEffectView.contentView` 迁回普通 AppKit 容器时，恢复 `translatesAutoresizingMaskIntoConstraints` 和尺寸管理；原生容器会改变布局模式，仅设置 frame 会导致前景偏移。用同尺寸双材质实机对照及容器 bounds 检查验证。

- 整体黑白适配使用经本机验证的 `CABackdropLayer.tracksLuma`：`captureOnly` 不绘制背景，通过 `backdropLayer:didChangeLuma:`（Double）获得区域平均亮度，0.43／0.57 迟滞阈值避免抖动；不截图或增加应用侧轮询。探测失败或受保护背景回退外观黑白色。逐像素 `vibrantColorMatrix` 会导致同一文字或线条内部混色，不能用于整体选色。采样层必须在文字／标记层下方作为兄弟层，避免采到元素自身，尤其是细线。分割线独立约束到玻璃中心，避免继承图标沿屏幕边缘的对齐。

- `NSTextField` 默认 alignmentRectInsets 左右各 2 点；几何标记继承它并使用自动布局后，1.5 点宽度约束会产生 5.5 点绘制宽度。标记覆盖为零边距，验证实际屏幕矩形的宽度／高度，不能只检查约束常数与中心。

- 桌面归属修复的实机验证：独立普通应用关闭唯一窗口后仍显示在未固定区；保持该进程存活并重启 PS，图标和保存的归属均恢复。跨桌面累计、多进程去重、PID 复用及退出清理另由假数据测试覆盖。首次升级无法恢复未曾保存的历史归属。

- 移窗隔离修复实机：独立测试窗口在两块显示器的不同 Space 间移动，保持同一窗口编号，归属从 A 替换为 B，A 的图标消失；随后关闭窗口仍仅保留 B。隐藏桌面 UUID 来自完整 Spaces 列表，避免只有访问目标桌面后才更新；同显示器移窗路径以假数据覆盖，未操作用户窗口做实测。

- 缩放算法采用用户验证的 `/tmp/ps-dock-magnification-study/Preview.swift`：三倍基础尺寸影响半径、正弦映射左右边界、余弦进出以及 `floor(42 * log(尺寸差 / 2 + 1) + 1)` 毫秒时长。正式版纯函数在 `DockMagnification.swift`，不依赖临时原型文件，也不调用系统 Dock 的私有动画入口。所有几何使用一次悬停开始时的屏幕坐标，图标与间隙同步映射；禁用叠加隐式动画。仅过渡期间启用计时器，拖拽／重建／隐藏先复位；自动隐藏命中区使用变形后的实际窗口位置。

- 玻璃固定厚度后，放大图标会超出材质边界。实测 AppKit 图层重建会恢复宿主 `clipsToBounds`／`masksToBounds`，需在 Dock 宿主布局时保持前景不裁切；四向几何测试同时检查裁切标志，另以纯图标预览检查实际上沿。

- 程序坞缩放会改变窗口及 tracking area，快速跨入其他应用时仅依赖 mouseExited 可能遗漏收尾。复用本地／全局鼠标事件监听，在收到窗口外事件时启动余弦退出；即使关闭自动隐藏，开启缩放仍需该监听。仅处理已有缩放，不增加轮询。

### 原生工作区预留实验（27.0 / 26A428）

- `SLSSetDockRectWithOrientation` 可改变服务器保存的 Dock 矩形，但不等于已运行应用刷新工作区：底部预留 79→119 点，新进程的 `NSScreen.visibleFrame` 和测试窗口 zoom 上移 40 点；提前启动的独立 AppKit 进程即使用标准 `NSApplication.run`，仍保持 79 点。重新取得 `NSScreen.screens` 也无效。不要以新进程验证替代已运行应用验证。
- 核对本机系统 Dock 二进制：矩形变化发送 `0x4b1` 广播，载荷为四个 Float（x/y/width/height）加两个 UInt32（reason/orientation），共 24 字节，随后调用上述 setter；原型载荷与顺序并未漏掉这一通知。AppKit 也注册了 `0x4b1`。
- 根因证据：`SLSPostBroadcastNotification`（`CGSPostBroadcastNotification` 的同一入口）只发单向 Mach 消息；返回 0 是发送成功。WindowServer 的 `_CGXPostBroadcastNotification` 对连接资格做检查，普通实验进程未获投递；只重发当前矩形、给同一消息补回复端口后，实测 `transport=0 reply_id=30222 server_result=1000 (0x3e8)`。不可把传输成功当作服务端授权成功，也不能仅按符号存在启用功能。
- 原型与日志保留在 `/tmp/ps-dock-workarea-study/`：`observer.m` / `observer-run.log`（提前启动、标准事件循环）、`external-run.log`（有独立看门狗恢复）、`ack.m` / `ack.log`（实际拒绝码）；临时路径非仓库依赖。回复诊断使用本机构建反汇编核对的私有函数相对地址，只可用于这次实验，不能进入生产代码。
- 所有测试已恢复底部 79 点并由独立进程回读。未验证其他方向、自动隐藏和普通应用；第二屏仅确认未受底部实验影响，不代表支持逐屏预留。当前不接入仅改变服务器、无法同步现有应用的半成品，也不接管原生 Dock 的特权连接；待找到并验证允许 PS 使用的刷新路径后再实现版本探测、恢复和失败回退。正式 PS 无此工作区写入逻辑。

- 后续刷新路径排查（同一构建）：公开显示配置事务提交原有显示器坐标，返回成功但提前运行的 AppKit 观察进程仍保留旧工作区；未改变分辨率／排列，实验后独立回读恢复 79 点。日志为 `noop.log`、`observer-noop.log`。事务作用域参见 [Apple CGConfigureOption](https://developer.apple.com/documentation/coregraphics/cgconfigureoption)，不能靠成功返回判断缓存已刷新。
- `SLSSpaceSetEdgeReservation` 的 WindowServer fallback `_XSpaceSetEdgeReservation` 仅在空间是自身所属平铺管理对象且其类型为 4 时更新预留，否则也返回 0；本机普通桌面只读类型为 0。此入口不是已验证的普通桌面通用预留接口；现代 bridged 路径尚未证明可用于普通桌面，不调用未知参数污染用户空间。
- 系统 Dock 在传统矩形广播后还向 `WindowManager.ExposeCoordinator.setDockInfo` 传递显示器、当前／最大 inset 和方向；该路线经 `AdminXPCConnection.xpcSetDockInfo`，`AdminXPCListener` 在接受连接前检查 `com.apple.private.windowmanager` entitlement。只读反汇编确认该检查，没有尝试伪造签名或取得该权限；不能把此入口当作第三方可用替代通知。

- 通知徽章缓存必须区分读取失败与明确空字符串：失败保留旧值，完整列表成功后才清理消失项；同 bundle 的多个源若冲突则保持未知，禁止按显示名称或窗口数量生成通知数。覆盖层用 NSButtonCell.imageRect 定位，避免标题宽度改变徽章位置；红色通知与蓝灰窗口数上下分离。
- 当前徽章实机验证阻塞于辅助功能授权：命令行原型及原安装路径的 PS 只读诊断均报告 AXIsProcessTrusted=false，AX 读取返回 -25211；已验证缓存和静态徽章布局，尚未验证系统 Dock AXStatusLabel 的实际内容、变化通知、隐藏／重启和应用退出。启用并确认授权后必须继续实测，不能把静态预览当成来源验证。


### 本地更新与辅助功能签名身份

- 临时签名的 designated requirement 是 `cdhash`，内容变化会改变身份；保持 bundle ID／路径无法独自解决旧授权失效。
- 固定自签名证书产生“bundle ID + certificate leaf SHA-1”要求，不依赖构建哈希；密钥放在仓库外的独立钥匙串，权限限制为当前用户，不添加系统证书信任。签名配置存在而不可用时必须停止，不能悄悄回退。
- 依据：[Apple TN2206](https://developer.apple.com/library/archive/technotes/tn2206/)。首次身份迁移需用户重新授权；相同签名要求的验证不能替代真实 TCC 跨版本测试。


### 图标居中与运行标记

- 程序坞厚度变化时，静止内容外沿应为（玻璃厚度－静止内容厚度）／2，不能固定为圆点留白；内容建立、标题宽度变化后必须同时刷新厚度和定位约束。
- 左右停靠时图标与展开标题作为整体居中；通过平移对齐框处理不同宽度，运行圆点反向补偿该位移以保持公共基线。放大仍使用静止外沿，不能用放大后的尺寸重新计算静止中心。
