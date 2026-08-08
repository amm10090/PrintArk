import AppKit
import Foundation

enum SettingsKeys {
    static let runtimeMode = "printark.runtimeMode"
    static let debugPreview = "printark.debugPreview"
    static let autoOpenPreview = "printark.autoOpenPreview"
    static let printerName = "printark.printerName"
    static let printMedia = "printark.printMedia"
    static let printDryRun = "printark.printDryRun"
    static let printFitToPage = "printark.printFitToPage"
    static let printDedupe = "printark.printDedupe"
    static let dedupeWindowMinutes = "printark.dedupeWindowMinutes"
    static let printHideTaoLogo = "printark.printHideTaoLogo"
    static let printHideCourierPackage = "printark.printHideCourierPackage"
    static let printHideBorder = "printark.printHideBorder"
    static let printFlip = "printark.printFlip"
    static let printerCalibrations = "printark.printerCalibrations"
    static let fontSizeItemInfoMM = "printark.fontSizeItemInfoMM"
    static let fontSizeMemoMM = "printark.fontSizeMemoMM"
    /// 菜单栏弹窗中已被用户隐藏（删除/清空已完成）的 QueueJob.id 集合，持久化以避免重启后“复活”。
    static let dismissedJobIDs = "printark.dismissedJobIDs"
    /// 启动时自动检查 GitHub 新版本（默认开，静默检查，仅有新版才提示）。
    static let autoCheckUpdate = "printark.autoCheckUpdate"
}

/// UserDefaults 键迁移：产品标识从 `Tabooprint` 改名 `PrintArk` 后，
/// 旧用户的设置存在 `tabooprint.*` 键下，新代码读 `printark.*`，需一次性搬迁
/// 避免现有设置（含 v1.0.0 实测的字号 3.5/5.5、纸张 74×126 等）回退出厂默认。
///
/// 必须在 `FactoryDefaults.register()` **之前**调用：迁移值要优先于注册默认值，
/// 而 register(defaults:) 只填未设置的键，因此「先迁移 → 再注册」既保住旧值
/// 又不覆盖用户显式值。
enum SettingsMigration {
    /// 旧 → 新键映射（含全部扁平键与 `printerCalibrations` JSON 整表键）。
    private static let keyMap: [(old: String, new: String)] = [
        ("tabooprint.runtimeMode", SettingsKeys.runtimeMode),
        ("tabooprint.debugPreview", SettingsKeys.debugPreview),
        ("tabooprint.autoOpenPreview", SettingsKeys.autoOpenPreview),
        ("tabooprint.printerName", SettingsKeys.printerName),
        ("tabooprint.printMedia", SettingsKeys.printMedia),
        ("tabooprint.printDryRun", SettingsKeys.printDryRun),
        ("tabooprint.printFitToPage", SettingsKeys.printFitToPage),
        ("tabooprint.printDedupe", SettingsKeys.printDedupe),
        ("tabooprint.dedupeWindowMinutes", SettingsKeys.dedupeWindowMinutes),
        ("tabooprint.printHideTaoLogo", SettingsKeys.printHideTaoLogo),
        ("tabooprint.printHideCourierPackage", SettingsKeys.printHideCourierPackage),
        ("tabooprint.printHideBorder", SettingsKeys.printHideBorder),
        ("tabooprint.printFlip", SettingsKeys.printFlip),
        ("tabooprint.printerCalibrations", SettingsKeys.printerCalibrations),
        ("tabooprint.fontSizeItemInfoMM", SettingsKeys.fontSizeItemInfoMM),
        ("tabooprint.fontSizeMemoMM", SettingsKeys.fontSizeMemoMM),
    ]

    /// 幂等迁移：仅当新键无值且旧键有值时拷贝。新键一旦有值（已迁移或用户改过）
    /// 就不再覆盖，多次启动安全。保留旧键不删，便于回滚到旧版本时设置仍在。
    static func migrateLegacyKeysIfNeeded() {
        let defaults = UserDefaults.standard
        for (old, new) in keyMap where defaults.object(forKey: new) == nil {
            if let value = defaults.object(forKey: old) {
                defaults.set(value, forKey: new)
            }
        }
    }
}

