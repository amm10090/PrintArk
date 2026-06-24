import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage(SettingsKeys.runtimeMode) private var runtimeModeRaw = RuntimeMode.defaultPreview.rawValue
    @AppStorage(SettingsKeys.autoOpenPreview) private var autoOpenPreview = true
    @AppStorage(SettingsKeys.printerName) private var printerName = "TAOBAO"
    @AppStorage(SettingsKeys.printMedia) private var printMedia = ""
    @AppStorage(SettingsKeys.printDryRun) private var printDryRun = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Tabooprint")
                    .font(.title2.weight(.semibold))

                serviceSection
                controlsSection
                diagnosticsSection
                taskSection
                logSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 980, minHeight: 720)
    }

    private var serviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("服务")
                .font(.headline)
            Text(model.serviceSummary)
                .font(.body.weight(.medium))
            HStack(spacing: 16) {
                LabeledContent("状态", value: model.serviceState.title)
                LabeledContent("浏览器连接", value: "\(model.activeBrowserConnections)")
                LabeledContent("刷新时间", value: model.lastRefreshedText)
            }
        }
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("控制")
                .font(.headline)

            HStack(spacing: 8) {
                Button(action: model.startService) {
                    Label("启动", systemImage: "play.fill")
                }
                .disabled(model.serviceState == .running || model.serviceState == .starting)

                Button(action: model.stopService) {
                    Label("停止", systemImage: "stop.fill")
                }
                .disabled(model.serviceState == .stopped || model.serviceState == .stopping)

                Button(action: model.restartService) {
                    Label("重启", systemImage: "arrow.clockwise")
                }

                Button(action: model.openLatestPreview) {
                    Label("打开最新预览 PDF", systemImage: "doc.richtext")
                }

                Button(action: model.clearLogViewer) {
                    Label("清空日志", systemImage: "trash")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("运行模式")
                    .font(.subheadline.weight(.medium))

                Picker("运行模式", selection: $runtimeModeRaw) {
                    ForEach(RuntimeMode.allCases) { mode in
                        Text(mode.shortTitle).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("自动打开预览 PDF", isOn: $autoOpenPreview)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("打印管线")
                    .font(.subheadline.weight(.medium))

                HStack(spacing: 8) {
                    TextField("打印机", text: $printerName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)

                    TextField("纸张参数，例如 100x180mm", text: $printMedia)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)

                    Toggle("Dry-run", isOn: $printDryRun)
                        .toggleStyle(.checkbox)
                }

                Text(printDryRun ? "当前只记录 lpr 命令，不会真实打印。" : "当前会调用 lpr 发送到真实打印机。")
                    .font(.caption)
                    .foregroundStyle(printDryRun ? Color.secondary : Color.red)
            }

            if !model.lastActionOutput.isEmpty {
                Text(model.lastActionOutput)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("诊断")
                .font(.headline)

            HStack(alignment: .top, spacing: 12) {
                ForEach(model.ports) { port in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(port.label)
                            .font(.subheadline.weight(.medium))
                        Text(port.stateText)
                        Text("\(port.listenerCount) 个监听进程")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近任务")
                .font(.headline)

            Table(model.recentTasks) {
                TableColumn("时间") { task in
                    Text(task.timestampText)
                        .font(.system(.caption, design: .monospaced))
                }
                .width(min: 140, ideal: 180)

                TableColumn("命令") { task in
                    Text(task.command)
                }
                .width(min: 80, ideal: 100)

                TableColumn("RequestID") { task in
                    Text(task.requestID)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                }
                .width(min: 220, ideal: 260)

                TableColumn("文档数") { task in
                    Text(task.documentCountText)
                }
                .width(min: 50, ideal: 70)

                TableColumn("模式") { task in
                    Text(task.modeDisplay)
                }
                .width(min: 120, ideal: 160)

                TableColumn("结果") { task in
                    Text(task.resultDisplay)
                }
                .width(min: 100, ideal: 160)
            }
            .frame(minHeight: 220)
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("日志")
                .font(.headline)

            ScrollView {
                Text(model.redactedLogs.isEmpty ? "暂无日志" : model.redactedLogs)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)
            }
            .frame(minHeight: 220)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
    }
}
