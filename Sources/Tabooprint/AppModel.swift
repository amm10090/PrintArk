import AppKit
import Foundation

enum SettingsKeys {
    static let runtimeMode = "tabooprint.runtimeMode"
    static let autoOpenPreview = "tabooprint.autoOpenPreview"
    static let printerName = "tabooprint.printerName"
    static let printMedia = "tabooprint.printMedia"
    static let printDryRun = "tabooprint.printDryRun"
    static let printFitToPage = "tabooprint.printFitToPage"
    static let printDedupe = "tabooprint.printDedupe"
    static let dedupeWindowMinutes = "tabooprint.dedupeWindowMinutes"
    static let printHideTaoLogo = "tabooprint.printHideTaoLogo"
    static let printHideCourierPackage = "tabooprint.printHideCourierPackage"
}

enum RuntimeMode: String, CaseIterable, Identifiable {
    case defaultPreview
    case respectPreviewFlag
    case failureDocumentNotFound
    case failureDecrypt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .defaultPreview: return "默认预览"
        case .respectPreviewFlag: return "尊重 preview"
        case .failureDocumentNotFound: return "缺文档失败"
        case .failureDecrypt: return "解密失败"
        }
    }

    var shortTitle: String {
        switch self {
        case .defaultPreview: return "默认"
        case .respectPreviewFlag: return "尊重"
        case .failureDocumentNotFound: return "缺文档"
        case .failureDecrypt: return "解密"
        }
    }

    static var current: RuntimeMode {
        let raw = UserDefaults.standard.string(forKey: SettingsKeys.runtimeMode) ?? RuntimeMode.defaultPreview.rawValue
        return RuntimeMode(rawValue: raw) ?? .defaultPreview
    }
}

enum ServiceState: String {
    case stopped
    case starting
    case running
    case stopping
    case error

    var title: String {
        switch self {
        case .stopped: return "已停止"
        case .starting: return "启动中"
        case .running: return "运行中"
        case .stopping: return "停止中"
        case .error: return "错误"
        }
    }

