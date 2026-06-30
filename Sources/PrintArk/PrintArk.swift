import AppKit
import Darwin
import SwiftUI

@MainActor
package enum PrintArkDesktopLauncher {
    package static func main() {
        // 旧版（Tabooprint）键迁移必须在注册默认与任何 UserDefaults 读取之前，
        // 保证旧用户的设置先搬到新 printark.* 键，再注册出厂默认（不覆盖已迁移值）。
        SettingsMigration.migrateLegacyKeysIfNeeded()

        // 出厂默认设置注册必须在任何 UserDefaults 读取之前；headless 与 GUI 两条路径都经过此点。
        FactoryDefaults.register()

        if ServiceOnlyRunner.runIfRequested() {
            return
        }

        configureDesktopRuntime()

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }

    private static func configureDesktopRuntime() {
        NSWindow.allowsAutomaticWindowTabbing = false

        guard ProcessInfo.processInfo.environment["PRINTARK_SHOW_SYSTEM_STDERR"] != "1" else {
            return
        }
        freopen("/dev/null", "w", stderr)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppModel()
    private var statusItemController: StatusItemController?
    private var settingsWindowController: NSWindowController?

    override init() {
        super.init()
        model.enableConsoleLogging()
        model.onRefresh = { [weak self] in
            self?.statusItemController?.refresh()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(
            model: model,
            openSettings: { [weak self] in self?.showSettingsWindow() },
            refresh: { [weak self] in self?.model.refresh() },
            start: { [weak self] in self?.model.startService() },
            stop: { [weak self] in self?.model.stopService() },
            restart: { [weak self] in self?.model.restartService() },
            openPreview: { [weak self] in self?.model.openLatestPreview() },
            quit: {
                NSApp.terminate(nil)
            }
        )

        showSettingsWindow()
        model.startService()
        model.startPolling()
        model.refresh()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow,
           window == settingsWindowController?.window {
            settingsWindowController = nil
            // 设置窗口关闭后退回菜单栏常驻，不在 Dock 显示。
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func showSettingsWindow() {
        // 有窗口时作为常规 app 在 Dock 显示图标。
        NSApp.setActivationPolicy(.regular)

        if let controller = settingsWindowController {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: WaybillPrintConsoleView(model: model))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "印舟"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1320, height: 860))
        window.contentMinSize = NSSize(width: 1040, height: 720)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let model: AppModel
    private let openSettingsHandler: () -> Void
    private let refreshHandler: () -> Void
    private let startHandler: () -> Void
    private let stopHandler: () -> Void
    private let restartHandler: () -> Void
    private let openPreviewHandler: () -> Void
    private let quitHandler: () -> Void
    private var renderedIconState: StatusIconState?
    private var renderedTooltip: String?

    private struct StatusIconState: Equatable {
        let hasFailed: Bool
        let isPrinting: Bool
        let waitingConnection: Bool
        let serviceState: ServiceState
    }

    init(
        model: AppModel,
        openSettings: @escaping () -> Void,
        refresh: @escaping () -> Void,
        start: @escaping () -> Void,
        stop: @escaping () -> Void,
        restart: @escaping () -> Void,
        openPreview: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        self.model = model
        openSettingsHandler = openSettings
        refreshHandler = refresh
        startHandler = start
        stopHandler = stop
        restartHandler = restart
        openPreviewHandler = openPreview
        quitHandler = quit

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
        configurePopover()
        refresh()
    }

    func refresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let state = self.currentIconState
            if state != self.renderedIconState {
                self.statusItem.button?.image = self.statusBarIcon(for: state)
                self.statusItem.button?.imagePosition = .imageOnly
                self.renderedIconState = state
            }
            let tooltip = self.statusTooltip
            if tooltip != self.renderedTooltip {
                self.statusItem.button?.toolTip = tooltip
                self.renderedTooltip = tooltip
            }
        }
    }

    private func configureStatusItem() {
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "印舟"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
    }

    /// 菜单栏图标三态:空闲(系统模板色打印机)/打印中(蓝色对勾角标)/错误(红色感叹角标)。
    /// 空闲态交给 NSStatusItem 的 template 渲染,才能和其他菜单栏图标一样随系统变白/变黑。
    /// 角标为彩色时整图改为非模板,并把基础打印机实心绘成白色。
    private func statusBarIcon(for state: StatusIconState) -> NSImage {
        let badge: NSColor?
        let badgeSymbol: String?
        if state.hasFailed {
            badge = .systemRed; badgeSymbol = "exclamationmark"
        } else if state.isPrinting {
            badge = .systemBlue; badgeSymbol = "checkmark"
        } else {
            badge = nil; badgeSymbol = nil
        }

        let size = NSSize(width: 20, height: 18)
        let usesTemplateRendering = badge == nil
        let baseColor: NSColor = usesTemplateRendering ? .black : .white
        guard let base = Self.tintedSymbolImage(
            name: "printer.fill",
            pointSize: 15,
            weight: .regular,
            color: baseColor
        ) else {
            return NSImage(systemSymbolName: "printer.fill", accessibilityDescription: statusAccessibilityDescription(for: state))
                ?? NSImage(size: size)
        }
        let badgeGlyph = badgeSymbol.flatMap {
            Self.tintedSymbolImage(name: $0, pointSize: 6, weight: .bold, color: .white)
        }
        let image = NSImage(size: size, flipped: false) { rect in
            let baseSize = base.size
            let baseRect = NSRect(
                x: (rect.width - baseSize.width) / 2,
                y: (rect.height - baseSize.height) / 2,
                width: baseSize.width,
                height: baseSize.height
            )
            base.draw(in: baseRect)

            // 角标:右上角彩色圆点 + 白色小符号。
            if let badge {
                let d: CGFloat = 9
                let badgeRect = NSRect(x: rect.width - d, y: rect.height - d, width: d, height: d)
                badge.set()
                NSBezierPath(ovalIn: badgeRect).fill()
                if let glyph = badgeGlyph {
                    let g = glyph.size
                    let gRect = NSRect(
                        x: badgeRect.midX - g.width / 2,
                        y: badgeRect.midY - g.height / 2,
                        width: g.width, height: g.height
                    )
                    glyph.draw(in: gRect)
                }
            }
            return true
        }
        image.accessibilityDescription = statusAccessibilityDescription(for: state)
        image.isTemplate = usesTemplateRendering
        return image
    }

    private static func tintedSymbolImage(
        name: String,
        pointSize: CGFloat,
        weight: NSFont.Weight,
        color: NSColor
    ) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
            return nil
        }
        let rect = NSRect(origin: .zero, size: symbol.size)
        let image = NSImage(size: symbol.size)
        image.lockFocus()
        symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        color.set()
        rect.fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: StatusMenuStyle.menuWidth, height: StatusMenuStyle.menuHeight)
        let hosting = NSHostingController(
            rootView: StatusBarPopoverView(
                model: model,
                actions: StatusBarPopoverActions(
                    openMainWindow: { [weak self] in
                        self?.closePopover()
                        self?.openSettingsHandler()
                    },
                    openPreferences: { [weak self] in
                        self?.closePopover()
                        self?.openSettingsHandler()
                    },
                    quit: { [weak self] in
                        self?.closePopover()
                        self?.quitHandler()
                    }
                )
            )
        )
        // 禁止 NSHostingController 用 SwiftUI 固有尺寸覆盖 popover.contentSize —— 二者冲突会让
        // NSPopover 拿不到稳定尺寸而把弹窗定位退化到屏幕原点(展开飘到左上角、挡住状态栏)。
        hosting.sizingOptions = []
        popover.contentViewController = hosting
    }

    private var currentIconState: StatusIconState {
        let jobs = model.queueJobs
        return StatusIconState(
            hasFailed: jobs.contains { $0.status == .failed },
            isPrinting: jobs.contains { $0.status == .printing || $0.status == .queued },
            waitingConnection: model.serviceState == .running && model.activeBrowserConnections == 0,
            serviceState: model.serviceState
        )
    }

    private func statusAccessibilityDescription(for state: StatusIconState) -> String {
        if state.hasFailed {
            return "印舟，有失败任务"
        }
        if state.waitingConnection {
            return "印舟，等待千牛连接"
        }
        return "印舟，\(state.serviceState.title)"
    }

    private var statusTooltip: String {
        let failedCount = model.queueJobs.filter { $0.status == .failed }.count
        let taskText = model.queueJobs.isEmpty ? "暂无任务" : "\(model.queueJobs.count) 个任务"
        let failedText = failedCount == 0 ? "无失败" : "\(failedCount) 个失败"
        return "\(model.serviceSummary) • \(taskText) • \(failedText)"
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
            return
        }
        refreshHandler()
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func closePopover() {
        popover.performClose(nil)
    }
}
