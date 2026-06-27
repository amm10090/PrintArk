import SwiftUI

struct WaybillPrintConsoleView: View {
    @ObservedObject var model: AppModel
    @State private var sidebarSelection: PrintSidebarDestination? = .currentWaybill

    var body: some View {
        NavigationSplitView {
            PrintSidebarView(selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            PrintWorkspaceContent(selection: sidebarSelection ?? .currentWaybill, model: model)
        }
        .frame(minWidth: 1320, minHeight: 860)
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
            HSplitView {
                LabelPreviewWorkspace(pdfURL: model.latestPreviewPDF, model: model)
                    .frame(minWidth: 620)

                PrintPipelineInspector(model: model)
                    .frame(minWidth: 360, idealWidth: 390, maxWidth: 440)
            }
        case .printQueue:
            PrintQueueWorkspace(model: model)
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

private enum QueueDesign {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let white = Color(nsColor: .controlBackgroundColor)
    static let topBarStart = Color(nsColor: .windowBackgroundColor)
    static let topBarEnd = Color(nsColor: .underPageBackgroundColor)
    static let ink = Color.primary
    static let ink2 = Color.secondary
    static let darkSurface = Color(red: 0.114, green: 0.114, blue: 0.122)
    static let darkSurfaceText = Color(red: 0.824, green: 0.824, blue: 0.843)
    static let neutral = Color.secondary
    static let borderSoft = Color(nsColor: .separatorColor)
    static let borderMid = Color.secondary.opacity(0.68)
    static let accent = Color.accentColor
    static let accent2 = Color.accentColor
    static let danger = Color.red
    static let dangerSoft = Color.red.opacity(0.14)
    static let ok = Color.green
    static let okSoft = Color.green.opacity(0.14)
    static let control = Color(nsColor: .quaternaryLabelColor).opacity(0.18)
    static let controlPressed = Color(nsColor: .quaternaryLabelColor).opacity(0.28)
    static let previewTileA = Color(nsColor: .windowBackgroundColor)
    static let previewTileB = Color(nsColor: .controlBackgroundColor)
    static let scrim = Color.black.opacity(0.42)

    /// Drawer / scrim present + dismiss timing. A spring gives the panel a soft
    /// settle at the end instead of a hard stop, which reads as "丝滑".
    static let drawerAnimation = Animation.spring(response: 0.38, dampingFraction: 0.86, blendDuration: 0)
}

enum PrintQueueFilter: String, CaseIterable, Identifiable {
    case all
    case printing
    case queued
    case failed
    case done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .printing: return "打印中"
        case .queued: return "排队中"
        case .failed: return "失败"
        case .done: return "完成"
        }
    }
}

enum QueueJobKind: Equatable {
    case preview
    case dryRun
    case physical
    case duplicate
    case failure
    case pending

    var title: String {
        switch self {
        case .preview: return "预览"
        case .dryRun: return "模拟"
        case .physical: return "真实"
        case .duplicate: return "重复"
        case .failure: return "失败"
        case .pending: return "排队"
        }
    }

    var systemImage: String {
        switch self {
        case .preview: return "eye"
        case .dryRun: return "doc.text.magnifyingglass"
        case .physical: return "printer.fill"
        case .duplicate: return "arrow.triangle.2.circlepath"
        case .failure: return "exclamationmark.triangle.fill"
        case .pending: return "clock"
        }
    }

    var color: Color {
        switch self {
        case .preview: return QueueDesign.accent
        case .dryRun: return .blue
        case .physical: return QueueDesign.ok
        case .duplicate: return QueueDesign.neutral
        case .failure: return QueueDesign.danger
        case .pending: return .orange
        }
    }
}

struct QueueJob: Identifiable, Equatable {
    let id: String
    let waybillCode: String
    let receiverName: String
    let receiverPhone: String
    let receiverAddress: String
    let copies: Int
    let status: QueueJobStatus
    let progress: Double
    let createdAtText: String
    let printerName: String
    let pdfPath: String
    let errorMessage: String?
    let commandText: String?
    let kind: QueueJobKind

    var subtitle: String {
        if status == .failed {
            return "\(receiverName) · 查看错误详情"
        }
        return receiverName
    }