    var symbolName: String {
        switch self {
        case .stopped: return "pause.circle"
        case .starting: return "arrow.triangle.2.circlepath"
        case .running: return "printer.fill"
        case .stopping: return "stop.circle"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}

enum ServiceAction: String {
    case start
    case stop
    case restart
}

struct PortStatus: Identifiable {
    let id: Int
    let port: Int
    let label: String
    let isListening: Bool
    let listenerCount: Int

    var stateText: String { isListening ? "监听" : "关闭" }
}

struct RecentTask: Identifiable {
    let id: String
    var timestampText: String
    var command: String
    var requestID: String
    var documentCount: Int
    var mode: String
    var result: String
    var isInProgress: Bool

    var modeDisplay: String {
        switch mode {
        case "default-preview": return "默认预览"
        case "respect-preview-flag": return "尊重 preview"
        case "failure-document-not-found": return "缺文档失败"
        case "failure-decrypt": return "解密失败"
        case "physical-dry-run": return "模拟打印"
        case "physical-print": return "真实打印"
        case "physical-duplicate-suppressed": return "重复跳过"
        default: return mode
        }
    }

    var resultDisplay: String {
        if isInProgress { return "进行中" }
        switch result {
        case "preview": return "预览成功"
        case "notifyPrintResult": return "物理打印"
        case "physical-dry-run": return "模拟打印"
        case "physical-print": return "真实打印"
        case "physical-duplicate-suppressed": return "重复跳过"
        case "physical-print-failed": return "打印失败"
        case "document-not-found": return "文档缺失"
        case "decrypt-failure": return "解密失败"
        default:
            return result.isEmpty ? "完成" : result
        }
    }

    var documentCountText: String { "\(documentCount)" }
}

struct SupervisorSnapshot {
    let serviceState: ServiceState
    let serviceSummary: String
    let ports: [PortStatus]
    let activeBrowserConnections: Int
    let recentTasks: [RecentTask]
    let printJobs: [PrintJob]
    let printerDevices: [PrinterDevice]
    let rawLogLines: [String]
    let latestPreviewPDF: URL?
    let pidIsAlive: Bool
}

struct CommandResult {
    let exitCode: Int32
    let output: String
}

struct PrintSettings {
    var printerName: String
    var media: String
    var dryRun: Bool
    var fitToPage: Bool
    var dedupe: Bool
    var dedupeWindowMinutes: Int
    var hideTaoLogo: Bool = false
    var hideCourierPackage: Bool = false

    static var current: PrintSettings {
        let defaults = UserDefaults.standard
        let printerName = defaults.string(forKey: SettingsKeys.printerName) ?? "TAOBAO"
        let media = defaults.string(forKey: SettingsKeys.printMedia) ?? "100x180mm"
        let dryRun = defaults.object(forKey: SettingsKeys.printDryRun) as? Bool ?? true
        let fitToPage = defaults.object(forKey: SettingsKeys.printFitToPage) as? Bool ?? true
        let dedupe = defaults.object(forKey: SettingsKeys.printDedupe) as? Bool ?? true
        let dedupeWindowMinutes = defaults.object(forKey: SettingsKeys.dedupeWindowMinutes) as? Int ?? 10
        let hideTaoLogo = defaults.object(forKey: SettingsKeys.printHideTaoLogo) as? Bool ?? false
        let hideCourierPackage = defaults.object(forKey: SettingsKeys.printHideCourierPackage) as? Bool ?? false
        return PrintSettings(
            printerName: printerName.isEmpty ? "TAOBAO" : printerName,
            media: media,
            dryRun: dryRun,
            fitToPage: fitToPage,
            dedupe: dedupe,
            dedupeWindowMinutes: dedupeWindowMinutes,
            hideTaoLogo: hideTaoLogo,
            hideCourierPackage: hideCourierPackage
        )
    }
}

@MainActor
final class AppModel: NSObject, ObservableObject {
    @Published var serviceState: ServiceState = .stopped
    @Published var serviceSummary: String = "未启动"
    @Published var ports: [PortStatus] = []
    @Published var activeBrowserConnections: Int = 0
    @Published var recentTasks: [RecentTask] = []
    @Published var printJobs: [PrintJob] = []
    @Published var printerDevices: [PrinterDevice] = [.fallback]
    @Published var redactedLogs: String = ""
    @Published var latestPreviewPDF: URL?
    @Published var lastActionOutput: String = ""
    @Published var lastRefreshedText: String = "从未刷新"

    private let printService = NativePrintService()
    private var pollingTimer: Timer?
    private var logViewerLineBaseline = 0
    private var lastRawLogLineCount = 0

    var onRefresh: (() -> Void)?

    func startPolling() {
        stopPolling()
        pollingTimer = Timer.scheduledTimer(timeInterval: 2.0, target: self, selector: #selector(pollTimerFired(_:)), userInfo: nil, repeats: true)
    }

    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    func refresh() {
        let snapshot = printService.snapshot()
        apply(snapshot: snapshot)
    }

    func startService() {
        launchService(action: .start)
    }

    func stopService() {
        launchService(action: .stop)
    }

    func restartService() {
        launchService(action: .restart)
    }

    /// 立即应用当前打印设置，并在可能时重渲染最近一张真实面单预览。
    func applyPrintSettings() {
        let didRerender = printService.applyPrintSettings(PrintSettings.current)
        apply(snapshot: printService.snapshot())
        if didRerender {
            lastActionOutput = "已按新设置更新预览"
        }
    }

    func openLatestPreview() {
        guard let url = printService.latestPreviewPDF else {
            lastActionOutput = "未找到预览 PDF"
            return
        }
        NSWorkspace.shared.open(url)
        lastActionOutput = "已打开：\(url.lastPathComponent)"
    }

    func clearLogViewer() {
        logViewerLineBaseline = lastRawLogLineCount
        redactedLogs = ""
        onRefresh?()
    }

    private func launchService(action: ServiceAction) {
        let runtimeMode = RuntimeMode.current
        let autoOpenPreview = UserDefaults.standard.object(forKey: SettingsKeys.autoOpenPreview) as? Bool ?? true
        let printSettings = PrintSettings.current

        serviceState = action == .stop ? .stopping : .starting
        let dedupeText = printSettings.dedupe ? "去重 \(printSettings.dedupeWindowMinutes) 分钟" : "去重关闭"
        serviceSummary = "\(serviceState.title) • \(runtimeMode.title) • \(printSettings.dryRun ? "模拟打印" : "真实打印") • \(dedupeText)"

        let configuration = PrintServiceConfiguration.current(
            runtimeMode: runtimeMode,
            autoOpenPreview: autoOpenPreview,
            printSettings: printSettings
        )
        let result: CommandResult
        switch action {
        case .start:
            result = printService.start(configuration: configuration)
        case .stop:
            result = printService.stop()
        case .restart:
            result = printService.restart(configuration: configuration)
        }
        lastActionOutput = result.output.isEmpty ? "命令已执行" : result.output
        apply(snapshot: printService.snapshot())
        if result.exitCode != 0 {
            serviceState = .error
            serviceSummary = "错误 • \(lastActionOutput)"
        }
    }

    private func apply(snapshot: SupervisorSnapshot) {
        serviceState = snapshot.serviceState
        serviceSummary = snapshot.serviceSummary
        ports = snapshot.ports
        activeBrowserConnections = snapshot.activeBrowserConnections
        recentTasks = Array(snapshot.recentTasks.prefix(20))
        printJobs = Array(snapshot.printJobs.prefix(12))
        printerDevices = snapshot.printerDevices
        latestPreviewPDF = snapshot.latestPreviewPDF
        lastRawLogLineCount = snapshot.rawLogLines.count

        let startIndex = min(logViewerLineBaseline, snapshot.rawLogLines.count)
        let visibleLines = Array(snapshot.rawLogLines.dropFirst(startIndex))
        redactedLogs = visibleLines.map(redactLogLine(_:)).joined(separator: "\n")
        lastRefreshedText = Self.timestampFormatter.string(from: Date())
        onRefresh?()
    }

    private func redactLogLine(_ line: String) -> String {
        var text = line
        text = text.replacingOccurrences(of: #"\b1[3-9]\d{9}\b"#, with: "[REDACTED_PHONE]", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\b\d{12,}\b"#, with: "[REDACTED_ID]", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[A-Za-z0-9+/=]{40,}"#, with: "[REDACTED_PAYLOAD]", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)(encryptedData|signature|accessToken|token)":"[^"]*""#, with: #"$1":"[REDACTED]""#, options: .regularExpression)
        return text
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    @objc private func pollTimerFired(_ sender: Timer) {
        refresh()
    }
}
