import SwiftUI

struct PrintPipelineInspector: View {
    @ObservedObject var model: AppModel

    @AppStorage(SettingsKeys.printerName) private var printerName = "TAOBAO"
    @AppStorage(SettingsKeys.printMedia) private var printMedia = "100x180mm"
    @AppStorage(SettingsKeys.printFitToPage) private var fitToPage = true
    @AppStorage(SettingsKeys.printDedupe) private var duplicateProtection = true
    @AppStorage(SettingsKeys.dedupeWindowMinutes) private var duplicateWindowMinutes = 10
    @AppStorage(SettingsKeys.printHideTaoLogo) private var hideTaoLogo = false
    @AppStorage(SettingsKeys.printHideCourierPackage) private var hideCourierPackage = false
    @AppStorage(SettingsKeys.printHideBorder) private var hideBorder = false

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

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PipelineSettingsCard(
                    selectedPrinter: selectedPrinter,
                    printerName: $printerName,
                    printMedia: $printMedia,
                    fitToPage: $fitToPage,
                    duplicateProtection: $duplicateProtection,
                    duplicateWindowMinutes: $duplicateWindowMinutes,
                    printers: printers
                )
                .onChange(of: printerName) { _ in model.rebakePreviewNow() }

                PrinterCalibrationCard(model: model, printerName: printerName)

                LabelContentCard(
                    model: model,
                    hideTaoLogo: $hideTaoLogo,
                    hideCourierPackage: $hideCourierPackage,
                    hideBorder: $hideBorder
                )

                RecentJobsCard(jobs: model.queueJobs)
            }
            .frame(maxWidth: .infinity)
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
    @Binding var fitToPage: Bool
    @Binding var duplicateProtection: Bool
    @Binding var duplicateWindowMinutes: Int

    let printers: [PrinterDevice]

    private var selectedPaperSize: PaperSize {
        PaperCatalog.match(media: printMedia)
    }

    private var paperSizeBinding: Binding<PaperSize> {
        Binding(
            get: { PaperCatalog.match(media: printMedia) },
            set: { printMedia = $0.media }
        )
    }

    var body: some View {
        SettingsCard(title: "打印设置", subtitle: "面单的打印机和纸张选项。") {
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

                Picker("纸张尺寸", selection: paperSizeBinding) {
                    ForEach(PaperSize.Group.allCases) { group in
                        Section(group.rawValue) {
                            ForEach(PaperCatalog.grouped(group)) { size in
                                Text(size.displayName).tag(size)
                            }
                        }
                    }
                }

                Text("纸张尺寸 \(selectedPaperSize.sizeText)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Toggle("自动缩放以适应纸张", isOn: $fitToPage)

                Toggle("避免重复打印", isOn: $duplicateProtection)

                if duplicateProtection {
                    Stepper("保护窗口：\(duplicateWindowMinutes) 分钟", value: $duplicateWindowMinutes, in: 1...60)
                }
            }
        }
    }
}

struct LabelContentCard: View {
    @ObservedObject var model: AppModel
    @Binding var hideTaoLogo: Bool
    @Binding var hideCourierPackage: Bool
    @Binding var hideBorder: Bool