/// App 版本号单一数据源。版本页与日志引用此常量；
/// build 脚本的 Info.plist（CFBundleShortVersionString）需人工对齐同一字面。
/// 注意：协议伪装字段（getAgentInfo 的 "1.5.3.0"）不是 App 版本，与此无关。
enum AppInfo {
    static let version = "1.1.16"

    /// 构建日期（本地化短日期）。以可执行文件的修改时间作为编译期代理——
    /// `.app` 包与 `swift run` 都能取到，无需编译期注入宏。
    static let buildDate: String = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let path = Bundle.main.executablePath
            ?? CommandLine.arguments.first
        if let path,
           let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let date = attrs[.modificationDate] as? Date {
            return formatter.string(from: date)
        }
        return formatter.string(from: Date())
    }()
}

/// 出厂默认设置（集中注册）。仅对从未被显式写入的扁平键生效——
/// 已有用户的已选值（更高优先级 domain）原样保留，满足「仅新装生效」。
/// 校准类（offset/rotation/scale/adaptivePaper）按打印机存于 printerCalibrations JSON，
/// register(defaults:) 覆盖不到，由 PrinterCalibration.factoryDefault 兜底。
///
/// 一致性约束：此表的默认值必须与各 `@AppStorage(...) = X` 字面值、
/// 以及 `PrintSettings.current` 的 `?? 默认` 完全一致，否则两套默认值漂移。
enum FactoryDefaults {
    static func register() {
        let values: [String: Any] = [
            SettingsKeys.printMedia: "74x126mm",
            SettingsKeys.printFitToPage: true,
            SettingsKeys.printDedupe: false,
            SettingsKeys.printFlip: true,
            SettingsKeys.printHideTaoLogo: true,
            SettingsKeys.printHideCourierPackage: true,
            SettingsKeys.printHideBorder: true,
            SettingsKeys.fontSizeItemInfoMM: 3.5,
            SettingsKeys.fontSizeMemoMM: 5.5,
            SettingsKeys.debugPreview: false,
            SettingsKeys.autoCheckUpdate: true,
        ]
        UserDefaults.standard.register(defaults: values)
    }
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

    /// 版本页健康状态行的颜色语义。
    var health: HealthStatusRow.Health {
        switch self {
        case .stopped: return .neutral
        case .starting, .stopping: return .pending
        case .running: return .ok
        case .error: return .error
        }
    }
}

enum ServiceAction: String {
    case start
    case stop
    case restart
}

struct PortStatus: Identifiable, Equatable {
    let id: Int
    let port: Int
    let label: String
    let isListening: Bool
    let listenerCount: Int
    var ownerDescription: String? = nil

    var stateText: String {
        if isListening { return "监听" }
        if ownerDescription != nil { return "占用" }
        return "关闭"
    }
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
    /// 文档级真实数据（运单号/收件人/地区）。无真实数据时为空，下游回退占位。
    var documents: [QueueDocument] = []

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

struct SupervisorSnapshotToken: Equatable {
    let serviceState: ServiceState
    let serviceSummary: String
    let ports: [PortStatus]
    let activeBrowserConnections: Int
    let logRevision: Int
    let latestPreviewPDF: URL?
    let printerDevices: [PrinterDevice]
}

struct SupervisorSnapshot {
    let token: SupervisorSnapshotToken
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
    var hideBorder: Bool = false
    var flipPrint: Bool = false
    // 面单字段字号（mm），全局偏好，预览与物理打印同源生效。
    var itemInfoFontMM: Double = 3.2
    var memoFontMM: Double = 2.5
    // 按打印机校准（由 resolvedPrintSettings() 从 AppModel.printerCalibrations 注入，不读扁平键）。
    var offsetXMM: Double = 0
    var offsetYMM: Double = 0
    var rotationDegrees: Int = 0
    var scaleRatio: Double = 1.0
    var adaptivePaper: Bool = false

