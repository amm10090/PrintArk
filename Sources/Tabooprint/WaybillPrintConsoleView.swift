import SwiftUI

struct WaybillPrintConsoleView: View {
    @ObservedObject var model: AppModel
    @State private var sidebarSelection: PrintSidebarDestination? = .currentWaybill
    @State private var isServicePanelPresented = false
    @AppStorage(SettingsKeys.printerName) private var printerName = "TAOBAO"

    private var selectedPrinter: PrinterDevice {
        model.printerDevices.first(where: { $0.name == printerName }) ?? PrinterDevice(name: printerName, isDefault: false, isEnabled: true)
    }

    var body: some View {
        VStack(spacing: 0) {
            ConsoleTopBar(
                model: model,
                selectedPrinter: selectedPrinter,
                isServicePanelPresented: $isServicePanelPresented
            )

            Divider()

            NavigationSplitView {
                PrintSidebarView(selection: $sidebarSelection)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
            } content: {
                PrintWorkspaceContent(selection: sidebarSelection ?? .currentWaybill, model: model)
            } detail: {
                PrintPipelineInspector(model: model)
                    .navigationSplitViewColumnWidth(min: 360, ideal: 390, max: 440)
            }
        }
        .frame(minWidth: 1240, minHeight: 780)
    }
}

struct ConsoleTopBar: View {
    @ObservedObject var model: AppModel
    let selectedPrinter: PrinterDevice
    @Binding var isServicePanelPresented: Bool

    var body: some View {
        HStack(spacing: 12) {
            Label("面单打印", systemImage: "printer.fill")
                .font(.headline)

            Spacer()

            Button {
                isServicePanelPresented.toggle()
            } label: {
                PipelineStateBadge(state: model.serviceState)
            }
            .buttonStyle(.plain)
            .help("本机服务")
            .popover(isPresented: $isServicePanelPresented, arrowEdge: .bottom) {
                ServiceControlsPanel(model: model)
            }

            PrinterStatusBadge(printer: selectedPrinter)

            Button(action: model.restartService) {
                Label("重启服务", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .help("重启本机打印服务")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial)
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
        case .payloadDocuments: return "多面单文档"
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
                        .tag(item)
                        .help(item.title)
                }
            }

            Section("批量能力") {
                ForEach(PrintSidebarDestination.batchItems) { item in
                    SidebarRow(item: item)
                        .foregroundStyle(item.isImplemented ? .primary : .secondary)
                        .tag(item)
                        .help(item.isImplemented ? item.title : "尚未实现")
                }
            }

            Section("说明") {
                ForEach(PrintSidebarDestination.infoItems) { item in
                    SidebarRow(item: item)
                        .tag(item)
                        .help(item.title)
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
            LabelPreviewWorkspace(pdfURL: model.latestPreviewPDF, model: model)
        case .printQueue:
            SidebarPage(
                title: "打印队列",
                subtitle: model.printJobs.isEmpty ? "等待新的打印任务。" : "最近 \(model.printJobs.count) 个打印任务。",
                systemImage: "tray.full"
            ) {
                RecentJobsCard(jobs: model.printJobs)
            }
        case .recentTasks:
            SidebarPage(
                title: "最近任务",
                subtitle: "最后刷新：\(model.lastRefreshedText)",
                systemImage: "clock"
            ) {
                RecentTasksCard(tasks: model.recentTasks)
            }
        case .payloadDocuments:
            SidebarPage(
                title: "多面单文档",
                subtitle: "当前支持一次提交里的多张面单。",
                systemImage: "doc.on.doc"
            ) {
                PayloadDocumentsCard(tasks: model.recentTasks)
            }
        case .currentVersion:
            SidebarPage(
                title: "当前版本",
                subtitle: "Tabooprint 本地运行信息。",
                systemImage: "info.circle"
            ) {
                VersionSummaryCard(model: model)
            }
        case .csvImport, .fieldMapping, .retryFailed:
            SidebarPage(
                title: selection.title,
                subtitle: "尚未接入当前版本。",
                systemImage: selection.systemImage
            ) {
                SettingsCard(title: "未实现", subtitle: "这个入口已预留，后续实现后再启用。") {
                    EmptyView()
                }
            }
        }
    }
}

struct SidebarPage<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let content: Content

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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

                content
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(title)
    }
}

struct RecentTasksCard: View {
    let tasks: [RecentTask]

    var body: some View {
        SettingsCard(title: "最近任务", subtitle: "浏览器请求和处理结果。") {
            if tasks.isEmpty {
                Label("暂无任务", systemImage: "clock")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(tasks) { task in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(task.command)
                                    .font(.subheadline.weight(.semibold))

                                Text(task.requestID)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            StatusText(text: task.resultDisplay, color: task.isInProgress ? .orange : .green)
                        }
                    }
                }
            }
        }
    }
}