    var metadataText: String {
        "\(receiverName) · \(copies) 份 · \(kind.title) · \(status.title)"
    }
}

enum QueueJobStatus: String, Equatable {
    case queued
    case printing
    case done
    case failed

    var title: String {
        switch self {
        case .queued: return "排队中"
        case .printing: return "打印中"
        case .done: return "已完成"
        case .failed: return "失败"
        }
    }

    var filter: PrintQueueFilter {
        switch self {
        case .queued: return .queued
        case .printing: return .printing
        case .done: return .done
        case .failed: return .failed
        }
    }

    var foreground: Color {
        switch self {
        case .queued: return QueueDesign.ink2
        case .printing: return QueueDesign.accent2
        case .done: return QueueDesign.ok
        case .failed: return QueueDesign.danger
        }
    }

    var background: Color {
        switch self {
        case .queued: return QueueDesign.control
        case .printing: return QueueDesign.accent.opacity(0.10)
        case .done: return QueueDesign.okSoft
        case .failed: return QueueDesign.dangerSoft
        }
    }

    var dot: Color {
        switch self {
        case .queued: return QueueDesign.borderMid
        case .printing: return QueueDesign.accent
        case .done: return QueueDesign.ok
        case .failed: return QueueDesign.danger
        }
    }
}

extension PrintJobStatus {
    var queueStatus: QueueJobStatus {
        switch self {
        case .pending:
            return .queued
        case .dryRun, .submitted:
            return .printing
        case .skippedDuplicate:
            return .done
        case .failed:
            return .failed
        }
    }
}

struct PrintQueueWorkspace: View {
    @ObservedObject var model: AppModel
    @State private var filter: PrintQueueFilter = .all
    @State private var searchText = ""
    @State private var selectedJobID: QueueJob.ID?
    @State private var selectedIDs: Set<QueueJob.ID> = []
    @State private var previewJob: QueueJob?
    @State private var errorJob: QueueJob?

    private var jobs: [QueueJob] {
        model.queueJobs
    }

    private var jobIDs: [QueueJob.ID] {
        jobs.map(\.id)
    }

    private var filteredJobs: [QueueJob] {
        jobs.filter { job in
            let matchesFilter = filter == .all || job.status.filter == filter
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matchesSearch = query.isEmpty
                || job.waybillCode.lowercased().contains(query)
                || job.receiverName.lowercased().contains(query)
            return matchesFilter && matchesSearch
        }
    }

