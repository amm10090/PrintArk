import AppKit
import Foundation

enum SettingsKeys {
    static let runtimeMode = "tabooprint.runtimeMode"
    static let autoOpenPreview = "tabooprint.autoOpenPreview"
    static let printerName = "tabooprint.printerName"
    static let printMedia = "tabooprint.printMedia"
    static let printDryRun = "tabooprint.printDryRun"
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

    var shellArguments: [String] {
        switch self {
        case .defaultPreview:
            return []
        case .respectPreviewFlag:
            return ["--force-preview", "false"]
        case .failureDocumentNotFound:
            return ["--fail", "document-not-found"]
        case .failureDecrypt:
            return ["--fail", "decrypt"]
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
        case "physical-dry-run": return "打印 dry-run"
        case "physical-print": return "真实打印"
        default: return mode
        }
    }

    var resultDisplay: String {
        if isInProgress { return "进行中" }
        switch result {
        case "preview": return "预览成功"
        case "notifyPrintResult": return "物理打印"
        case "physical-dry-run": return "打印 dry-run"
        case "physical-print": return "真实打印"
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

    var shellArguments: [String] {
        var arguments = [
            "--printer-name", printerName,
            "--print-dry-run", dryRun ? "true" : "false",
        ]
        if !media.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["--print-media", media]
        }
        return arguments
    }

    static var current: PrintSettings {
        let defaults = UserDefaults.standard
        let printerName = defaults.string(forKey: SettingsKeys.printerName) ?? "TAOBAO"
        let media = defaults.string(forKey: SettingsKeys.printMedia) ?? ""
        let dryRun = defaults.object(forKey: SettingsKeys.printDryRun) as? Bool ?? true
        return PrintSettings(printerName: printerName.isEmpty ? "TAOBAO" : printerName, media: media, dryRun: dryRun)
    }
}

private struct MockLogEvent: Decodable {
    let type: String?
    let time: String?
    let phase: String?
    let command: String?
    let requestID: String?
    let taskID: String?
    let documentCount: Int?
    let mode: String?
    let result: String?
    let activeConnections: Int?
    let port: Int?
}

final class ServiceSupervisor: @unchecked Sendable {
    let repoRoot: URL
    let scriptURL: URL
    let pidFileURL: URL
    let logFileURL: URL
    let previewDirectoryURL: URL

    private let shellURL = URL(fileURLWithPath: "/bin/zsh")

    init() {
        let root = ServiceSupervisor.locateRepositoryRoot() ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        repoRoot = root
        scriptURL = root.appendingPathComponent("scripts/cainiao_mock.sh")
        pidFileURL = root.appendingPathComponent(".cainiao-mock.pid")
        logFileURL = root.appendingPathComponent(".cainiao-mock.log")
        previewDirectoryURL = URL(fileURLWithPath: "/Users/amo/cainiao-x-print/preview")
    }

    func perform(_ action: ServiceAction, runtimeMode: RuntimeMode, autoOpenPreview: Bool, printSettings: PrintSettings) -> (result: CommandResult, snapshot: SupervisorSnapshot) {
        let arguments: [String]
        switch action {
        case .start, .restart:
            arguments = [action.rawValue]
                + runtimeMode.shellArguments
                + ["--auto-open-preview", autoOpenPreview ? "true" : "false"]
                + printSettings.shellArguments
        case .stop:
            arguments = [action.rawValue]
        }

        let result = runShellScript(arguments: arguments)
        let expectedState: ServiceState? = action == .stop ? .stopped : .running
        let snapshot = waitForStableSnapshot(expectedState: expectedState, timeout: 6.0)
        return (result, snapshot)
    }

