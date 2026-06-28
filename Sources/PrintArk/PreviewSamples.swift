#if DEBUG
import Foundation

enum PreviewModelState: String, CaseIterable, Identifiable {
    case running
    case stoppedEmpty
    case starting
    case error
    case busyQueue
    case calibrated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .running: return "运行中"
        case .stoppedEmpty: return "空状态"
        case .starting: return "启动中"
        case .error: return "错误"
        case .busyQueue: return "队列繁忙"
        case .calibrated: return "校准"
        }
    }
}

extension ServiceState {
    static let allPreviewCases: [ServiceState] = [
        .stopped,
        .starting,
        .running,
        .stopping,
        .error,
    ]
}

@MainActor
enum PreviewSamples {
    static var previewDefaults: UserDefaults {
        let defaults = UserDefaults(suiteName: "PrintArk.Previews") ?? .standard
        defaults.set("TAOBAO", forKey: SettingsKeys.printerName)
        defaults.set("100x180mm", forKey: SettingsKeys.printMedia)
        defaults.set(true, forKey: SettingsKeys.printFitToPage)
        defaults.set(true, forKey: SettingsKeys.printDedupe)
        defaults.set(10, forKey: SettingsKeys.dedupeWindowMinutes)
        defaults.set(false, forKey: SettingsKeys.debugPreview)
        defaults.set(false, forKey: SettingsKeys.printHideTaoLogo)
        defaults.set(false, forKey: SettingsKeys.printHideCourierPackage)
        defaults.set(false, forKey: SettingsKeys.printHideBorder)
        defaults.set(false, forKey: SettingsKeys.printFlip)
        return defaults
    }

    static var consoleModel: AppModel {
        model(.running)
    }

    static func model(_ state: PreviewModelState) -> AppModel {
        let model = AppModel()
        model.printerDevices = printers
        model.printerCalibrations = calibrations
        model.bakedCalibration = .identity
        model.lastRefreshedText = "2026-06-26 22:30:00"

        switch state {
        case .running:
            model.serviceState = .running
            model.serviceSummary = "运行中 · WS 监听 · HTTP 监听 · 1 个浏览器连接"
            model.ports = listeningPorts
            model.activeBrowserConnections = 1
            model.recentTasks = recentTasks
            model.printJobs = printJobs
            model.redactedLogs = runningLogs
            model.lastActionOutput = "最近一次预览已生成"
        case .stoppedEmpty:
            model.serviceState = .stopped
            model.serviceSummary = "未启动"
            model.ports = closedPorts
            model.activeBrowserConnections = 0
            model.recentTasks = []
            model.printJobs = []
            model.redactedLogs = ""
            model.lastActionOutput = "等待启动本机服务"
            model.printerDevices = [.fallback]
        case .starting:
            model.serviceState = .starting
            model.serviceSummary = "启动中 · 正在检查本机端口"
            model.ports = [
                PortStatus(id: 13528, port: 13528, label: "WS", isListening: true, listenerCount: 1),
                PortStatus(id: 13525, port: 13525, label: "HTTP", isListening: false, listenerCount: 0),
            ]
            model.activeBrowserConnections = 0
            model.recentTasks = [inProgressTask]
            model.printJobs = [pendingJob]
            model.redactedLogs = "[22:29:58] starting local print service\n[22:29:59] waiting for HTTP preview server"
            model.lastActionOutput = "服务启动中"
        case .error:
            model.serviceState = .error
            model.serviceSummary = "错误 · HTTP 端口未监听"
            model.ports = closedPorts
            model.activeBrowserConnections = 0
            model.recentTasks = failureTasks
            model.printJobs = failureJobs
            model.redactedLogs = errorLogs
            model.lastActionOutput = "启动失败：端口不可用"
            model.printerDevices = unavailablePrinters
        case .busyQueue:
            model.serviceState = .running
            model.serviceSummary = "运行中 · 正在处理多个打印任务"
            model.ports = listeningPorts
            model.activeBrowserConnections = 3
            model.recentTasks = recentTasks + failureTasks
            model.printJobs = printJobs + failureJobs + [pendingJob]
            model.redactedLogs = runningLogs
            model.lastActionOutput = "队列中还有 2 个任务"
        case .calibrated:
            model.serviceState = .running
            model.serviceSummary = "运行中 · 已应用打印机校准"
            model.ports = listeningPorts
            model.activeBrowserConnections = 1
            model.recentTasks = recentTasks
            model.printJobs = printJobs
            model.printerCalibrations = calibratedTable
            model.bakedCalibration = .identity
            model.redactedLogs = "[22:30:10] calibration updated for TAOBAO"
            model.lastActionOutput = "已按新设置更新预览"
        }

        return model
    }

