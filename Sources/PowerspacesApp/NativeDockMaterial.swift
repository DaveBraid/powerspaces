// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI
import Darwin
import CDockMaterial

/// 私有 Swift ABI 只在已验证的构建上启用；任何前置检查失败均保留公开玻璃回退。
@MainActor
final class NativeDockRecipe {
    static let shared: NativeDockRecipe? = load()
    private(set) static var unavailableReason = "Not probed"
    let material: Material
    private let activeSetter: UnsafeMutableRawPointer
    private let activeGetter: UnsafeMutableRawPointer

    private init(material: Material, setter: UnsafeMutableRawPointer, getter: UnsafeMutableRawPointer) {
        self.material = material
        activeSetter = setter
        activeGetter = getter
    }

    /// 设置并回读渲染环境；与 NSApp 激活、keyWindow 和鼠标事件完全无关。
    func setActive(_ active: Bool, environment: inout EnvironmentValues) -> Bool {
        withUnsafeMutablePointer(to: &environment) { pointer in
            PSDockSetWindowActive(activeSetter, pointer, active)
            return PSDockGetWindowActive(activeGetter, pointer) == active
        }
    }

    /// 用确切系统构建、类型布局、协议见证与环境回读共同约束 ABI；不强制解包或静态链接私有符号。
    private static func load() -> NativeDockRecipe? {
        func fail(_ reason: String) -> NativeDockRecipe? {
            unavailableReason = reason
            return nil
        }
        #if arch(arm64)
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 else {
            return fail("Requires validated macOS 27 build")
        }
        var count = 0
        guard sysctlbyname("kern.osversion", nil, &count, nil, 0) == 0, count > 1, count < 128 else {
            return fail("Cannot read system build")
        }
        var build = [CChar](repeating: 0, count: count)
        guard sysctlbyname("kern.osversion", &build, &count, nil, 0) == 0,
              String(cString: build) == "26A428" else { return fail("Unverified system build") }
        // 保持框架在进程生命周期内加载，缓存材质可能仍引用其协议见证表。
        guard let design = dlopen("/System/Library/PrivateFrameworks/DesignLibrary.framework/DesignLibrary", RTLD_LAZY | RTLD_LOCAL),
              let core = dlopen("/System/Library/Frameworks/SwiftUICore.framework/SwiftUICore", RTLD_LAZY | RTLD_LOCAL),
              let runtime = dlopen(nil, RTLD_LAZY) else { return fail("Framework unavailable") }
        guard let configurationMetadata = dlsym(design, "$s13DesignLibrary21GlassMaterialProviderV13ConfigurationVMa"),
              let providerMetadata = dlsym(design, "$s13DesignLibrary21GlassMaterialProviderVMa"),
              let dock = dlsym(design, "$s13DesignLibrary21GlassMaterialProviderV13ConfigurationV4dockAEvgZ"),
              let providerInit = dlsym(design, "$s13DesignLibrary21GlassMaterialProviderV13configurationA2C13ConfigurationV_tcfC"),
              let materialInit = dlsym(core, "$s7SwiftUI8MaterialVAAE8providerACx_tcAA0C8ProviderRzlufC"),
              let descriptor = dlsym(core, "$s7SwiftUI16MaterialProviderMp"),
              let conformsAddress = dlsym(runtime, "swift_conformsToProtocol"),
              let setter = dlsym(core, "$s7SwiftUI17EnvironmentValuesV19windowAppearsActiveSbvs"),
              let getter = dlsym(core, "$s7SwiftUI17EnvironmentValuesV19windowAppearsActiveSbvg") else {
            return fail("Required symbol unavailable")
        }
        let configuration = PSDockGetMetadata(configurationMetadata)
        let provider = PSDockGetMetadata(providerMetadata)
        guard configuration.state == 0, provider.state == 0,
              let configurationType = configuration.type, let providerType = provider.type else {
            return fail("Incomplete type metadata")
        }
        func layout<T>(_ type: T.Type) -> (String, Int, Int, Int) {
            (String(reflecting: type), MemoryLayout<T>.size, MemoryLayout<T>.stride, MemoryLayout<T>.alignment)
        }
        let configurationLayout = _openExistential(unsafeBitCast(configurationType, to: Any.Type.self), do: layout)
        let providerLayout = _openExistential(unsafeBitCast(providerType, to: Any.Type.self), do: layout)
        guard configurationLayout == ("DesignLibrary.GlassMaterialProvider.Configuration", 216, 216, 8),
              providerLayout == ("DesignLibrary.GlassMaterialProvider", 328, 328, 8),
              MemoryLayout<Material>.size == 17, MemoryLayout<Material>.stride == 24,
              MemoryLayout<Material>.alignment == 8,
              MemoryLayout<EnvironmentValues>.size == 16, MemoryLayout<EnvironmentValues>.alignment == 8 else {
            return fail("ABI layout changed")
        }
        typealias Conforms = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> UnsafeRawPointer?
        let conforms = unsafeBitCast(conformsAddress, to: Conforms.self)
        guard let witness = conforms(providerType, descriptor) else { return fail("MaterialProvider conformance unavailable") }
        let configurationStorage = UnsafeMutableRawPointer.allocate(byteCount: 216, alignment: 8)
        let providerStorage = UnsafeMutableRawPointer.allocate(byteCount: 328, alignment: 8)
        let materialStorage = UnsafeMutablePointer<Material>.allocate(capacity: 1)
        defer {
            // 两个初始化器依次消费输入值；只释放空存储，避免重复 release。
            configurationStorage.deallocate()
            providerStorage.deallocate()
            materialStorage.deallocate()
        }
        PSDockMakeConfiguration(dock, configurationStorage)
        PSDockMakeProvider(providerInit, providerStorage, configurationStorage)
        PSDockMakeMaterial(materialInit, materialStorage, providerStorage, providerType, witness)
        let result = NativeDockRecipe(material: materialStorage.move(), setter: setter, getter: getter)
        var environment = EnvironmentValues()
        guard result.setActive(false, environment: &environment), result.setActive(true, environment: &environment) else {
            return fail("Window appearance environment failed round-trip")
        }
        unavailableReason = ""
        return result
        #else
        return fail("Unverified architecture")
        #endif
    }
}