    func collectSnapshot() -> SupervisorSnapshot {
        let pid = readPid()
        let pidIsAlive = pid.map(isProcessAlive(_:)) ?? false
        let wsPort = portStatus(port: 13528, label: "WS")
        let httpPort = portStatus(port: 13525, label: "HTTP")
        let ports = [wsPort, httpPort]
        let activeBrowserConnections = establishedConnectionCount(on: 13528)
        let rawLogLines = readLogLines(maxLines: 1200)
        let recentTasks = parseRecentTasks(from: rawLogLines)
        let serviceState = deriveServiceState(pidIsAlive: pidIsAlive, ports: ports)
        let serviceSummary = buildServiceSummary(state: serviceState, ports: ports, connections: activeBrowserConnections)
        let latestPreviewPDF = findLatestPreviewPDF()
        return SupervisorSnapshot(
            serviceState: serviceState,
            serviceSummary: serviceSummary,
            ports: ports,
            activeBrowserConnections: activeBrowserConnections,
            recentTasks: recentTasks,
            rawLogLines: rawLogLines,
            latestPreviewPDF: latestPreviewPDF,
            pidIsAlive: pidIsAlive
        )
    }

    func openLatestPreviewPDF() -> URL? {
        findLatestPreviewPDF()
    }

    private func waitForStableSnapshot(expectedState: ServiceState?, timeout: TimeInterval) -> SupervisorSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        var snapshot = collectSnapshot()

        while Date() < deadline {
            if let expectedState, snapshot.serviceState == expectedState {
                return snapshot
            }
            if expectedState == nil {
                return snapshot
            }
            Thread.sleep(forTimeInterval: 0.25)
            snapshot = collectSnapshot()
        }

        return snapshot
    }

    private func runShellScript(arguments: [String]) -> CommandResult {
        let command = ([scriptURL.path] + arguments).map(shellQuote(_:)).joined(separator: " ")
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = shellURL
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = repoRoot
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CommandResult(exitCode: -1, output: "failed to launch script: \(error.localizedDescription)")
        }

        let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combined = (stdout + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return CommandResult(exitCode: process.terminationStatus, output: combined)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func readPid() -> Int32? {
        guard let raw = try? String(contentsOf: pidFileURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int32(trimmed)
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        let result = kill(pid, 0)
        return result == 0 || errno == EPERM
    }

    private func portStatus(port: Int, label: String) -> PortStatus {
        let listeningCount = lsofCount(arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"])
        return PortStatus(id: port, port: port, label: label, isListening: listeningCount > 0, listenerCount: listeningCount)
    }

    private func establishedConnectionCount(on port: Int) -> Int {
        lsofCount(arguments: ["-nP", "-iTCP:\(port)", "-sTCP:ESTABLISHED"])
    }

    private func lsofCount(arguments: [String]) -> Int {
        guard let executable = executableURL(named: "lsof") else { return 0 }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return 0
        }

        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            return 0
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let lines = output.split(whereSeparator: \.isNewline)
        guard lines.count > 1 else { return 0 }
        return max(0, lines.count - 1)
    }

    private func readLogLines(maxLines: Int) -> [String] {
        guard let raw = try? String(contentsOf: logFileURL, encoding: .utf8), !raw.isEmpty else {
            return []
        }

        var lines = raw.components(separatedBy: .newlines)
        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }

        if lines.count > maxLines {
            lines = Array(lines.suffix(maxLines))
        }

        return lines
    }

    private func parseRecentTasks(from lines: [String]) -> [RecentTask] {
        var tasks: [String: RecentTask] = [:]

        for line in lines {
            guard let event = decodeEvent(from: line), event.type == "task", let requestID = event.requestID else {
                continue
            }

            var task = tasks[requestID] ?? RecentTask(
                id: requestID,
                timestampText: event.time ?? "",
                command: event.command ?? "print",
                requestID: requestID,
                documentCount: event.documentCount ?? 0,
                mode: event.mode ?? "",
                result: event.result ?? "in-progress",
                isInProgress: event.phase != "finish"
            )

            if let time = event.time, !time.isEmpty {
                task.timestampText = time
            }
            if let command = event.command, !command.isEmpty {
                task.command = command
            }
            if let documentCount = event.documentCount {
                task.documentCount = documentCount
            }
            if let mode = event.mode, !mode.isEmpty {
                task.mode = mode
            }
            if let result = event.result, !result.isEmpty {
                task.result = result
            }
            if event.phase == "finish" {
                task.isInProgress = false
            } else if event.phase == "start" {
                task.isInProgress = true
            }

            tasks[requestID] = task
        }

        return tasks.values.sorted {
            if $0.timestampText == $1.timestampText {
                return $0.requestID > $1.requestID
            }
            return $0.timestampText > $1.timestampText
        }
    }

    private func decodeEvent(from line: String) -> MockLogEvent? {
        let prefix = "[cainiao-mock:event] "
        guard line.hasPrefix(prefix) else { return nil }
        let jsonText = String(line.dropFirst(prefix.count))
        guard let data = jsonText.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MockLogEvent.self, from: data)
    }

