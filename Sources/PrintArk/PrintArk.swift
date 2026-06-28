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
            self.statusItem.button?.image = NSImage(
                systemSymbolName: self.statusSymbolName,
                accessibilityDescription: self.statusAccessibilityDescription
            )
            self.statusItem.button?.imagePosition = .imageOnly
            self.statusItem.button?.toolTip = self.statusTooltip
        }
    }

    private func configureStatusItem() {
        statusItem.button?.image = NSImage(systemSymbolName: "printer.fill", accessibilityDescription: "印舟")
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "印舟"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 386, height: 560)
        popover.contentViewController = NSHostingController(
            rootView: StatusDashboardPopover(
                model: model,
                start: { [weak self] in self?.startHandler() },
                stop: { [weak self] in self?.stopHandler() },
                restart: { [weak self] in self?.restartHandler() },
                refresh: { [weak self] in self?.refreshHandler() },
                openPreview: { [weak self] in self?.openPreviewHandler() },
                openSettings: { [weak self] in
                    self?.closePopover()
                    self?.openSettingsHandler()
                },
                quit: { [weak self] in
                    self?.closePopover()
                    self?.quitHandler()
                }
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

private struct StatusDashboardPopover: View {
    @ObservedObject var model: AppModel

    let start: () -> Void
    let stop: () -> Void
    let restart: () -> Void
    let refresh: () -> Void
    let openPreview: () -> Void
    let openSettings: () -> Void
    let quit: () -> Void

    @AppStorage(SettingsKeys.debugPreview) private var debugPreview = false

    private var jobs: [QueueJob] {
        model.queueJobs
    }

    private var recentJobs: [QueueJob] {
        Array(jobs.prefix(3))
    }

    private var failedJobs: [QueueJob] {
        jobs.filter { $0.status == .failed }
    }

    private var isServiceBusy: Bool {
        model.serviceState == .starting || model.serviceState == .stopping
    }

    private var health: StatusDashboardHealth {
        if model.serviceState == .error {
            return StatusDashboardHealth(title: "服务异常", detail: model.serviceSummary, color: .red, symbolName: "exclamationmark.triangle.fill")
        }
        if !failedJobs.isEmpty {
            return StatusDashboardHealth(title: "有失败任务", detail: "\(failedJobs.count) 个任务需要处理", color: .red, symbolName: "exclamationmark.triangle.fill")
        }
        if model.serviceState == .running && model.activeBrowserConnections == 0 {
            return StatusDashboardHealth(title: "等待千牛连接", detail: "本机服务已运行，浏览器尚未连接", color: .orange, symbolName: "antenna.radiowaves.left.and.right.slash")
        }
        if model.serviceState == .running {
            return StatusDashboardHealth(title: "服务正常", detail: "\(model.activeBrowserConnections) 个浏览器连接", color: .green, symbolName: "checkmark.circle.fill")
        }
        if model.serviceState == .starting || model.serviceState == .stopping {
            return StatusDashboardHealth(title: model.serviceState.title, detail: model.serviceSummary, color: .orange, symbolName: "arrow.triangle.2.circlepath")
        }
        return StatusDashboardHealth(title: "服务未启动", detail: "启动后即可接收千牛打印请求", color: .secondary, symbolName: "pause.circle")
    }

    private var modeText: String {
        debugPreview ? "调试预览" : "真实打印"
    }

    private var primaryActionTitle: String {
        model.serviceState == .running ? "重启服务" : "启动服务"
    }

    private var primaryActionSymbol: String {
        model.serviceState == .running ? "arrow.clockwise" : "play.fill"
    }

    private var previewFileName: String {
        model.latestPreviewPDF?.lastPathComponent ?? "暂无预览"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    metricsGrid
                    recentTasks
                    controls
                }
                .padding(16)
            }
            .frame(width: 386, height: 506)
            .background(Color(nsColor: .windowBackgroundColor))

            footer
        }
        .frame(width: 386, height: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: health.symbolName)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(health.color)
                    .frame(width: 34, height: 34)
                    .background(health.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(health.title)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)

                    Text(health.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                StatusDashboardPill(text: modeText, color: debugPreview ? .blue : .green)
            }

            HStack(spacing: 8) {
                ForEach(model.ports) { port in
                    StatusDashboardPill(text: "\(port.label) \(port.stateText)", color: port.isListening ? .green : .secondary)
                }

                Spacer(minLength: 0)

                Text(model.lastRefreshedText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    private var metricsGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
        ], spacing: 10) {
            StatusMetricTile(title: "浏览器连接", value: "\(model.activeBrowserConnections)", symbolName: "network", color: model.activeBrowserConnections > 0 ? .green : .orange)
            StatusMetricTile(title: "最近任务", value: "\(jobs.count)", symbolName: "tray.full", color: .blue)
            StatusMetricTile(title: "失败任务", value: "\(failedJobs.count)", symbolName: "exclamationmark.triangle.fill", color: failedJobs.isEmpty ? .secondary : .red)
            StatusMetricTile(title: "最新预览", value: previewFileName, symbolName: "doc.richtext", color: model.latestPreviewPDF == nil ? .secondary : .purple, compact: true)
        }
    }

    private var recentTasks: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("最近任务", systemImage: "clock")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !jobs.isEmpty {
                    Text("最多 3 条")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if recentJobs.isEmpty {
                StatusDashboardEmptyTasks()
            } else {
                VStack(spacing: 8) {
                    ForEach(recentJobs) { job in
                        StatusDashboardTaskRow(
                            job: job,
                            canRetry: job.status == .failed && !job.pdfPath.isEmpty,
                            retry: { model.retry(job: job) }
                        )
                    }
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var controls: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                Button(action: primaryAction) {
                    Label(primaryActionTitle, systemImage: primaryActionSymbol)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isServiceBusy)

                Button(action: stop) {
                    Label("停止", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.serviceState == .stopped || model.serviceState == .stopping)
            }

            HStack(spacing: 8) {
                Button(action: openPreview) {
                    Label("打开预览", systemImage: "doc.richtext")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.latestPreviewPDF == nil)

                Button(action: refresh) {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .controlSize(.regular)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: openSettings) {
                Label("工作台", systemImage: "macwindow")
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: quit) {
                Label("退出", systemImage: "power")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 0.5)
        }
    }

    private func primaryAction() {
        if model.serviceState == .running {
            restart()
        } else {
            start()
        }
    }
}

private struct StatusDashboardHealth {
    let title: String
    let detail: String
    let color: Color
    let symbolName: String
}

private struct StatusDashboardPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct StatusMetricTile: View {
    let title: String
    let value: String
    let symbolName: String
    let color: Color
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(value)
                .font(compact ? .system(size: 13, weight: .semibold) : .system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(compact ? 2 : 1)
                .truncationMode(.middle)
                .frame(height: compact ? 36 : 28, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
    }
}

private struct StatusDashboardEmptyTasks: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray")
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text("暂无打印任务")
                    .font(.system(size: 13, weight: .semibold))
                Text("从千牛提交后会显示最近打印和预览。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct StatusDashboardTaskRow: View {
    let job: QueueJob
    let canRetry: Bool
    let retry: () -> Void

    private var title: String {
        job.waybillCode.isEmpty ? job.id : job.waybillCode
    }

    private var detail: String {
        let region = job.regionText.isEmpty ? job.printerName : job.regionText
        return "\(job.receiverName) · \(region)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 5) {
                    QueueKindBadge(kind: job.kind)
                    QueueStatusBadge(status: job.status)
                }
            }

            if let error = job.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                if !job.createdAtText.isEmpty && job.createdAtText != "—" {
                    Text(job.createdAtText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer(minLength: 0)

                if job.status == .failed {
                    Button("重试", action: retry)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!canRetry)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(job.status == .failed ? Color.red.opacity(0.25) : Color.primary.opacity(0.06), lineWidth: 0.5)
        }
    }
}