    static let printers: [PrinterDevice] = [
        PrinterDevice(name: "TAOBAO", isDefault: true, isEnabled: true),
        PrinterDevice(name: "Office PDF", isDefault: false, isEnabled: true),
        PrinterDevice(name: "Offline Label Printer", isDefault: false, isEnabled: false),
    ]

    static let unavailablePrinters: [PrinterDevice] = [
        PrinterDevice(name: "TAOBAO", isDefault: true, isEnabled: false),
        PrinterDevice(name: "Office PDF", isDefault: false, isEnabled: false),
    ]

    static let listeningPorts: [PortStatus] = [
        PortStatus(id: 13528, port: 13528, label: "WS", isListening: true, listenerCount: 1),
        PortStatus(id: 13525, port: 13525, label: "HTTP", isListening: true, listenerCount: 1),
    ]

    static let closedPorts: [PortStatus] = [
        PortStatus(id: 13528, port: 13528, label: "WS", isListening: false, listenerCount: 0),
        PortStatus(id: 13525, port: 13525, label: "HTTP", isListening: false, listenerCount: 0),
    ]

    static let calibrations: [String: PrinterCalibration] = [
        "TAOBAO": .identity,
    ]

    static let calibratedTable: [String: PrinterCalibration] = [
        "TAOBAO": PrinterCalibration(
            offsetXMM: 2.5,
            offsetYMM: -1.0,
            rotationDegrees: 90,
            scaleRatio: 1.15,
            adaptivePaper: false
        ),
        "Office PDF": PrinterCalibration(
            offsetXMM: 0,
            offsetYMM: 0,
            rotationDegrees: 180,
            scaleRatio: 1,
            adaptivePaper: true
        ),
    ]

    /// 非 print 协议命令（握手 / 配置读写），供「协议」筛选项的命令行视图展示。
    static let protocolTasks: [RecentTask] = [
        RecentTask(
            id: "proto-get-printers",
            timestampText: "22:24:58",
            command: "getPrinters",
            requestID: "REQ-DEMO-PRN",
            documentCount: 0,
            mode: "default-preview",
            result: "",
            isInProgress: false
        ),
        RecentTask(
            id: "proto-agent-info",
            timestampText: "22:25:01",
            command: "getAgentInfo",
            requestID: "REQ-DEMO-AGENT",
            documentCount: 0,
            mode: "default-preview",
            result: "",
            isInProgress: false
        ),
        RecentTask(
            id: "proto-global-config",
            timestampText: "22:25:05",
            command: "getGlobalConfig",
            requestID: "REQ-DEMO-CFG",
            documentCount: 0,
            mode: "default-preview",
            result: "",
            isInProgress: true
        ),
    ]

    static let recentTasks: [RecentTask] = protocolTasks + [
        RecentTask(
            id: "preview-success",
            timestampText: "22:25:31",
            command: "print",
            requestID: "REQ-DEMO-0001",
            documentCount: 1,
            mode: "physical-dry-run",
            result: "physical-dry-run",
            isInProgress: false,
            documents: [
                QueueDocument(waybillCode: "78812340001122", receiverName: "演示收件人 甲", receiverPhone: "188****8801", province: "浙江省", city: "杭州市", district: "余杭区")
            ]
        ),
        RecentTask(
            id: "preview-submitted",
            timestampText: "22:26:02",
            command: "print",
            requestID: "REQ-DEMO-0002",
            documentCount: 2,
            mode: "physical-print",
            result: "physical-print",
            isInProgress: false,
            documents: [
                QueueDocument(waybillCode: "78812340002233", receiverName: "演示收件人 乙", receiverPhone: "188****8802", province: "江苏省", city: "南京市", district: "鼓楼区"),
                QueueDocument(waybillCode: "78812340002244", receiverName: "演示收件人 丙", receiverPhone: "188****8803", province: "广东省", city: "深圳市", district: "南山区"),
            ]
        ),
    ]

    static let inProgressTask = RecentTask(
        id: "preview-progress",
        timestampText: "22:29:59",
        command: "print",
        requestID: "REQ-DEMO-STARTING",
        documentCount: 1,
        mode: "default-preview",
        result: "",
        isInProgress: true
    )

