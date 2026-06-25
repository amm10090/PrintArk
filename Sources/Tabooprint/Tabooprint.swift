import AppKit
import Darwin
import SwiftUI

@MainActor
package enum TabooprintDesktopLauncher {
    package static func main() {
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

        guard ProcessInfo.processInfo.environment["TABOOPRINT_SHOW_SYSTEM_STDERR"] != "1" else {
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
        }
    }

    private func showSettingsWindow() {
        if let controller = settingsWindowController {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: WaybillPrintConsoleView(model: model))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Tabooprint"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1240, height: 780))
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
    private let model: AppModel
    private let openSettingsHandler: () -> Void
    private let refreshHandler: () -> Void
    private let startHandler: () -> Void
    private let stopHandler: () -> Void
    private let restartHandler: () -> Void
    private let openPreviewHandler: () -> Void
    private let quitHandler: () -> Void

    private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let summaryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let connectionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let portItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let startItem = NSMenuItem(title: "启动", action: #selector(startSelected), keyEquivalent: "")
    private let stopItem = NSMenuItem(title: "停止", action: #selector(stopSelected), keyEquivalent: "")
    private let restartItem = NSMenuItem(title: "重启", action: #selector(restartSelected), keyEquivalent: "")
    private let openPreviewItem = NSMenuItem(title: "打开最新预览 PDF", action: #selector(openPreviewSelected), keyEquivalent: "")
    private let refreshItem = NSMenuItem(title: "刷新", action: #selector(refreshSelected), keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: "显示设置", action: #selector(openSettingsSelected), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "退出", action: #selector(quitSelected), keyEquivalent: "")

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
        configureMenu()
        refresh()
    }

    func refresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusItem.button?.image = NSImage(
                systemSymbolName: self.model.serviceState.symbolName,
                accessibilityDescription: self.model.serviceState.title
            )
            self.statusItem.button?.imagePosition = .imageOnly
            self.statusItem.button?.toolTip = self.model.serviceSummary
            self.stateItem.title = "状态：\(self.model.serviceState.title)"
            self.summaryItem.title = self.model.serviceSummary
            self.connectionItem.title = "连接：\(self.model.activeBrowserConnections)"
            let portSummary = self.model.ports.map { "\($0.label)\($0.stateText)" }.joined(separator: " · ")
            self.portItem.title = "端口：\(portSummary)"
            self.startItem.isEnabled = self.model.serviceState != .running && self.model.serviceState != .starting
            self.stopItem.isEnabled = self.model.serviceState != .stopped && self.model.serviceState != .stopping
            self.restartItem.isEnabled = true
            self.openPreviewItem.isEnabled = self.model.latestPreviewPDF != nil
        }
    }

    private func configureStatusItem() {
        statusItem.button?.image = NSImage(systemSymbolName: "printer.fill", accessibilityDescription: "Tabooprint")
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "Tabooprint"
    }

    private func configureMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        stateItem.isEnabled = false
        summaryItem.isEnabled = false
        connectionItem.isEnabled = false
        portItem.isEnabled = false

        menu.addItem(stateItem)
        menu.addItem(summaryItem)
        menu.addItem(connectionItem)
        menu.addItem(portItem)
        menu.addItem(.separator())

        [startItem, stopItem, restartItem, openPreviewItem, refreshItem, settingsItem, quitItem].forEach { item in
            item.target = self
            menu.addItem(item)
        }

        statusItem.menu = menu
    }

    @objc private func startSelected() { startHandler() }
    @objc private func stopSelected() { stopHandler() }
    @objc private func restartSelected() { restartHandler() }
    @objc private func openPreviewSelected() { openPreviewHandler() }
    @objc private func refreshSelected() { refreshHandler() }
    @objc private func openSettingsSelected() { openSettingsHandler() }
    @objc private func quitSelected() { quitHandler() }
}
