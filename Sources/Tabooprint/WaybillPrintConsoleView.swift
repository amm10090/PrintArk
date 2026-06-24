import SwiftUI

struct WaybillPrintConsoleView: View {
    @ObservedObject var model: AppModel
    @State private var sidebarSelection: PrintSidebarDestination? = .currentWaybill
    @AppStorage(SettingsKeys.printerName) private var printerName = "TAOBAO"
    @AppStorage(SettingsKeys.printDryRun) private var printDryRun = true

    private var selectedPrinter: PrinterDevice {
        model.printerDevices.first(where: { $0.name == printerName }) ?? PrinterDevice(name: printerName, isDefault: false, isEnabled: true)
    }

    var body: some View {
        NavigationSplitView {
            PrintSidebarView(selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } content: {
            PrintWorkspaceContent(selection: sidebarSelection ?? .currentWaybill, model: model)
        } detail: {
            PrintWorkspaceDetail(selection: sidebarSelection ?? .currentWaybill, model: model)
                .navigationSplitViewColumnWidth(min: 360, ideal: 390, max: 440)
        }
        .frame(minWidth: 1240, minHeight: 780)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Label("面单打印", systemImage: "printer.fill")
                    .font(.headline)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                PipelineStateBadge(state: model.serviceState)

                PrinterStatusBadge(printer: selectedPrinter)

                Button(action: model.refresh) {
                    Label("刷新打印机", systemImage: "arrow.clockwise")
                }

                Button(action: model.openLatestPreview) {
                    Label("打开最新预览", systemImage: "doc.richtext")
                }
                .disabled(model.latestPreviewPDF == nil)

                Button(action: model.stopService) {
                    Label("停止", systemImage: "stop.fill")
                }
                .disabled(model.serviceState == .stopped || model.serviceState == .stopping)

                Button(action: model.restartService) {
                    Label(printDryRun ? "启动模拟打印" : "启动真实打印", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

enum PrintSidebarDestination: String, CaseIterable, Identifiable, Hashable {
    case currentWaybill
    case printQueue
    case recentTasks
    case payloadDocuments
    case currentVersion
    case csvImport
    case fieldMapping
    case retryFailed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentWaybill: return "当前面单"
        case .printQueue: return "打印队列"
        case .recentTasks: return "最近任务"
        case .payloadDocuments: return "Payload 多文档"
        case .currentVersion: return "当前版本"
        case .csvImport: return "CSV / Excel 导入"
        case .fieldMapping: return "字段映射"
        case .retryFailed: return "失败重试"
        }
    }

    var systemImage: String {
        switch self {
        case .currentWaybill: return "doc.text"
        case .printQueue: return "tray.full"
        case .recentTasks: return "clock"
        case .payloadDocuments: return "doc.on.doc"
        case .currentVersion: return "info.circle"
        case .csvImport: return "tablecells"
        case .fieldMapping: return "arrow.left.arrow.right"
        case .retryFailed: return "arrow.triangle.2.circlepath"
        }
    }

    var isImplemented: Bool {
        switch self {
        case .currentWaybill, .printQueue, .recentTasks, .payloadDocuments, .currentVersion:
            return true
        case .csvImport, .fieldMapping, .retryFailed:
            return false
        }
    }

    static let printItems: [Self] = [.currentWaybill, .printQueue, .recentTasks]
    static let batchItems: [Self] = [.payloadDocuments, .csvImport, .fieldMapping, .retryFailed]
    static let infoItems: [Self] = [.currentVersion]
}

struct PrintSidebarView: View {
    @Binding var selection: PrintSidebarDestination?

    var body: some View {
        List(selection: $selection) {
            Section("打印") {
                ForEach(PrintSidebarDestination.printItems) { item in
                    SidebarRow(item: item)
                        .tag(item as PrintSidebarDestination?)
                }
            }

            Section("批量能力") {
                ForEach(PrintSidebarDestination.batchItems) { item in
                    if item.isImplemented {
                        SidebarRow(item: item)
                            .tag(item as PrintSidebarDestination?)
                    } else {
                        SidebarRow(item: item)
                            .foregroundStyle(.secondary)
                            .help("尚未实现")
                    }
                }
            }

            Section("说明") {
                ForEach(PrintSidebarDestination.infoItems) { item in
                    SidebarRow(item: item)
                        .tag(item as PrintSidebarDestination?)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("工作台")
    }
}

struct SidebarRow: View {
    let item: PrintSidebarDestination

    var body: some View {
        Label(item.title, systemImage: item.systemImage)
    }
}

struct PrintWorkspaceContent: View {
    let selection: PrintSidebarDestination
    @ObservedObject var model: AppModel

    var body: some View {
        switch selection {
        case .currentWaybill:
            LabelPreviewWorkspace(document: .sample)
        case .printQueue:
            PrintQueueWorkspace(jobs: model.printJobs)
        case .recentTasks:
            RecentTasksWorkspace(model: model)
        case .payloadDocuments:
            PayloadDocumentsWorkspace(tasks: model.recentTasks)
        case .currentVersion:
            VersionWorkspace(model: model)
        case .csvImport, .fieldMapping, .retryFailed:
            PlaceholderWorkspace(title: selection.title, systemImage: selection.systemImage)
        }
    }
}

struct PrintWorkspaceDetail: View {
    let selection: PrintSidebarDestination
    @ObservedObject var model: AppModel

    var body: some View {
        switch selection {
        case .currentVersion:
            VersionDetail(model: model)
        case .currentWaybill, .printQueue, .recentTasks, .payloadDocuments, .csvImport, .fieldMapping, .retryFailed:
            PrintPipelineInspector(model: model)
        }
    }
}

struct PrintQueueWorkspace: View {
    let jobs: [PrintJob]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WorkspaceHeader(
                    title: "打印队列",
                    subtitle: jobs.isEmpty ? "等待新的打印 payload。" : "最近 \(jobs.count) 个打印任务。",
                    systemImage: "tray.full"
                )

                if jobs.isEmpty {
                    PlaceholderPanel(
                        title: "暂无任务",
                        subtitle: "千牛提交面单后，这里会显示 PDF、打印机和 lpr 状态。",
                        systemImage: "tray"
                    )
                } else {
                    VStack(spacing: 10) {
                        ForEach(jobs) { job in
                            PrintQueueRow(job: job)
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("打印队列")
    }
}

struct PrintQueueRow: View {
    let job: PrintJob

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Label(job.waybillCode, systemImage: job.status.systemImage)
                    .font(.headline)
                    .foregroundStyle(job.status.color)

                Spacer()

                StatusText(text: job.status.rawValue, color: job.status.color)
            }

            HStack(spacing: 16) {
                QueueMetaItem(title: "打印机", value: job.printerName)
                QueueMetaItem(title: "PDF", value: job.pdfPath.isEmpty ? "-" : job.pdfPath)
            }

            if let commandText = job.commandText, !commandText.isEmpty {
                Text(commandText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let errorMessage = job.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(job.status == .failed ? .red : .secondary)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        }
    }
}

struct QueueMetaItem: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RecentTasksWorkspace: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WorkspaceHeader(
                    title: "最近任务",
                    subtitle: "最后刷新：\(model.lastRefreshedText)",
                    systemImage: "clock"
                )

                if model.recentTasks.isEmpty {
                    PlaceholderPanel(
                        title: "暂无任务",
                        subtitle: "收到浏览器请求后会显示 requestID、命令、文档数和结果。",
                        systemImage: "clock"
                    )
                } else {
                    VStack(spacing: 10) {
                        ForEach(model.recentTasks) { task in
                            RecentTaskRow(task: task)
                        }
                    }
                }

                LogPanel(logs: model.redactedLogs, clear: model.clearLogViewer)
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("最近任务")
    }
}

struct RecentTaskRow: View {
    let task: RecentTask

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.command)
                        .font(.headline)

                    Text(task.requestID)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                StatusText(text: task.resultDisplay, color: task.isInProgress ? .orange : .green)
            }

            HStack(spacing: 10) {
                StatusText(text: task.modeDisplay, color: .secondary)
                StatusText(text: "\(task.documentCountText) 个文档", color: .secondary)
                Text(task.timestampText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        }
    }
}

struct LogPanel: View {
    let logs: String
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("日志")
                    .font(.headline)

                Spacer()

                Button(action: clear) {
                    Label("清空", systemImage: "trash")
                }
                .disabled(logs.isEmpty)
            }

            Text(logs.isEmpty ? "暂无日志" : logs)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(logs.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
                .padding(12)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        }
    }
}

struct PayloadDocumentsWorkspace: View {
    let tasks: [RecentTask]