struct PayloadDocumentsCard: View {
    let tasks: [RecentTask]

    var body: some View {
        SettingsCard(title: "支持范围", subtitle: "当前可处理的面单能力。") {
            VStack(alignment: .leading, spacing: 9) {
                DedupKeyRow("一次提交里的多张面单")
                DedupKeyRow("多张面单逐个生成预览")
                DedupKeyRow("最近文档数：\(tasks.first?.documentCountText ?? "0")")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct VersionSummaryCard: View {
    @ObservedObject var model: AppModel
    @AppStorage(SettingsKeys.debugPreview) private var debugPreview = false

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "运行状态", subtitle: "当前本机服务。") {
                VStack(alignment: .leading, spacing: 9) {
                    DedupKeyRow("服务：\(model.serviceState.title)")
                    DedupKeyRow("连接：\(model.activeBrowserConnections)")
                    DedupKeyRow("最新预览：\(model.latestPreviewPDF?.lastPathComponent ?? "-")")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            SettingsCard(title: "调试选项", subtitle: "仅供开发调试，正常使用请保持关闭。") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("调试打印（不送打印机，仅生成 PDF 预览）", isOn: $debugPreview)
                        .onChange(of: debugPreview) { _ in model.restartService() }

                    Text(debugPreview
                         ? "已开启：千牛打印请求只生成 PDF 预览，不会真实送到打印机。适合没有物理打印机的开发环境。"
                         : "已关闭：千牛打印请求会真实送到打印机（默认行为）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()

                    HStack(spacing: 8) {
                        Button(action: model.refresh) {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }

                        Button(action: model.stopService) {
                            Label("停止", systemImage: "stop.fill")
                        }
                        .disabled(model.serviceState == .stopped || model.serviceState == .stopping)

                        Button(action: model.openLatestPreview) {
                            Label("打开预览", systemImage: "doc.richtext")
                        }
                        .disabled(model.latestPreviewPDF == nil)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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

struct ServiceControlsPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("本机服务")
                        .font(.headline)

                    Text(model.serviceSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                PipelineStateBadge(state: model.serviceState)
            }

            HStack(spacing: 8) {
                ForEach(model.ports) { port in
                    StatusText(
                        text: "\(port.label) \(port.stateText)",
                        color: port.isListening ? .green : .secondary
                    )
                }

                StatusText(text: "\(model.activeBrowserConnections) 个连接", color: .secondary)
            }

            Divider()

            HStack(spacing: 8) {
                Button(action: model.restartService) {
                    Label(model.serviceState == .running ? "重启服务" : "启动服务", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)

                Button(action: model.stopService) {
                    Label("停止", systemImage: "stop.fill")
                }
                .disabled(model.serviceState == .stopped || model.serviceState == .stopping)

                Button(action: model.refresh) {
                    Label("刷新", systemImage: "arrow.clockwise")
                }

                Button(action: model.openLatestPreview) {
                    Label("预览", systemImage: "doc.richtext")
                }
                .disabled(model.latestPreviewPDF == nil)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

#if DEBUG
@MainActor
enum PreviewSamples {
    static var consoleModel: AppModel {
        let model = AppModel()
        model.serviceState = .running
        model.serviceSummary = "运行中 • WS 监听 · HTTP 监听 • 1 个浏览器连接"
        model.ports = [
            PortStatus(id: 13528, port: 13528, label: "WS", isListening: true, listenerCount: 1),
            PortStatus(id: 13525, port: 13525, label: "HTTP", isListening: true, listenerCount: 1),
        ]
        model.activeBrowserConnections = 1
        model.printerDevices = [
            PrinterDevice(name: "TAOBAO 闲置", isDefault: true, isEnabled: true),
            PrinterDevice(name: "Office PDF", isDefault: false, isEnabled: false),
        ]
        model.recentTasks = [
            RecentTask(
                id: "preview-demo",
                timestampText: "09:34:33",
                command: "print",
                requestID: "REQ-DEMO-0001",
                documentCount: 1,
                mode: "physical-dry-run",
                result: "physical-dry-run",
                isInProgress: false
            ),
        ]
        model.printJobs = [
            PrintJob(
                id: "job-demo",
                waybillCode: "79013939670143",
                printerName: "TAOBAO 闲置",
                pdfPath: "/Users/amo/cainiao-x-print/preview/GA_REPLAY_1782351273403.pdf",
                status: .dryRun,
                errorMessage: nil,
                commandText: "lpr -P 'TAOBAO 闲置' -o media=100x180mm -o fit-to-page"
            ),
        ]
        model.lastRefreshedText = "2026-06-25 09:34:33"
        return model
    }
}

@MainActor
struct WaybillPrintConsoleView_Previews: PreviewProvider {
    static var previews: some View {
        WaybillPrintConsoleView(model: PreviewSamples.consoleModel)
            .frame(width: 1240, height: 780)
    }
}
#endif
