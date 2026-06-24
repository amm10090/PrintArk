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
            PrintPipelineInspector(model: model)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SidebarSection(title: "打印") {
                    ForEach(PrintSidebarDestination.printItems) { item in
                        SidebarActionRow(item: item, selection: $selection)
                    }
                }

                SidebarSection(title: "批量能力") {
                    ForEach(PrintSidebarDestination.batchItems) { item in
                        SidebarActionRow(item: item, selection: $selection, isMuted: !item.isImplemented)
                    }
                }

                SidebarSection(title: "说明") {
                    ForEach(PrintSidebarDestination.infoItems) { item in
                        SidebarActionRow(item: item, selection: $selection)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 18)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .navigationTitle("工作台")
    }
}

struct SidebarSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

            content
        }
    }
}

struct SidebarActionRow: View {
    let item: PrintSidebarDestination
    @Binding var selection: PrintSidebarDestination?
    var isMuted = false

    private var isSelected: Bool {
        selection == item
    }

    var body: some View {
        Button {
            selection = item
        } label: {
            SidebarRow(item: item)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isMuted && !isSelected ? .secondary : .primary)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help(isMuted ? "尚未实现" : item.title)
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
            SidebarPage(
                title: "打印队列",
                subtitle: model.printJobs.isEmpty ? "等待新的打印 payload。" : "最近 \(model.printJobs.count) 个打印任务。",
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
                title: "Payload 多文档",
                subtitle: "当前支持 payload 内多个 documents。",
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
        SettingsCard(title: "支持范围", subtitle: "当前 payload 能力。") {
            VStack(alignment: .leading, spacing: 9) {
                DedupKeyRow("payload 内多个 documents")
                DedupKeyRow("多文档逐个渲染 PDF")
                DedupKeyRow("最近文档数：\(tasks.first?.documentCountText ?? "0")")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct VersionSummaryCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsCard(title: "运行状态", subtitle: "当前本机服务。") {
            VStack(alignment: .leading, spacing: 9) {
                DedupKeyRow("服务：\(model.serviceState.title)")
                DedupKeyRow("连接：\(model.activeBrowserConnections)")
                DedupKeyRow("最新预览：\(model.latestPreviewPDF?.lastPathComponent ?? "-")")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