    /// 渲染用的校准视图，从已注入的字段聚合。
    var calibration: PrinterCalibration {
        PrinterCalibration(offsetXMM: offsetXMM, offsetYMM: offsetYMM, rotationDegrees: rotationDegrees, scaleRatio: scaleRatio, adaptivePaper: adaptivePaper)
    }

    static var current: PrintSettings {
        let defaults = UserDefaults.standard
        let printerName = defaults.string(forKey: SettingsKeys.printerName) ?? "TAOBAO"
        let media = defaults.string(forKey: SettingsKeys.printMedia) ?? "74x126mm"
        let dryRun = defaults.object(forKey: SettingsKeys.printDryRun) as? Bool ?? true
        let fitToPage = defaults.object(forKey: SettingsKeys.printFitToPage) as? Bool ?? true
        let dedupe = defaults.object(forKey: SettingsKeys.printDedupe) as? Bool ?? false
        let dedupeWindowMinutes = defaults.object(forKey: SettingsKeys.dedupeWindowMinutes) as? Int ?? 10
        let hideTaoLogo = defaults.object(forKey: SettingsKeys.printHideTaoLogo) as? Bool ?? true
        let hideCourierPackage = defaults.object(forKey: SettingsKeys.printHideCourierPackage) as? Bool ?? true
        let hideBorder = defaults.object(forKey: SettingsKeys.printHideBorder) as? Bool ?? true
        let flipPrint = defaults.object(forKey: SettingsKeys.printFlip) as? Bool ?? true
        let itemInfoFontMM = defaults.object(forKey: SettingsKeys.fontSizeItemInfoMM) as? Double ?? 3.5
        let memoFontMM = defaults.object(forKey: SettingsKeys.fontSizeMemoMM) as? Double ?? 5.5
        return PrintSettings(
            printerName: printerName.isEmpty ? "TAOBAO" : printerName,
            media: media,
            dryRun: dryRun,
            fitToPage: fitToPage,
            dedupe: dedupe,
            dedupeWindowMinutes: dedupeWindowMinutes,
            hideTaoLogo: hideTaoLogo,
            hideCourierPackage: hideCourierPackage,
            hideBorder: hideBorder,
            flipPrint: flipPrint,
            itemInfoFontMM: itemInfoFontMM,
            memoFontMM: memoFontMM
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
    /// Only real queues discovered from macOS CUPS are exposed to the desktop UI.
    /// Cainiao protocol fallbacks (for example `TAOBAO`) are kept inside the
    /// WebSocket compatibility response and are not inserted into this list.
    @Published var printerDevices: [PrinterDevice] = []
    @Published var redactedLogs: String = ""
    @Published var latestPreviewPDF: URL?
    @Published var lastActionOutput: String = ""
    @Published var lastRefreshedText: String = "从未刷新"
    @Published var nativeHandshakeState: NativeHandshakeState = .idle
    @Published var localTLSTrustState: LocalTLSTrustState = .missing
    @Published var isInstallingLocalTLSCertificate = false

    /// 菜单栏弹窗中被用户隐藏（删除/清空已完成）的 QueueJob.id。持久化到 UserDefaults，避免重启后“复活”。
    /// 队列为派生只读状态（每 2s 从事件日志重算），删除语义是“从弹窗视图移除”而非抹掉底层审计日志。
    @Published var dismissedJobIDs: Set<String> = AppModel.loadDismissedJobIDs()

    /// 是否已完成首屏快照加载。用于菜单栏弹窗区分“加载骨架态”与“空态”。
    @Published var hasLoadedOnce: Bool = false

    /// 按打印机名持久化的校准设置。整张表以 JSON 存于单个 UserDefaults 键，
    /// 因为 @AppStorage 无法按打印机名动态建键。
    @Published var printerCalibrations: [String: PrinterCalibration] = AppModel.loadCalibrations()

    /// 当前预览 PDF 里**已烘焙**的校准值。预览层叠加「当前校准 − bakedCalibration」的
    /// 增量变换实现实时平滑预览；每当 latestPreviewPDF 的 URL 变化（web 端打单或内容类
    /// 重渲染），同步为当前打印机校准，使增量归零、切换无跳变。
    @Published var bakedCalibration: PrinterCalibration = .identity

    private let printService = NativePrintService()
    private let localTLSIdentityManager = LocalTLSIdentityManager()
    private var pollingTimer: Timer?
    private var eventRefreshTimer: Timer?
    private var logViewerLineBaseline = 0
    private var lastRawLogLineCount = 0
    private var lastAppliedSnapshotToken: SupervisorSnapshotToken?
    private var lastWakeRestartAt: Date?
    private var handshakeGeneration = 0

    private static let fallbackRefreshInterval: TimeInterval = 20
    private static let fallbackRefreshTolerance: TimeInterval = 5
    private static let eventRefreshDebounce: TimeInterval = 0.18
    private static let wakeRestartDebounce: TimeInterval = 10
    private static let wakeRestartDelayNanoseconds: UInt64 = 1_500_000_000

    private lazy var handshakeCoordinator: NativeHandshakeCoordinator = {
        let service = printService
        let eventSink: @Sendable (NativeHandshakeEvent) -> Void = { event in
            service.appendNativeHandshakeEvent(event)
        }
        guard let credentials = CainiaoHandshakeCredentials.load() else {
            return NativeHandshakeCoordinator(operation: nil, eventSink: eventSink)
        }
        let client = CainiaoHandshakeClient(
            credentials: credentials,
            transport: URLSessionCainiaoHandshakeTransport()
        )
        return NativeHandshakeCoordinator(
            operation: { try await client.perform() },
            eventSink: eventSink
        )
    }()

    var onRefresh: (() -> Void)?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(nativeServiceDidChange(_:)),
            name: NativePrintService.didChangeNotification,
            object: printService
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// 让本机服务的事件日志同时写到标准输出，方便在 Xcode 控制台 / 终端实时查看。
    /// GUI 模式默认不接 sink（日志只进窗口内的查看器），调试时调用此方法即可镜像到 stdout。
    func enableConsoleLogging() {
        printService.setLogSink { line in
            print(line)
            fflush(stdout)
        }
    }

    func startPolling() {
        stopPolling()
        pollingTimer = Timer.scheduledTimer(
            timeInterval: Self.fallbackRefreshInterval,
            target: self,
            selector: #selector(pollTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
        pollingTimer?.tolerance = Self.fallbackRefreshTolerance
    }

    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        eventRefreshTimer?.invalidate()
        eventRefreshTimer = nil
    }

    func refresh() {
        refresh(forcePrinterRefresh: false, onlyIfChanged: false)
    }

    func refreshPrinters() {
        refresh(forcePrinterRefresh: true, onlyIfChanged: false)
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

    /// 失败任务重试：复用已渲染并落盘的 PDF 重新执行 lpr，绕过 10 分钟去重，沿用当前 dryRun 设置。
    /// Process 在后台执行避免阻塞主线程，结果回主线程写 lastActionOutput 并刷新快照。
    func retry(job: QueueJob) {
        retry(requestID: job.id, pdfPath: job.pdfPath, printerName: job.printerName, waybillCode: job.waybillCode)
    }

    /// 失败列表（侧边栏「失败重试」页）用 PrintJob 触发重试的入口。
    func retry(job: PrintJob) {
        retry(requestID: job.id, pdfPath: job.pdfPath, printerName: job.printerName, waybillCode: job.waybillCode)
    }

    private func retry(requestID: String, pdfPath: String, printerName: String, waybillCode: String) {
        guard !pdfPath.isEmpty else {
            lastActionOutput = "重试失败：任务 \(waybillCode) 缺少 PDF 路径"
            return
        }
        lastActionOutput = "正在重试：\(waybillCode)…"
        let service = printService
        Task.detached {
            let job = service.retryPhysicalPrint(requestID: requestID, pdfPath: pdfPath, printerName: printerName)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if job.ok {
                    self.lastActionOutput = job.dryRun
                        ? "已重试（模拟）：\(waybillCode) · \(job.printerName)"
                        : "已重试打印：\(waybillCode) · \(job.printerName)"
                } else {
                    self.lastActionOutput = "重试失败：\(waybillCode) · \(job.error ?? "未知错误")"
                }
                self.refresh()
            }
        }
    }

    /// 当前生效的打印设置：以 debugPreview 为唯一来源翻译 dryRun，
    /// 避免读到无人写入的历史 `printDryRun` 键（恒为 true）而把真实打印误降级为模拟。
    private func resolvedPrintSettings() -> PrintSettings {
        var settings = PrintSettings.current
        settings.dryRun = UserDefaults.standard.bool(forKey: SettingsKeys.debugPreview)
        // 注入当前选中打印机的校准；服务端消费这些具体值（不再按名二次查表）。
        // 无记录打印机回退到出厂默认（自适应纸张开），而非纯零基线 identity。
        let cal = printerCalibrations[settings.printerName] ?? .factoryDefault
        settings.offsetXMM = cal.offsetXMM
        settings.offsetYMM = cal.offsetYMM
        settings.rotationDegrees = cal.rotationDegrees
        settings.scaleRatio = cal.scaleRatio
        settings.adaptivePaper = cal.adaptivePaper
        return settings
    }

    /// 从 UserDefaults 解码校准表；缺失或损坏时回退到空表。
    private static func loadCalibrations() -> [String: PrinterCalibration] {
        guard let data = UserDefaults.standard.data(forKey: SettingsKeys.printerCalibrations),
              let decoded = try? JSONDecoder().decode([String: PrinterCalibration].self, from: data) else {
            return [:]
        }
        return decoded
    }

    /// 从 UserDefaults 加载已隐藏的任务 id 集合；缺失/损坏回退空集。
    private static func loadDismissedJobIDs() -> Set<String> {
        guard let stored = UserDefaults.standard.array(forKey: SettingsKeys.dismissedJobIDs) as? [String] else {
            return []
        }
        return Set(stored)
    }

    /// 把当前 dismissedJobIDs 编码写回 UserDefaults。
    func saveDismissedJobIDs() {
        UserDefaults.standard.set(Array(dismissedJobIDs), forKey: SettingsKeys.dismissedJobIDs)
    }

    /// 将当前校准表编码写回 UserDefaults。
    func saveCalibrations() {
        guard let data = try? JSONEncoder().encode(printerCalibrations) else { return }
        UserDefaults.standard.set(data, forKey: SettingsKeys.printerCalibrations)
    }

    /// 应用当前打印设置。预览的实时变化由 `printerCalibrations`（@Published）驱动的
    /// 增量变换层负责，像素级精确且无需重绘 PDF —— 因此纯校准变化**不重渲染预览**，
    /// 只把设置推给服务供下次打印使用，彻底消除每次步进都闪屏的问题。
    func applyPrintSettings() {
        printService.updateConfiguration(resolvedPrintSettings())
    }

    /// 立即按当前设置重烘焙最近一张面单并刷新快照。
    /// 用于内容类变化（隐藏标记、纸张、打印机切换）等确实需要重绘 PDF 的场景。
    func rebakePreviewNow() {
        let didRerender = printService.applyPrintSettings(resolvedPrintSettings())
        apply(snapshot: printService.snapshot(), onlyIfChanged: false)
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
        handshakeGeneration &+= 1
        // 调试预览开关是唯一的用户概念：关闭=真实物理打印，开启=仅生成 PDF 预览。
        // 它在这里翻译为底层 runtimeMode + dryRun，CLI（--service-only）路径不受影响。
        let debugPreview = UserDefaults.standard.bool(forKey: SettingsKeys.debugPreview)
        let runtimeMode: RuntimeMode = debugPreview ? .defaultPreview : .respectPreviewFlag
        let autoOpenPreview = UserDefaults.standard.object(forKey: SettingsKeys.autoOpenPreview) as? Bool ?? true
        let printSettings = resolvedPrintSettings() // dryRun 由 debugPreview 翻译，忽略历史残留值

        serviceState = action == .stop ? .stopping : .starting
        let dedupeText = printSettings.dedupe ? "去重 \(printSettings.dedupeWindowMinutes) 分钟" : "去重关闭"
        let modeText = debugPreview ? "调试预览" : "真实打印"
        serviceSummary = "\(serviceState.title) • \(modeText) • \(dedupeText)"

        let configuration = PrintServiceConfiguration.current(
            runtimeMode: runtimeMode,
            autoOpenPreview: autoOpenPreview,
            printSettings: printSettings
        )
        let restartStopResult: CommandResult?
        if action == .restart {
            restartStopResult = printService.stop()
        } else {
            restartStopResult = nil
        }
        let result: CommandResult
        switch action {
        case .start:
            result = printService.start(configuration: configuration)
        case .stop:
            result = printService.stop()
        case .restart:
            let startResult = printService.start(configuration: configuration)
            let output = [restartStopResult?.output, startResult.output]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            result = CommandResult(exitCode: startResult.exitCode, output: output)
        }
        lastActionOutput = result.output.isEmpty ? "命令已执行" : result.output
        apply(snapshot: printService.snapshot(forcePrinterRefresh: true), onlyIfChanged: false)
        if result.exitCode != 0 {
            serviceState = .error
            serviceSummary = "错误 • \(lastActionOutput)"
        } else if action == .stop {
            nativeHandshakeState = .idle
        } else {
            refreshLocalTLSTrustState()
            triggerNativeHandshake(reason: action == .restart ? .manualRestart : .startup)
        }
    }

    private func refresh(forcePrinterRefresh: Bool, onlyIfChanged: Bool) {
        let snapshot = printService.snapshot(forcePrinterRefresh: forcePrinterRefresh)
        apply(snapshot: snapshot, onlyIfChanged: onlyIfChanged)
    }

    private func refreshIfChanged(forcePrinterRefresh: Bool = false) {
        refresh(forcePrinterRefresh: forcePrinterRefresh, onlyIfChanged: true)
    }

    private func scheduleEventRefresh() {
        eventRefreshTimer?.invalidate()
        eventRefreshTimer = Timer.scheduledTimer(
            timeInterval: Self.eventRefreshDebounce,
            target: self,
            selector: #selector(eventRefreshTimerFired(_:)),
            userInfo: nil,
            repeats: false
        )
    }

    private func apply(snapshot: SupervisorSnapshot, onlyIfChanged: Bool) {
        if onlyIfChanged, hasLoadedOnce, snapshot.token == lastAppliedSnapshotToken {
            return
        }
        lastAppliedSnapshotToken = snapshot.token
        serviceState = snapshot.serviceState
        serviceSummary = combinedServiceSummary(snapshot.serviceSummary)
        ports = snapshot.ports
        activeBrowserConnections = snapshot.activeBrowserConnections
        recentTasks = Array(snapshot.recentTasks.prefix(20))
        printJobs = Array(snapshot.printJobs.prefix(12))
        printerDevices = snapshot.printerDevices
        hasLoadedOnce = true
        // 预览 PDF 的 URL 变化意味着烘焙了新内容（web 端打单或自身防抖重烘焙），
        // 此时其中烘焙的校准就是当前打印机校准——同步 bakedCalibration 令增量变换归零。
        let previousPreview = latestPreviewPDF
        latestPreviewPDF = snapshot.latestPreviewPDF
        if let url = snapshot.latestPreviewPDF, url != previousPreview {
            bakedCalibration = printerCalibrations[PrintSettings.current.printerName] ?? .identity
        }
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
        refreshIfChanged()
    }

    @objc private func eventRefreshTimerFired(_ sender: Timer) {
        eventRefreshTimer = nil
        refreshIfChanged()
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        scheduleWakeRestart()
    }

    private func scheduleWakeRestart() {
        let now = Date()
        if let lastWakeRestartAt, now.timeIntervalSince(lastWakeRestartAt) < Self.wakeRestartDebounce {
            return
        }
        lastWakeRestartAt = now
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.wakeRestartDelayNanoseconds)
            self?.restartServiceAfterWake()
        }
    }