    private var latestDocumentCount: Int {
        tasks.first?.documentCount ?? 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WorkspaceHeader(
                    title: "Payload 多文档",
                    subtitle: latestDocumentCount > 0 ? "最近 payload 包含 \(latestDocumentCount) 个文档。" : "等待 payload。",
                    systemImage: "doc.on.doc"
                )

                VStack(alignment: .leading, spacing: 12) {
                    CapabilityRow(title: "解析 documents", value: "已接入")
                    CapabilityRow(title: "批量渲染 PDF", value: "已接入")
                    CapabilityRow(title: "CSV / Excel 导入", value: "未接入")
                    CapabilityRow(title: "失败重试", value: "未接入")
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Payload 多文档")
    }
}

struct CapabilityRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))

            Spacer()

            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(value == "已接入" ? .green : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background((value == "已接入" ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
        }
    }
}

struct VersionWorkspace: View {
    @ObservedObject var model: AppModel

    private var versionText: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "本地开发版"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WorkspaceHeader(
                    title: "Tabooprint",
                    subtitle: versionText,
                    systemImage: "printer.fill"
                )

                VStack(alignment: .leading, spacing: 12) {
                    VersionRow(title: "服务状态", value: model.serviceState.title)
                    VersionRow(title: "服务摘要", value: model.serviceSummary)
                    VersionRow(title: "浏览器连接", value: "\(model.activeBrowserConnections)")
                    VersionRow(title: "最新预览", value: model.latestPreviewPDF?.path ?? "-")
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("当前版本")
    }
}