    private var selectedJob: QueueJob? {
        if let selectedJobID, let found = jobs.first(where: { $0.id == selectedJobID }) {
            return found
        }
        return filteredJobs.first
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(spacing: 0) {
                PrintQueueToolbar(
                    filter: $filter,
                    searchText: $searchText,
                    counts: counts,
                    allSelected: allFilteredSelected,
                    toggleAll: toggleAllFiltered
                )

                QueueListPanel(
                    jobs: filteredJobs,
                    selectedJobID: selectedJob?.id,
                    selectedIDs: selectedIDs,
                    selectJob: { openPreview($0) },
                    toggleSelection: toggleSelection,
                    showError: { showError($0) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(QueueDesign.white)
            .onAppear {
                if selectedJobID == nil {
                    selectedJobID = filteredJobs.first?.id
                }
            }
            .onChange(of: jobIDs) { _ in
                pruneSelection()
            }
            .onChange(of: filter) { _ in
                keepSelectionVisible()
            }
            .onChange(of: searchText) { _ in
                keepSelectionVisible()
            }

            if !selectedIDs.isEmpty {
                BulkSelectionBar(count: selectedIDs.count) {
                    selectedIDs.removeAll()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if let previewJob {
                QueueDesign.scrim
                    .ignoresSafeArea()
                    .onTapGesture { self.previewJob = nil }

                QueuePreviewDrawer(
                    job: previewJob,
                    pdfURL: previewURL(for: previewJob),
                    model: model
                ) {
                    self.previewJob = nil
                }
                .frame(width: 640)
                .transition(.move(edge: .trailing))
            }

            if let errorJob {
                QueueDesign.scrim
                    .ignoresSafeArea()
                    .onTapGesture { self.errorJob = nil }

                QueueErrorDrawer(job: errorJob) {
                    self.errorJob = nil
                }
                .frame(width: 420)
                .transition(.move(edge: .trailing))
            }
        }
        .navigationTitle("打印队列")
    }

    private var counts: [PrintQueueFilter: Int] {
        var result: [PrintQueueFilter: Int] = [.all: jobs.count, .printing: 0, .queued: 0, .failed: 0, .done: 0]
        for job in jobs {
            result[job.status.filter, default: 0] += 1
        }
        return result
    }

    private var allFilteredSelected: Bool {
        !filteredJobs.isEmpty && filteredJobs.allSatisfy { selectedIDs.contains($0.id) }
    }

    private func toggleSelection(_ job: QueueJob) {
        if selectedIDs.contains(job.id) {
            selectedIDs.remove(job.id)
        } else {
            selectedIDs.insert(job.id)
        }
    }

    private func openPreview(_ job: QueueJob) {
        selectedJobID = job.id
        previewJob = job
        errorJob = nil
    }

    private func showError(_ job: QueueJob) {
        selectedJobID = job.id
        previewJob = nil
        errorJob = job
    }

    private func previewURL(for job: QueueJob) -> URL? {
        if !job.pdfPath.isEmpty, FileManager.default.fileExists(atPath: job.pdfPath) {
            return URL(fileURLWithPath: job.pdfPath)
        }
        return model.latestPreviewPDF
    }

    private func toggleAllFiltered() {
        if allFilteredSelected {
            selectedIDs.subtract(filteredJobs.map(\.id))
        } else {
            selectedIDs.formUnion(filteredJobs.map(\.id))
        }
    }

    private func pruneSelection() {
        let ids = Set(jobs.map(\.id))
        selectedIDs = selectedIDs.intersection(ids)
        if let selectedJobID, !ids.contains(selectedJobID) {
            self.selectedJobID = filteredJobs.first?.id
        }
        if let previewJob, !ids.contains(previewJob.id) {
            self.previewJob = nil
        }
        if let errorJob, !ids.contains(errorJob.id) {
            self.errorJob = nil
        }
    }

    private func keepSelectionVisible() {
        guard !filteredJobs.isEmpty else {
            selectedJobID = nil
            return
        }
        if let selectedJobID, filteredJobs.contains(where: { $0.id == selectedJobID }) {
            return
        }
        selectedJobID = filteredJobs.first?.id
    }
}

extension QueueJob {
    static func merged(printJobs: [PrintJob], recentTasks: [RecentTask]) -> [QueueJob] {
        let requestIDsWithPrintJobs = Set(printJobs.map(\.id))
        let liveJobs = printJobs.enumerated().map { index, job in
            QueueJob.from(printJob: job, index: index)
        }
        let previewJobs = recentTasks
            .filter { task in
                !requestIDsWithPrintJobs.contains(task.requestID) && task.shouldAppearInQueue
            }
            .map { task in
                QueueJob.from(recentTask: task)
            }
        return liveJobs + previewJobs
    }

    static func from(printJob: PrintJob, index: Int) -> QueueJob {
        let useDesignSample = printJob.usesDesignSampleRecipient
        let sample = useDesignSample
            ? QueueJob.sampleDetails[index % QueueJob.sampleDetails.count]
            : QueueJob.genericDetails
        let copies = useDesignSample ? max(1, (index % 4) + 1) : 1
        let status = printJob.status.queueStatus
        let progress: Double
        switch status {
        case .printing:
            progress = printJob.status == .submitted ? 0.82 : 0.44
        case .done:
            progress = 1
        case .queued, .failed:
            progress = 0
        }
        return QueueJob(
            id: printJob.id,
            waybillCode: printJob.waybillCode,
            receiverName: sample.name,
            receiverPhone: sample.phone,
            receiverAddress: sample.address,
            copies: copies,
            status: status,
            progress: progress,
            createdAtText: sample.time,
            printerName: printJob.printerName,
            pdfPath: printJob.pdfPath,
            errorMessage: printJob.errorMessage,
            commandText: printJob.commandText,
            kind: printJob.queueKind
        )
    }

    static func from(recentTask: RecentTask) -> QueueJob {
        let sample = QueueJob.genericDetails
        return QueueJob(
            id: recentTask.requestID,
            waybillCode: recentTask.requestID,
            receiverName: sample.name,
            receiverPhone: sample.phone,
            receiverAddress: sample.address,
            copies: max(1, recentTask.documentCount),
            status: recentTask.queueStatus,
            progress: recentTask.isInProgress ? 0.36 : 1,
            createdAtText: recentTask.timestampText,
            printerName: recentTask.queueSourceText,
            pdfPath: "",
            errorMessage: recentTask.queueErrorMessage,
            commandText: "requestID=\(recentTask.requestID) · \(recentTask.documentCountText) 个文档",
            kind: recentTask.queueKind
        )
    }

    fileprivate static let sampleDetails: [(name: String, phone: String, address: String, time: String)] = [
        ("演示收件人 01", "188****0001", "示例省示例市示例区演示路 1 号", "14:32"),
        ("演示收件人 02", "188****0002", "示例省示例市示例区演示路 2 号", "14:28"),
        ("演示收件人 03", "188****0003", "示例省示例市示例区演示路 3 号", "14:21"),
        ("演示收件人 04", "188****0004", "示例省示例市示例区演示路 4 号", "14:18"),
        ("演示收件人 05", "188****0005", "示例省示例市示例区演示路 5 号", "14:15"),
        ("演示收件人 06", "188****0006", "示例省示例市示例区演示路 6 号", "14:09"),
        ("演示收件人 07", "188****0007", "示例省示例市示例区演示路 7 号", "14:05"),
        ("演示收件人 08", "188****0008", "示例省示例市示例区演示路 8 号", "14:01"),
        ("演示收件人 09", "188****0009", "示例省示例市示例区演示路 9 号", "13:58"),
        ("演示收件人 10", "188****0010", "示例省示例市示例区演示路 10 号", "13:52"),
        ("演示收件人 11", "188****0011", "示例省示例市示例区演示路 11 号", "13:47"),
        ("演示收件人 12", "188****0012", "示例省示例市示例区演示路 12 号", "13:41"),
    ]

    private static let genericDetails: (name: String, phone: String, address: String, time: String) = (
        "收件人已脱敏",
        "—",
        "真实收件地址请以 PDF 预览为准",
        "—"
    )
}

private extension PrintJob {
    var usesDesignSampleRecipient: Bool {
        id.hasPrefix("job-")
    }

    var queueKind: QueueJobKind {
        switch status {
        case .pending:
            return .pending
        case .dryRun:
            return .dryRun
        case .submitted:
            return .physical
        case .skippedDuplicate:
            return .duplicate
        case .failed:
            return .failure
        }
    }
}

private extension RecentTask {
    var shouldAppearInQueue: Bool {
        command == "print" && (isInProgress || result.isEmpty || result == "preview" || result.contains("failure") || result.contains("failed") || result == "document-not-found")
    }

    var queueKind: QueueJobKind {
        if isInProgress { return .pending }
        switch result {
        case "preview":
            return .preview
        case "document-not-found", "decrypt-failure", "physical-print-failed":
            return .failure
        case "physical-dry-run":
            return .dryRun
        case "physical-print":
            return .physical
        case "physical-duplicate-suppressed":
            return .duplicate
        default:
            return mode == "default-preview" ? .preview : .pending
        }
    }

    var queueStatus: QueueJobStatus {
        if isInProgress { return .printing }
        switch result {
        case "document-not-found", "decrypt-failure", "physical-print-failed":
            return .failed
        case "physical-dry-run", "physical-print":
            return .printing
        case "physical-duplicate-suppressed", "preview":
            return .done
        default:
            return .queued
        }
    }

    var queueErrorMessage: String? {
        switch result {
        case "document-not-found":
            return "文档缺失，未生成预览。"
        case "decrypt-failure":
            return "解密失败，未完成预览。"
        case "physical-print-failed":
            return "打印失败。"
        case "physical-duplicate-suppressed":
            return "10 分钟窗口内重复提交，已跳过。"
        default:
            return nil
        }
    }

    var queueSourceText: String {
        if isInProgress {
            return "预览进行中 · \(modeDisplay)"
        }
        switch result {
        case "preview":
            return "预览完成 · \(modeDisplay)"
        case "document-not-found":
            return "预览失败 · 文档缺失"
        case "decrypt-failure":
            return "预览失败 · 解密失败"
        case "physical-print-failed":
            return "真实打印失败 · \(modeDisplay)"
        case "physical-dry-run":
            return "模拟打印 · \(modeDisplay)"
        case "physical-print":
            return "真实打印 · \(modeDisplay)"
        case "physical-duplicate-suppressed":
            return "重复跳过 · \(modeDisplay)"
        default:
            return modeDisplay
        }
    }
}

extension AppModel {
    var queueJobs: [QueueJob] {
        QueueJob.merged(printJobs: printJobs, recentTasks: recentTasks)
    }
}

struct PrintQueueToolbar: View {
    @Binding var filter: PrintQueueFilter
    @Binding var searchText: String
    let counts: [PrintQueueFilter: Int]
    let allSelected: Bool
    let toggleAll: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(PrintQueueFilter.allCases) { item in
                    Button {
                        filter = item
                    } label: {
                        HStack(spacing: 5) {
                            Text(item.title)
                                .fontWeight(.medium)
                            Text("\(counts[item, default: 0])")
                                .foregroundStyle(filter == item ? QueueDesign.accent : QueueDesign.neutral)
                        }
                        .font(.system(size: 12.5))
                        .foregroundStyle(filter == item ? QueueDesign.ink : QueueDesign.ink2)
                        .padding(.horizontal, 13)
                        .frame(height: 28)
                        .background(filter == item ? QueueDesign.white : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .shadow(color: filter == item ? .black.opacity(0.10) : .clear, radius: 2, x: 0, y: 1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(QueueDesign.control, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            Spacer()

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(QueueDesign.borderMid)

                TextField("搜索运单号 / 收件人", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 11)
            .frame(width: 250, height: 30)
            .background(QueueDesign.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Button(action: toggleAll) {
                Text(allSelected ? "取消" : "全选")
                    .font(.system(size: 13, weight: .medium))
                    .frame(minWidth: 44)
            }
            .buttonStyle(QueuePlainButtonStyle())
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background(QueueDesign.white)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(QueueDesign.borderSoft)
                .frame(height: 0.5)
        }
    }
}

struct QueuePlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(QueueDesign.ink)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(configuration.isPressed ? QueueDesign.controlPressed : QueueDesign.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(QueueDesign.borderSoft, lineWidth: 0.5)
            }
    }
}

struct QueueListPanel: View {
    let jobs: [QueueJob]
    let selectedJobID: QueueJob.ID?
    let selectedIDs: Set<QueueJob.ID>
    let selectJob: (QueueJob) -> Void
    let toggleSelection: (QueueJob) -> Void
    let showError: (QueueJob) -> Void

    var body: some View {
        VStack(spacing: 0) {
            QueueHeaderRow()

            if jobs.isEmpty {
                QueueEmptyListView()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(jobs) { job in
                            QueueJobRow(
                                job: job,
                                isSelected: selectedJobID == job.id,
                                isChecked: selectedIDs.contains(job.id),
                                selectJob: { selectJob(job) },
                                toggleSelection: { toggleSelection(job) },
                                showError: { showError(job) }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
        }
        .background(QueueDesign.canvas)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(QueueDesign.borderSoft)
                .frame(width: 0.5)
        }
    }
}

struct QueueHeaderRow: View {
    var body: some View {
        Grid(alignment: .center, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                QueueCheckbox(isOn: false)
                    .padding(.leading, 16)
                    .frame(width: 54, alignment: .leading)

                Text("任务详情")
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("份数")
                    .frame(width: 64, alignment: .trailing)

                Text("创建时间")
                    .frame(width: 92, alignment: .trailing)
                    .padding(.trailing, 16)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(QueueDesign.neutral)
        .textCase(.uppercase)
        .frame(height: 44)
        .background(QueueDesign.canvas)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(QueueDesign.borderSoft)
                .frame(height: 0.5)
        }
    }
}

struct QueueJobRow: View {
    let job: QueueJob
    let isSelected: Bool
    let isChecked: Bool
    let selectJob: () -> Void
    let toggleSelection: () -> Void
    let showError: () -> Void

    var body: some View {
        Grid(alignment: .center, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                Button(action: toggleSelection) {
                    QueueCheckbox(isOn: isChecked)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
                .frame(width: 54, alignment: .leading)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text(job.waybillCode)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(QueueDesign.ink)
                            .fontDesign(.default)
                            .lineLimit(1)

                        QueueKindBadge(kind: job.kind)
                        QueueStatusBadge(status: job.status)
                    }

                    HStack(spacing: 4) {
                        Text(job.receiverName)
                            .foregroundStyle(QueueDesign.neutral)

                        if job.status == .failed {
                            Text("·")
                                .foregroundStyle(QueueDesign.neutral)
                            Button(action: showError) {
                                Text("查看错误详情")
                                    .foregroundStyle(QueueDesign.danger)
                                    .underline()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .font(.system(size: 12.5))
                    .lineLimit(1)

                    if job.status == .printing {
                        ProgressView(value: job.progress)
                            .progressViewStyle(.linear)
                            .tint(QueueDesign.accent)
                            .frame(height: 3)
                            .padding(.top, 8)
                            .padding(.trailing, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(job.copies) 份")
                    .font(.system(size: 13))
                    .foregroundStyle(QueueDesign.ink2)
                    .frame(width: 64, alignment: .trailing)

                Text(job.createdAtText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(QueueDesign.neutral)
                    .monospacedDigit()
                    .frame(width: 92, alignment: .trailing)
                    .padding(.trailing, 8)
            }
        }
        .padding(.vertical, 12)
        .background(isSelected ? QueueDesign.white : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? QueueDesign.borderSoft : Color.clear, lineWidth: 1)
        }
        .shadow(color: isSelected ? .black.opacity(0.08) : .clear, radius: 12, x: 0, y: 7)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture(perform: selectJob)
        .accessibilityAddTraits(.isButton)
    }
}

struct QueueCheckbox: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isOn ? QueueDesign.accent : QueueDesign.white)
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(isOn ? QueueDesign.accent : QueueDesign.borderMid, lineWidth: 1.5)
                }

            if isOn {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 17, height: 17)
    }
}

struct QueueStatusBadge: View {
    let status: QueueJobStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(status.dot)
                .frame(width: 6, height: 6)

            Text(status.title)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(status.foreground)
        .padding(.horizontal, 8)
        .frame(height: 19)
        .background(status.background, in: Capsule())
    }
}

struct QueueKindBadge: View {
    let kind: QueueJobKind

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 10, weight: .semibold))

            Text(kind.title)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(kind.color)
        .padding(.horizontal, 8)
        .frame(height: 19)
        .background(kind.color.opacity(0.12), in: Capsule())
    }
}

struct QueueEmptyListView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 38, weight: .semibold))
            Text("暂无打印任务")
                .font(.system(size: 13))
        }
        .foregroundStyle(QueueDesign.borderMid)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BulkSelectionBar: View {
    let count: Int
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(count) 项已选")
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            Button("打印所选") {}
                .buttonStyle(BulkButtonStyle(isPrimary: true))
            Button("重打") {}
                .buttonStyle(BulkButtonStyle(isPrimary: false))
            Button("取消", action: clear)
                .buttonStyle(BulkButtonStyle(isPrimary: false, isClear: true))
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(QueueDesign.darkSurface)
        .foregroundStyle(.white)
    }
}

struct BulkButtonStyle: ButtonStyle {
    var isPrimary = false
    var isClear = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isClear ? Color.white.opacity(0.70) : .white)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(background(configuration.isPressed), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func background(_ isPressed: Bool) -> Color {
        if isClear {
            return .clear
        }
        if isPrimary {
            return QueueDesign.accent.opacity(isPressed ? 0.85 : 1)
        }
        return Color.white.opacity(isPressed ? 0.20 : 0.14)
    }
}

struct QueuePreviewDrawer: View {
    let job: QueueJob
    let pdfURL: URL?
    @ObservedObject var model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        QueueKindBadge(kind: job.kind)
                        QueueStatusBadge(status: job.status)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.waybillCode)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(QueueDesign.ink)
                            .lineLimit(2)
                            .monospacedDigit()