    private func restartServiceAfterWake() {
        guard printService.snapshot().pidIsAlive else { return }
        handshakeGeneration &+= 1
        printService.appendDiagnosticLog("Wake recovery restarting PrintArk listeners before native handshake")
        let result = printService.restart(configuration: PrintServiceConfiguration.current(
            runtimeMode: UserDefaults.standard.bool(forKey: SettingsKeys.debugPreview) ? .defaultPreview : .respectPreviewFlag,
            autoOpenPreview: UserDefaults.standard.object(forKey: SettingsKeys.autoOpenPreview) as? Bool ?? true,
            printSettings: resolvedPrintSettings()
        ))
        lastActionOutput = result.exitCode == 0
            ? "从睡眠唤醒后已自动重启本机服务并刷新原生握手"
            : "唤醒后自动重启服务失败：\(result.output)"
        apply(snapshot: printService.snapshot(forcePrinterRefresh: true), onlyIfChanged: false)
        if result.exitCode == 0 {
            refreshLocalTLSTrustState()
            triggerNativeHandshake(reason: .wake)
        }
    }

    @objc private func nativeServiceDidChange(_ notification: Notification) {
        scheduleEventRefresh()
    }

    func installLocalTLSCertificate() {
        guard !isInstallingLocalTLSCertificate else { return }
        isInstallingLocalTLSCertificate = true
        lastActionOutput = "正在安装本机安全证书…"
        let manager = localTLSIdentityManager
        Task.detached { [weak self] in
            let result = manager.installTrust()
            let trustState = manager.trustState()
            await MainActor.run {
                guard let self else { return }
                self.isInstallingLocalTLSCertificate = false
                self.localTLSTrustState = trustState
                self.lastActionOutput = result.message
            }
        }
    }