    private func deriveServiceState(pidIsAlive: Bool, ports: [PortStatus]) -> ServiceState {
        let allListening = ports.allSatisfy { $0.isListening }
        let anyListening = ports.contains { $0.isListening }
        let allClosed = ports.allSatisfy { !$0.isListening }

        if pidIsAlive && allListening {
            return .running
        }
        if !pidIsAlive && allClosed {
            return .stopped
        }
        if pidIsAlive && !allListening {
            return .starting
        }
        if !pidIsAlive && anyListening {
            return .error
        }
        return .stopped
    }

    private func buildServiceSummary(state: ServiceState, ports: [PortStatus], connections: Int) -> String {
        let portSummary = ports.map { "\($0.label)\($0.stateText)" }.joined(separator: " · ")
        let connectionText = connections == 1 ? "1 个浏览器连接" : "\(connections) 个浏览器连接"
        return "\(state.title) • \(portSummary) • \(connectionText)"
    }

    private func findLatestPreviewPDF() -> URL? {
        guard FileManager.default.fileExists(atPath: previewDirectoryURL.path) else {
            return nil
        }

        let urls = (try? FileManager.default.contentsOfDirectory(
            at: previewDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }
            .first
    }

    private func executableURL(named name: String) -> URL? {
        let candidates = [
            "/usr/sbin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)",
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    private static func locateRepositoryRoot() -> URL? {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment

        var candidates: [URL] = [
            URL(fileURLWithPath: fileManager.currentDirectoryPath),
            URL(fileURLWithPath: environment["PWD"] ?? fileManager.currentDirectoryPath),
        ]

        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent())
        }

        if let commandLine = CommandLine.arguments.first, !commandLine.isEmpty {
            candidates.append(URL(fileURLWithPath: commandLine).deletingLastPathComponent())
        }

        for candidate in candidates {
            var current = candidate
            for _ in 0..<10 {
                let marker = current.appendingPathComponent("PLAN.md")
                let script = current.appendingPathComponent("scripts/mock_cainiao_server.js")
                if fileManager.fileExists(atPath: marker.path) && fileManager.fileExists(atPath: script.path) {
                    return current
                }
                let parent = current.deletingLastPathComponent()
                if parent.path == current.path {
                    break
                }
                current = parent
            }
        }

        return nil
    }
}

@MainActor
final class AppModel: NSObject, ObservableObject {
    @Published var serviceState: ServiceState = .stopped
    @Published var serviceSummary: String = "未启动"
    @Published var ports: [PortStatus] = []
    @Published var activeBrowserConnections: Int = 0
    @Published var recentTasks: [RecentTask] = []
    @Published var redactedLogs: String = ""
    @Published var latestPreviewPDF: URL?
    @Published var lastActionOutput: String = ""
    @Published var lastRefreshedText: String = "从未刷新"

    private let supervisor = ServiceSupervisor()
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
        let snapshot = supervisor.collectSnapshot()
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

    func openLatestPreview() {
        guard let url = supervisor.openLatestPreviewPDF() else {
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
        serviceSummary = "\(serviceState.title) • \(runtimeMode.title) • \(printSettings.dryRun ? "dry-run" : "真实打印")"

        let result = supervisor.perform(action, runtimeMode: runtimeMode, autoOpenPreview: autoOpenPreview, printSettings: printSettings)
        lastActionOutput = result.result.output.isEmpty ? "命令已执行" : result.result.output
        apply(snapshot: result.snapshot)
        if result.result.exitCode != 0 {
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