                        Text(job.metadataText)
                            .font(.system(size: 12.5))
                            .foregroundStyle(QueueDesign.neutral)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(QueueDesign.ink2)
                        .frame(width: 28, height: 28)
                        .background(QueueDesign.control, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 16)
            .background(QueueDesign.white)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(QueueDesign.borderSoft)
                    .frame(height: 0.5)
            }

            LabelPreviewWorkspace(pdfURL: pdfURL, model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(QueueDesign.white)
        .shadow(color: .black.opacity(0.18), radius: 40, x: -8, y: 0)
    }
}

struct QueuePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(QueueDesign.accent.opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct QueueErrorDrawer: View {
    let job: QueueJob
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 12) {
                        QueueStatusBadge(status: .failed)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("打印失败")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(QueueDesign.ink)
                            Text("\(job.waybillCode) · \(job.receiverName)")
                                .font(.system(size: 13))
                                .foregroundStyle(QueueDesign.neutral)
                                .monospacedDigit()
                        }
                    }

                    Spacer()

                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(QueueDesign.ink2)
                            .frame(width: 28, height: 28)
                            .background(QueueDesign.control, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(QueueDesign.borderSoft)
                    .frame(height: 0.5)
            }

            ScrollView {
                VStack(spacing: 0) {
                    QueueErrorRow(label: "错误码", value: job.errorMessage == nil ? "PRINT_FAILED" : "DEVICE_OFFLINE", codeStyle: true)
                    QueueErrorRow(label: "说明", value: job.errorMessage ?? "打印任务未成功完成。")
                    QueueErrorRow(label: "发生时间", value: job.createdAtText)
                    QueueErrorRow(label: "打印机", value: job.printerName)

                    Text(job.commandText ?? "没有可用的命令日志。")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(QueueDesign.darkSurfaceText)
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(QueueDesign.darkSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.top, 18)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }

            HStack(spacing: 10) {
                Button("忽略", action: close)
                    .buttonStyle(QueuePlainButtonStyle())
                    .frame(maxWidth: .infinity)

                Button("重试打印", action: close)
                    .buttonStyle(QueuePrimaryButtonStyle())
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(QueueDesign.borderSoft)
                    .frame(height: 0.5)
            }
        }
        .background(QueueDesign.white)
        .shadow(color: .black.opacity(0.18), radius: 40, x: -8, y: 0)
    }
}

