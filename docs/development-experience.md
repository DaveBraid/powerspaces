# 开发经验

只维护影响后续开发的重要、可复用结论，不记录过程流水账或未经验证的猜测。

## 原生玻璃

- `NSGlassEffectView` 应通过 `contentView` 承载前景。把玻璃当作独立背景层会绕开系统对内容的自适应处理；移动层级时必须复核图标悬停溢出、拖放和空白区菜单。
- `alphaValue` 淡化整个合成结果，边缘高光与前景也会受影响。需要保留光学轮廓时，使用原生材质与 `tintColor` 调节染色，并在界面中准确区分“着色强度”和“不透明度”。
- `.regular` 和 `.clear` 都是原生玻璃；前者强调内容可读性，后者更通透。不要把 `.regular` 称为普通模糊，也不要未经对照断言系统 Dock 的私有实现。
- 本机 macOS 27 SDK 没有公开透光率参数，但实测内部 `glassBackground` 的 `inputBlurRadius` 与 `inputFaceOpacity` 可独立减弱背景模糊和底色；保持折射和整层 alpha 原值；高光宽度与强度独立维护。私有实现集中于 `GlassBackgroundTuning.swift`，限定系统大版本、探测键与数值类型、复制滤镜再修改；记录系统原值避免滑块反复调整造成累积衰减。
- 固定 RGB 标题和只跟随系统主题的语义色均不能保证适应实际玻璃背景。macOS 27 标题单独使用 `vibrantColorMatrix` 的背景感知灰度反向映射；必须保留文字 alpha，且不能把滤镜加在含应用图标的整个按钮上。深浅交替背景的视觉对照可检出错误。
- **高光根因修正（macOS 27.0 / 26A428）**：不能把背景滤镜 `inputKeyFillHighlightHeight`／`Amount` 的可写性当成原生 Dock 上下高光的因果证据。同一 clear 玻璃窗口的实机激活／失活对照显示：独立 `CASDFKeyFillHighlightEffect` 所在 `CASDFLayer.opacity` 从 1 变为 0，`keyColor`／`fillColor` 的 alpha 同时从 1 变为 0；视觉上上下高光随之消失。PS 使用 `.nonactivatingPanel`，当前滑块只调背景滤镜，不能解决前景高光失活。后续修复应保持非抢焦点行为，处理前景高光及其系统重建。
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