    static let failureTasks: [RecentTask] = [
        RecentTask(
            id: "preview-missing-doc",
            timestampText: "22:27:14",
            command: "print",
            requestID: "REQ-DEMO-MISSING",
            documentCount: 0,
            mode: "failure-document-not-found",
            result: "document-not-found",
            isInProgress: false
        ),
        RecentTask(
            id: "preview-decrypt-failure",
            timestampText: "22:27:48",
            command: "print",
            requestID: "REQ-DEMO-DECRYPT",
            documentCount: 1,
            mode: "failure-decrypt",
            result: "decrypt-failure",
            isInProgress: false
        ),
    ]

    static let printJobs: [PrintJob] = [
        PrintJob(
            id: "job-dry-run",
            waybillCode: "79013939670143",
            printerName: "TAOBAO",
            pdfPath: "/Users/amo/cainiao-x-print/preview/DEMO_0001.pdf",
            status: .dryRun,
            errorMessage: nil,
            commandText: "lpr -P 'TAOBAO' -o media=100x180mm -o fit-to-page",
            documents: [
                QueueDocument(waybillCode: "79013939670143", receiverName: "演示收件人 丁", receiverPhone: "188****8804", province: "四川省", city: "成都市", district: "武侯区")
            ]
        ),
        PrintJob(
            id: "job-submitted",
            waybillCode: "79013939670144",
            printerName: "TAOBAO",
            pdfPath: "/Users/amo/cainiao-x-print/preview/DEMO_0002.pdf",
            status: .submitted,
            errorMessage: nil,
            commandText: "lpr -P 'TAOBAO' -o media=74x126mm"
        ),
        PrintJob(
            id: "job-duplicate",
            waybillCode: "79013939670145",
            printerName: "TAOBAO",
            pdfPath: "/Users/amo/cainiao-x-print/preview/DEMO_0003.pdf",
            status: .skippedDuplicate,
            errorMessage: "10 分钟内重复提交，已跳过。",
            commandText: nil
        ),
    ]

    static let pendingJob = PrintJob(
        id: "job-pending",
        waybillCode: "79013939670146",
        printerName: "TAOBAO",
        pdfPath: "",
        status: .pending,
        errorMessage: nil,
        commandText: nil
    )

    static let failureJobs: [PrintJob] = [
        PrintJob(
            id: "job-failed",
            waybillCode: "79013939670147",
            printerName: "Offline Label Printer",
            pdfPath: "/Users/amo/cainiao-x-print/preview/DEMO_FAILED.pdf",
            status: .failed,
            errorMessage: "打印机不可用，请检查连接。",
            commandText: "lpr -P 'Offline Label Printer' -o media=100x180mm"
        ),
    ]

    static let longDocument = WaybillDocument(
        waybillCode: "90000000000099",
        documentID: "DEMO-DOC-LONG",
        receiverName: "演示长姓名收件人",
        receiverPhone: "188****0099",
        receiverAddress: "示例省示例市示例区一条很长很长的演示街道 100 号 8 栋 18 层 1808 室，门口请勿放置在雨淋区域",
        senderName: "演示发货仓",
        senderPhone: "199****0099",
        senderAddress: "示例省样板市样板区测试路 200 号虚拟发货仓二号库西门",
        sortingCode: "LONG-A99",
        consolidationInfo: "长文本集包地",
        blockCode: "ROUTE-LONG-0099",
        packageIndexText: "第 2/4 个",
        itemInfo: "超长商品名称演示套装；多规格组合；附带赠品与售后卡；请轻拿轻放",
        itemTotalCount: "12 件",
        orderID: "DEMO-ORDER-20260626-LONG",
        buyerNick: "demo_long_buyer",
        buyerMemo: "买家备注较长：请工作日送达，电话无人接听时放在前台并短信通知。",
        sellerMemo: "卖家备注较长：此订单包含多个包裹，打印后请核对包裹序号和商品数量。",
        printedAt: Date(timeIntervalSinceReferenceDate: 804470400)
    )

    private static let runningLogs = """
    [22:25:31] websocket connected from browser
    [22:25:32] received print request REQ-DEMO-0001
    [22:25:32] generated preview DEMO_0001.pdf
    """

    private static let errorLogs = """
    [22:27:14] print failed: document not found
    [22:27:48] print failed: decrypt failure
    [22:28:01] local service error: HTTP port unavailable
    """
}
#endif