/// SwiftUI 只绘制背景；图标、文本、拖放和菜单继续由原有 AppKit 层负责。
struct NativeDockBackground: View {
    let recipe: NativeDockRecipe
    var radius: CGFloat
    var tint: NSColor?
    var body: some View {
        Color.clear
            .background(recipe.material, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).fill(Color(nsColor: tint ?? .clear)))
            .transformEnvironment(\.self) { values in _ = recipe.setActive(true, environment: &values) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// 不接管焦点或命中测试；布局变化驱动参数恢复，并检查实际高光层是否渲染成功。
@MainActor
final class NativeDockMaterialView: NSHostingView<NativeDockBackground> {
    let tuning = GlassLayerTuning()
    var onFailure: (() -> Void)?
    private var pending = false
    private var validationAttempts = 0
    private(set) var renderingVerified = false
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    convenience init(recipe: NativeDockRecipe) {
        self.init(rootView: NativeDockBackground(recipe: recipe, radius: 16))
    }
    required init(rootView: NativeDockBackground) {
        super.init(rootView: rootView)
        sizingOptions = []
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        clipsToBounds = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 更新现有宿主，不创建新窗口；明暗与圆角重建后重新应用参数。
    func update(radius: CGFloat, tint: NSColor?, appearance: NSAppearance?, transparency: Double) {
        self.appearance = appearance
        rootView = NativeDockBackground(recipe: rootView.recipe, radius: radius, tint: tint)
        tuning.backgroundTransparency = transparency
        scheduleUpdate()
    }
    override func layout() { super.layout(); scheduleUpdate() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleUpdate() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); scheduleUpdate() }

    /// 首次绘制最多三次延后验证；成功后仅依靠布局和图层通知，不增加持续轮询。
    private func scheduleUpdate() {
        guard !pending, window?.isVisible == true, bounds.width > 1, bounds.height > 1,
              !isHidden, !SystemDisplay.reduceTransparency else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            self.tuning.attach(to: self.layer)
            self.tuning.applyBackgroundTuning()
            if Self.hasActiveHighlight(self.layer), self.tuning.tuningAvailable {
                self.renderingVerified = true
                self.validationAttempts = 0
            } else {
                self.validationAttempts += 1
                if self.validationAttempts >= 3 { self.onFailure?() }
                else {
                    self.pending = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                        self?.pending = false
                        self?.scheduleUpdate()
                    }
                }
            }
        }
    }

    /// 同时检查独立高光层及颜色 alpha，避免只看到材质对象就误判成功。
    static func hasActiveHighlight(_ layer: CALayer?) -> Bool {
        guard let layer else { return false }
        guard !layer.isHidden, layer.opacity > 0.99 else { return false }
        if layer.responds(to: NSSelectorFromString("effect")),
           let effect = layer.value(forKey: "effect") as? NSObject,
           String(describing: type(of: effect)) == "CASDFKeyFillHighlightEffect" {
            let colorsActive = ["keyColor", "fillColor"].allSatisfy { key in
                guard effect.responds(to: NSSelectorFromString(key)),
                      let value = effect.value(forKey: key) as AnyObject?,
                      CFGetTypeID(value) == CGColor.typeID else { return false }
                let color = unsafeBitCast(value, to: CGColor.self) // CF 类型已核对。
                return color.alpha > 0.99
            }
            if colorsActive { return true }
        }
        return (layer.sublayers ?? []).contains { hasActiveHighlight($0) }
    }
}