    func refreshLocalTLSTrustState() {
        let manager = localTLSIdentityManager
        Task.detached { [weak self] in
            let state = manager.trustState()
            await MainActor.run {
                self?.localTLSTrustState = state
            }
        }
    }

    private func triggerNativeHandshake(reason: NativeHandshakeReason) {
        nativeHandshakeState = .running
        serviceSummary = combinedServiceSummary(printService.snapshot().serviceSummary)
        let coordinator = handshakeCoordinator
        let generation = handshakeGeneration
        Task { @MainActor [weak self] in
            let state = await coordinator.trigger(reason: reason)
            guard let self,
                  Self.shouldApplyNativeHandshakeResult(
                      generation: generation,
                      currentGeneration: self.handshakeGeneration,
                      serviceState: self.serviceState
                  ) else { return }
            self.nativeHandshakeState = state
            self.serviceSummary = self.combinedServiceSummary(self.printService.snapshot().serviceSummary)
            switch state {
            case .ready:
                self.lastActionOutput = "原生菜鸟握手已完成"
            case .credentialsMissing:
                self.lastActionOutput = "本地服务已启动，但远端握手凭据缺失"
            case let .failed(category):
                self.lastActionOutput = "本地服务已启动，远端握手失败：\(category)"
            case .idle, .running:
                break
            }
        }
    }

    static func shouldApplyNativeHandshakeResult(
        generation: Int,
        currentGeneration: Int,
        serviceState: ServiceState
    ) -> Bool {
        generation == currentGeneration && serviceState == .running
    }

    private func combinedServiceSummary(_ base: String) -> String {
        guard serviceState == .running else { return base }
        switch nativeHandshakeState {
        case .idle:
            return base
        case .running:
            return "\(base) • 原生握手中"
        case .ready:
            return "\(base) • 原生握手正常"
        case .failed:
            return "\(base) • 原生握手失败"
        case .credentialsMissing:
            return "\(base) • 握手凭据缺失"
        }
    }
}