struct QueueErrorRow: View {
    let label: String
    let value: String
    var codeStyle = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(QueueDesign.neutral)
                .frame(width: 86, alignment: .leading)

            if codeStyle {
                Text(value)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(QueueDesign.control, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Text(value)
                    .font(.system(size: 13))
                    .foregroundStyle(QueueDesign.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(QueueDesign.borderSoft)
                .frame(height: 0.5)
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
struct WaybillPrintConsoleView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ForEach([
                PreviewModelState.running,
                .stoppedEmpty,
                .starting,
                .error,
            ]) { state in
                WaybillPrintConsoleView(model: PreviewSamples.model(state))
                    .frame(width: 1320, height: 860)
                    .defaultAppStorage(PreviewSamples.previewDefaults)
                    .previewDisplayName("控制台 · \(state.title)")
            }
        }
    }
}

@MainActor
struct PrintWorkspaceContent_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ForEach(PrintSidebarDestination.allCases) { destination in
                PrintWorkspaceContent(
                    selection: destination,
                    model: PreviewSamples.model(destination == .printQueue ? .busyQueue : .running)
                )
                .frame(width: destination == .printQueue ? 1100 : 760, height: 760)
                .defaultAppStorage(PreviewSamples.previewDefaults)
                .previewDisplayName("工作区 · \(destination.title)")
            }

            PrintWorkspaceContent(selection: .printQueue, model: PreviewSamples.model(.stoppedEmpty))
                .frame(width: 1100, height: 760)
                .defaultAppStorage(PreviewSamples.previewDefaults)
                .previewDisplayName("工作区 · 空队列")
        }
    }
}

@MainActor
struct ConsoleChrome_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ServiceControlsPanel(model: PreviewSamples.model(.starting))
                .defaultAppStorage(PreviewSamples.previewDefaults)
                .previewDisplayName("服务弹层 · 启动中")

            ServiceControlsPanel(model: PreviewSamples.model(.error))
                .defaultAppStorage(PreviewSamples.previewDefaults)
                .previewDisplayName("服务弹层 · 错误")

            HStack(spacing: 12) {
                ForEach(ServiceState.allPreviewCases, id: \.rawValue) { state in
                    PipelineStateBadge(state: state)
                }
                PrinterStatusBadge(printer: PreviewSamples.printers[0])
                PrinterStatusBadge(printer: PreviewSamples.unavailablePrinters[0])
            }
            .padding()
            .defaultAppStorage(PreviewSamples.previewDefaults)
            .previewDisplayName("状态徽标")
        }
    }
}
#endif
