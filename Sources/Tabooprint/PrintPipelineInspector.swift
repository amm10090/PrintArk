import SwiftUI

struct PrintPipelineInspector: View {
    @ObservedObject var model: AppModel

    @AppStorage(SettingsKeys.printerName) private var printerName = "TAOBAO"
    @AppStorage(SettingsKeys.printMedia) private var printMedia = "100x180mm"
    @AppStorage(SettingsKeys.printDryRun) private var printDryRun = true
    @AppStorage(SettingsKeys.printFitToPage) private var fitToPage = true
    @AppStorage(SettingsKeys.printDedupe) private var duplicateProtection = true
    @AppStorage(SettingsKeys.dedupeWindowMinutes) private var duplicateWindowMinutes = 10

    private var printers: [PrinterDevice] {
        var devices = model.printerDevices
        if devices.isEmpty {
            devices = [.fallback]
        }
        if !devices.contains(where: { $0.name == printerName }) {
            devices.insert(PrinterDevice(name: printerName.isEmpty ? "TAOBAO" : printerName, isDefault: false, isEnabled: true), at: 0)
        }
        return devices
    }

    private var selectedPrinter: PrinterDevice {
        printers.first(where: { $0.name == printerName }) ?? .fallback
    }

    private var printModeBinding: Binding<PrintMode> {
        Binding(
            get: { PrintMode(dryRun: printDryRun) },
            set: { printDryRun = $0.isDryRun }
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PipelineSettingsCard(
                    selectedPrinter: selectedPrinter,
                    printerName: $printerName,
                    printMedia: $printMedia,
                    printMode: printModeBinding,
                    fitToPage: $fitToPage,
                    duplicateProtection: $duplicateProtection,
                    duplicateWindowMinutes: $duplicateWindowMinutes,
                    printers: printers
                )

                DeduplicationCard(
                    printerName: selectedPrinter.name,
                    printMedia: printMedia,
                    fitToPage: fitToPage,
                    enabled: duplicateProtection,
                    windowMinutes: duplicateWindowMinutes
                )

                RecentJobsCard(jobs: model.printJobs)

                FutureBatchCard()
            }
            .padding(18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("打印设置")
    }
}

struct PipelineSettingsCard: View {
    let selectedPrinter: PrinterDevice

    @Binding var printerName: String
    @Binding var printMedia: String
    @Binding var printMode: PrintMode
    @Binding var fitToPage: Bool
    @Binding var duplicateProtection: Bool
    @Binding var duplicateWindowMinutes: Int

    let printers: [PrinterDevice]

    var body: some View {
        SettingsCard(title: "打印管线", subtitle: "对应当前 macOS lpr 打印链路。") {
            VStack(spacing: 14) {
                Picker("打印机", selection: $printerName) {
                    ForEach(printers) { printer in
                        Text(printer.displayName + (printer.isEnabled ? "" : " · 未启用"))
                            .tag(printer.name)
                    }
                }

                HStack {
                    Text("启用状态")
                    Spacer()
                    StatusText(
                        text: selectedPrinter.isEnabled ? "可用" : "不可用",
                        color: selectedPrinter.isEnabled ? .green : .red
                    )
                }

                TextField("纸张参数 printMedia", text: $printMedia)
                    .textFieldStyle(.roundedBorder)

                Text("传给 lpr -o media=...，例如 100x180mm。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Picker("打印模式", selection: $printMode) {
                    ForEach(PrintMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("页面适配 fit-to-page", isOn: $fitToPage)

                Toggle("重复打印保护", isOn: $duplicateProtection)

                if duplicateProtection {
                    Stepper("保护窗口：\(duplicateWindowMinutes) 分钟", value: $duplicateWindowMinutes, in: 1...60)
                }
            }
        }
    }
}

struct DeduplicationCard: View {
    let printerName: String
    let printMedia: String
    let fitToPage: Bool
    let enabled: Bool
    let windowMinutes: Int

    var body: some View {
        SettingsCard(title: "去重依据", subtitle: "这些字段共同决定是否跳过重复打印。") {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    StatusText(text: enabled ? "已启用" : "已关闭", color: enabled ? .green : .secondary)
                    StatusText(text: "\(windowMinutes) 分钟窗口", color: .secondary)
                    Spacer()
                }

                DedupKeyRow("打印机：\(printerName)")
                DedupKeyRow("纸张参数：\(printMedia.isEmpty ? "(default-media)" : printMedia)")
                DedupKeyRow("fit-to-page：\(fitToPage ? "fit" : "nofit")")
                DedupKeyRow("documentID")
                DedupKeyRow("面单内容指纹")
            }
        }
    }
}

struct DedupKeyRow: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)

            Text(text)
                .font(.subheadline)

            Spacer()
        }
    }
}

struct RecentJobsCard: View {
    let jobs: [PrintJob]

    var body: some View {
        SettingsCard(title: "最近任务", subtitle: "用于排查 PDF 路径、lpr 状态和去重结果。") {
            if jobs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("等待 print payload", systemImage: "tray")
                        .font(.subheadline.weight(.semibold))

                    Text("千牛提交后会显示 PDF 路径、lpr 命令和去重结果。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 10) {
                    ForEach(jobs) { job in
                        RecentJobRow(job: job)
                    }
                }
            }
        }
    }
}

struct RecentJobRow: View {
    let job: PrintJob

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.waybillCode)
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))

                    Text(job.printerName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Label(job.status.rawValue, systemImage: job.status.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(job.status.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(job.status.color.opacity(0.12), in: Capsule())
            }

            if !job.pdfPath.isEmpty {
                Text(job.pdfPath)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let commandText = job.commandText, !commandText.isEmpty {
                Text(commandText)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let errorMessage = job.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(job.status == .failed ? .red : .secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct FutureBatchCard: View {
    var body: some View {
        SettingsCard(title: "后续批量能力", subtitle: "当前支持 payload 内多个 documents；导入能力可作为下一阶段。") {
            VStack(alignment: .leading, spacing: 10) {
                FutureRow(title: "CSV / Excel 导入", detail: "后续解析为 documents")
                FutureRow(title: "字段映射", detail: "后续映射 waybillCode、地址、备注等字段")
                FutureRow(title: "批量预览", detail: "payload 内多个 documents 当前可进入渲染")
                FutureRow(title: "批量打印", detail: "后续统一提交到 macOS lpr")
                FutureRow(title: "失败重试", detail: "后续对失败任务单独重试")
            }
        }
    }
}

struct FutureRow: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            content
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        }
    }
}

struct StatusText: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct PrinterStatusBadge: View {
    let printer: PrinterDevice

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(printer.isEnabled ? .green : .red)
                .frame(width: 8, height: 8)

            Text(printer.isEnabled ? "\(printer.name) 在线" : "\(printer.name) 不可用")
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(
            (printer.isEnabled ? Color.green.opacity(0.12) : Color.red.opacity(0.12)),
            in: Capsule()
        )
        .foregroundStyle(printer.isEnabled ? .green : .red)
    }
}

#if DEBUG
@MainActor
struct PrintPipelineInspector_Previews: PreviewProvider {
    static var previews: some View {
        PrintPipelineInspector(model: PreviewSamples.consoleModel)
            .frame(width: 390, height: 760)
    }
}
#endif