    var body: some View {
        SettingsCard(title: "面单内容", subtitle: "选择是否打印这些标记。") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("不打印左上角的“淘”字", isOn: $hideTaoLogo)
                    .onChange(of: hideTaoLogo) { _ in model.rebakePreviewNow() }

                Toggle("不打印右上角的“快递包裹”", isOn: $hideCourierPackage)
                    .onChange(of: hideCourierPackage) { _ in model.rebakePreviewNow() }

                Toggle("不打印面单外边框", isOn: $hideBorder)
                    .onChange(of: hideBorder) { _ in model.rebakePreviewNow() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 按打印机的校准设置卡片。通过指向 model.printerCalibrations、按当前 printerName
/// 取值的计算 Binding 读写——切换打印机 Picker 时控件自动显示该机器的值。
struct PrinterCalibrationCard: View {
    @ObservedObject var model: AppModel
    let printerName: String

    @AppStorage(SettingsKeys.printFlip) private var flipPrint = false

    private static let rotationOptions = [0, 90, 180, 270, 360]

    private var calibration: Binding<PrinterCalibration> {
        Binding(
            get: { model.printerCalibrations[printerName] ?? .identity },
            set: {
                model.printerCalibrations[printerName] = $0
                model.saveCalibrations()
                model.applyPrintSettings()
            }
        )
    }

    private var rotationWarning: Bool {
        let rot = calibration.wrappedValue.rotationDegrees % 360
        return (rot == 90 || rot == 270) && !calibration.wrappedValue.adaptivePaper
    }

    var body: some View {
        SettingsCard(title: "打印机校准", subtitle: "为「\(printerName)」单独保存偏移、旋转、缩放与自适应纸张。") {
            VStack(alignment: .leading, spacing: 14) {
                Stepper(
                    "水平偏移：\(mmText(calibration.wrappedValue.offsetXMM)) mm（+ 向右）",
                    value: calibration.offsetXMM,
                    in: -50...50,
                    step: 0.5
                )

                Stepper(
                    "垂直偏移：\(mmText(calibration.wrappedValue.offsetYMM)) mm（+ 向下）",
                    value: calibration.offsetYMM,
                    in: -50...50,
                    step: 0.5
                )

                Picker("旋转角度", selection: calibration.rotationDegrees) {
                    ForEach(Self.rotationOptions, id: \.self) { degree in
                        Text("\(degree)°").tag(degree)
                    }
                }

                Stepper(
                    "缩放比例：\(scaleText(calibration.wrappedValue.scaleRatio))×",
                    value: calibration.scaleRatio,
                    in: 0.25...4.0,
                    step: 0.05
                )

                Toggle("自适应纸张（按内容尺寸自动选纸）", isOn: calibration.adaptivePaper)

                Divider()

                Toggle("反转打印（纸张180°反向放置时使用）", isOn: $flipPrint)
                    .onChange(of: flipPrint) { _ in model.applyPrintSettings() }

                Text("仅作用于真实打印，预览不反转。用于快递面单纸反方向放置时，避免信息从纸张底部开始打印。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if rotationWarning {
                    CalibrationHint(text: "90° / 270° 旋转在非自适应纸张下可能裁切内容，建议开启自适应纸张。", color: .orange)
                }

                if calibration.wrappedValue.rotationDegrees % 360 == 180 && flipPrint {
                    CalibrationHint(text: "校准旋转 180° 与「反转打印」会在纸面相互抵消（预览仍显示 180°）。", color: .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func mmText(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func scaleText(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

struct CalibrationHint: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(color)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    let jobs: [QueueJob]

    var body: some View {
        SettingsCard(title: "最近任务", subtitle: "查看每次打印和预览任务的文件和结果。") {
            if jobs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("等待打印任务", systemImage: "tray")
                        .font(.subheadline.weight(.semibold))

                    Text("从千牛提交后，这里会显示打印和预览的文件、状态与结果。")
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
    let job: QueueJob

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.waybillCode)
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))

                    Text(job.printerName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    QueueKindBadge(kind: job.kind)
                    QueueStatusBadge(status: job.status)
                }
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
        Group {
            ForEach([
                PreviewModelState.running,
                .stoppedEmpty,
                .error,
                .busyQueue,
                .calibrated,
            ]) { state in
                PrintPipelineInspector(model: PreviewSamples.model(state))
                    .frame(width: 390, height: 760)
                    .defaultAppStorage(PreviewSamples.previewDefaults)
                    .previewDisplayName("设置面板 · \(state.title)")
            }
        }
    }
}

@MainActor
struct PrintSettingsCards_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            RecentJobsCard(jobs: [])
                .padding(24)
                .frame(width: 420)
                .defaultAppStorage(PreviewSamples.previewDefaults)
                .previewDisplayName("最近任务 · 空")

            RecentJobsCard(jobs: PreviewSamples.model(.busyQueue).queueJobs)
                .padding(24)
                .frame(width: 420)
                .defaultAppStorage(PreviewSamples.previewDefaults)
                .previewDisplayName("最近任务 · 多状态")

            RecentJobRow(job: PreviewSamples.model(.error).queueJobs.first(where: { $0.kind == .failure }) ?? PreviewSamples.model(.error).queueJobs[0])
                .padding(24)
                .frame(width: 420)
                .defaultAppStorage(PreviewSamples.previewDefaults)
                .previewDisplayName("任务行 · 失败")

            PipelineSettingsCard(
                selectedPrinter: PreviewSamples.unavailablePrinters[0],
                printerName: .constant("TAOBAO"),
                printMedia: .constant("A4"),
                fitToPage: .constant(true),
                duplicateProtection: .constant(false),
                duplicateWindowMinutes: .constant(10),
                printers: PreviewSamples.unavailablePrinters
            )
            .padding(24)
            .frame(width: 420)
            .defaultAppStorage(PreviewSamples.previewDefaults)
            .previewDisplayName("打印设置 · 不可用打印机")

            PrinterCalibrationCard(model: PreviewSamples.model(.calibrated), printerName: "TAOBAO")
                .padding(24)
                .frame(width: 420)
                .defaultAppStorage(PreviewSamples.previewDefaults)
                .previewDisplayName("打印机校准 · 警告")
        }
    }
}
#endif