struct VersionRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(.subheadline, design: title == "最新预览" ? .monospaced : .default).weight(.semibold))
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct VersionDetail: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsCard(title: "运行状态", subtitle: "当前本机服务。") {
                    VStack(alignment: .leading, spacing: 10) {
                        DedupKeyRow("WebSocket：\(portText(for: 13528))")
                        DedupKeyRow("HTTP 预览：\(portText(for: 13525))")
                        DedupKeyRow("打印机：\(model.printerDevices.map(\.displayName).joined(separator: ", "))")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("版本信息")
    }

    private func portText(for port: Int) -> String {
        guard let status = model.ports.first(where: { $0.port == port }) else {
            return "未检测"
        }
        return "\(port) \(status.stateText)"
    }
}

struct PlaceholderWorkspace: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack {
            PlaceholderPanel(title: title, subtitle: "尚未接入当前版本。", systemImage: systemImage)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(title)
    }
}

struct PlaceholderPanel: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.headline)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        }
    }
}

struct WorkspaceHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}

struct PipelineStateBadge: View {
    let state: ServiceState

    private var color: Color {
        switch state {
        case .running:
            return .green
        case .starting, .stopping:
            return .orange
        case .error:
            return .red
        case .stopped:
            return .secondary
        }
    }

    var body: some View {
        Label(state.title, systemImage: state.symbolName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(color.opacity(0.12), in: Capsule())
    }
}
