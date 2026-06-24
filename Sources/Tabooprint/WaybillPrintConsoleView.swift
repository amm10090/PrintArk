import SwiftUI

struct WaybillPrintConsoleView: View {
    @ObservedObject var model: AppModel
    @AppStorage(SettingsKeys.printerName) private var printerName = "TAOBAO"
    @AppStorage(SettingsKeys.printDryRun) private var printDryRun = true

    private var selectedPrinter: PrinterDevice {
        model.printerDevices.first(where: { $0.name == printerName }) ?? PrinterDevice(name: printerName, isDefault: false, isEnabled: true)
    }

    var body: some View {
        NavigationSplitView {
            PrintSidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } content: {
            LabelPreviewWorkspace(document: .sample)
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
                    Label(printDryRun ? "启动 Dry-run" : "启动真实打印", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct PrintSidebarView: View {
    var body: some View {
        List {
            Section("打印") {
                Label("当前面单", systemImage: "doc.text")
                Label("打印队列", systemImage: "tray.full")
                Label("最近任务", systemImage: "clock")
            }

            Section("批量能力") {
                Label("Payload 多文档", systemImage: "doc.on.doc")
                Label("CSV / Excel 导入", systemImage: "tablecells")
                    .foregroundStyle(.secondary)
                Label("字段映射", systemImage: "arrow.left.arrow.right")
                    .foregroundStyle(.secondary)
                Label("失败重试", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            }

            Section("说明") {
                Label("当前版本", systemImage: "info.circle")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("工作台")
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
