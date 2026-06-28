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
            self.statusItem.button?.image = self.statusBarIcon()
            self.statusItem.button?.imagePosition = .imageOnly
            self.statusItem.button?.toolTip = self.statusTooltip
        }
    }

    private func configureStatusItem() {
        statusItem.button?.image = statusBarIcon()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "印舟"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
    }

    /// 菜单栏图标三态:空闲(模板色打印机)/打印中(蓝色对勾角标)/错误(红色感叹角标)。
    /// 角标为彩色,故整图 isTemplate=false,自绘 SF Symbol 打印机轮廓 + 右上角标圆点。
    private func statusBarIcon() -> NSImage {
        let hasFailed = model.queueJobs.contains { $0.status == .failed }
        let waitingConnection = model.serviceState == .running && model.activeBrowserConnections == 0
        let isPrinting = model.queueJobs.contains { $0.status == .printing || $0.status == .queued }

        let badge: NSColor?
        let badgeSymbol: String?
        if hasFailed {
            badge = .systemRed; badgeSymbol = "exclamationmark"
        } else if isPrinting {
            badge = .systemBlue; badgeSymbol = "checkmark"
        } else {
            badge = nil; badgeSymbol = nil
        }

        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            guard let base = NSImage(systemSymbolName: "printer", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return false }
            // 基础打印机轮廓:用 label 色绘制(随明暗自适应)。
            let baseSize = base.size
            let baseRect = NSRect(
                x: (rect.width - baseSize.width) / 2,
                y: (rect.height - baseSize.height) / 2,
                width: baseSize.width,
                height: baseSize.height
            )
            NSColor.labelColor.set()
            base.draw(in: baseRect)

            // 角标:右上角彩色圆点 + 白色小符号。
            if let badge, let badgeSymbol {
                let d: CGFloat = 9
                let badgeRect = NSRect(x: rect.width - d, y: rect.height - d, width: d, height: d)
                badge.set()
                NSBezierPath(ovalIn: badgeRect).fill()
                let badgeConfig = NSImage.SymbolConfiguration(pointSize: 6, weight: .bold)
                if let glyph = NSImage(systemSymbolName: badgeSymbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(badgeConfig) {
                    let g = glyph.size
                    let gRect = NSRect(
                        x: badgeRect.midX - g.width / 2,
                        y: badgeRect.midY - g.height / 2,
                        width: g.width, height: g.height
                    )
                    let tinted = glyph.copy() as! NSImage
                    tinted.isTemplate = true
                    NSColor.white.set()
                    tinted.draw(in: gRect)
                }
            }
            _ = waitingConnection
            return true
        }
        image.accessibilityDescription = statusAccessibilityDescription
        return image
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: StatusMenuStyle.menuWidth, height: 540)
        popover.contentViewController = NSHostingController(
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
    }

    private var statusSymbolName: String {
        if model.queueJobs.contains(where: { $0.status == .failed }) {
            return "exclamationmark.triangle.fill"
        }
        if model.serviceState == .running && model.activeBrowserConnections == 0 {
            return "antenna.radiowaves.left.and.right.slash"
        }
        return model.serviceState.symbolName
    }

    private var statusAccessibilityDescription: String {
        if model.queueJobs.contains(where: { $0.status == .failed }) {
            return "印舟，有失败任务"
        }
        if model.serviceState == .running && model.activeBrowserConnections == 0 {
            return "印舟，等待千牛连接"
        }
        return "印舟，\(model.serviceState.title)"
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
