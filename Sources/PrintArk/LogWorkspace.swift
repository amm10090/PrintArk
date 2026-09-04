import SwiftUI

enum DiagnosticLogLevel: Int, CaseIterable, Identifiable {
    case error = 0
    case warning = 1
    case info = 2
    case debug = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .error: return "错误"
        case .warning: return "警告"
        case .info: return "信息"
        case .debug: return "调试"
        }
    }

    var shortTitle: String {
        switch self {
        case .error: return "ERROR"
        case .warning: return "WARN"
        case .info: return "INFO"
        case .debug: return "DEBUG"
        }
    }

    var color: Color {
        switch self {
        case .error: return .red
        case .warning: return .orange
        case .info: return .blue
        case .debug: return .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        case .debug: return "ladybug.fill"
        }
    }

    func includes(_ entryLevel: Self) -> Bool {
        entryLevel.rawValue <= rawValue
    }
}

struct DiagnosticLogEntry: Identifiable {
    let id: Int
    let level: DiagnosticLogLevel
    let text: String

    static func parse(_ content: String) -> [Self] {
        content
            .split(whereSeparator: { $0.isNewline })
            .enumerated()
            .compactMap { index, line in
                let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return Self(id: index, level: classify(text), text: text)
            }
    }

    private static func classify(_ text: String) -> DiagnosticLogLevel {
        let normalized = text.lowercased()

        let errorMarkers = [
            "[error]", "error", "failed", "failure", "失败", "错误",
            "document-not-found", "not found", "不存在", "blocked", "decrypt",
            "\"ok\":false", "\"status\":\"failed",
        ]
        if errorMarkers.contains(where: normalized.contains) { return .error }

        let warningMarkers = [
            "[warn]", "warning", "warn", "警告", "disabled", "missing",
            "duplicate-suppressed", "timeout", "timed out", "closed", "unavailable",
        ]
        if warningMarkers.contains(where: normalized.contains) { return .warning }

        let debugMarkers = [
            "[debug]", "recv cmd=", "send cmd=", "http get", "http post",
            "\"type\":\"connection\"", "\"type\":\"native-handshake\"",
        ]
        if debugMarkers.contains(where: normalized.contains) { return .debug }

        return .info
    }
}

private struct DiagnosticLogDiagnosis {
    let title: String
    let detail: String
    let suggestion: String
    let sourceLine: String?
    let level: DiagnosticLogLevel

    static func analyze(_ entries: [DiagnosticLogEntry]) -> Self {
        guard let issue = entries.reversed().first(where: { $0.level == .error || $0.level == .warning }) else {
            return Self(
                title: "暂未发现明显异常",
                detail: "当前日志中没有错误或警告记录。",
                suggestion: "若打印仍未输出，请切换到“调试”级别并重新触发一次打印。",
                sourceLine: nil,
                level: .info
            )
        }

        let text = issue.text.lowercased()
        if text.contains("document-not-found") || text.contains("document not found")
            || text.contains("no documents") || text.contains("pdf 不存在") || text.contains("缺少 pdf") {
            return diagnosis(
                title: "打印文档不可用",
                detail: "服务没有拿到可打印文档，或已生成的 PDF 路径失效。",
                suggestion: "确认订单已获取电子面单，重新请求打印；重试任务时检查 PDF 文件是否仍存在。",
                issue: issue
            )
        }
        if text.contains("decrypt") || text.contains("encrypteddata")
            || text.contains("signature") || text.contains("token") {
            return diagnosis(
                title: "面单数据解密失败",
                detail: "浏览器传入的加密数据、签名或令牌可能无效。",
                suggestion: "重新登录打单平台后再试，并确认客户端密钥与当前店铺授权一致。",
                issue: issue
            )
        }
        if text.contains("lpr") || text.contains("cups") || text.contains("printer")
            || text.contains("打印机") {
            return diagnosis(
                title: "打印机提交失败",
                detail: "任务已进入本机打印阶段，但未能成功提交到 macOS 打印队列。",
                suggestion: "检查打印机是否在线、系统默认打印机是否正确，并在“打印队列”中查看失败详情后重试。",
                issue: issue
            )
        }
        if text.contains("port") || text.contains("address already in use")
            || text.contains("listen") || text.contains("端口") {
            return diagnosis(
                title: "本机服务端口异常",
                detail: "打印服务需要的本机端口未能正常监听。",
                suggestion: "停止占用对应端口的程序，然后在左侧服务卡片中重启本机服务。",
                issue: issue
            )
        }
        if text.contains("tls") || text.contains("certificate") || text.contains("wss")
            || text.contains("证书") {
            return diagnosis(
                title: "安全连接异常",
                detail: "浏览器到本机打印服务的安全连接或证书可能不可用。",
                suggestion: "检查本机证书状态，修复后重启服务并刷新打单页面。",
                issue: issue
            )
        }
        if text.contains("websocket") || text.contains("connection") || text.contains("连接") {
            return diagnosis(
                title: "浏览器连接异常",
                detail: "打单页面与本机打印服务之间的连接发生中断。",
                suggestion: "确认本机服务正在运行，然后刷新打单页面并重新发送打印任务。",
                issue: issue
            )
        }

        return diagnosis(
            title: issue.level == .error ? "检测到打印错误" : "检测到运行警告",
            detail: "最近一条异常日志可能与本次打印问题有关。",
            suggestion: "复制下方日志中的请求 ID 与错误上下文，并结合“打印队列”的任务详情继续排查。",
            issue: issue
        )
    }

    private static func diagnosis(
        title: String,
        detail: String,
        suggestion: String,
        issue: DiagnosticLogEntry
    ) -> Self {
        Self(title: title, detail: detail, suggestion: suggestion, sourceLine: issue.text, level: issue.level)
    }
}

struct LogWorkspace: View {
    @ObservedObject var model: AppModel
    @AppStorage("printark.logMinimumLevel") private var minimumLevel: DiagnosticLogLevel = .info
    @State private var searchText = ""

    private var entries: [DiagnosticLogEntry] {
        DiagnosticLogEntry.parse(model.redactedLogs)
    }

    private var visibleEntries: [DiagnosticLogEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.filter { entry in
            minimumLevel.includes(entry.level)
                && (query.isEmpty || entry.text.lowercased().contains(query))
        }
    }

    private var diagnosis: DiagnosticLogDiagnosis {
        DiagnosticLogDiagnosis.analyze(entries)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            toolbar
            Divider()
            logContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("运行日志")
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.72)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .shadow(color: Color.accentColor.opacity(0.25), radius: 6, y: 3)

                VStack(alignment: .leading, spacing: 3) {
                    Text("运行日志")
                        .font(.title2.weight(.semibold))
                    Text("按日志等级筛选本机打印流程，并从最近异常中定位失败原因。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    ForEach(DiagnosticLogLevel.allCases) { level in
                        statPill(level)
                    }
                }
            }

            diagnosisCard
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 18)
    }

    /// 等级统计胶囊：实时计数，点击即把最低等级切到该等级，快速聚焦对应日志。
    private func statPill(_ level: DiagnosticLogLevel) -> some View {
        let count = entries.filter { $0.level == level }.count
        let isActive = minimumLevel == level
        return Button {
            minimumLevel = level
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(level.color)
                    .frame(width: 6, height: 6)
                Text(level.title)
                    .font(.caption.weight(.medium))
                Text("\(count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            .foregroundStyle(isActive ? level.color : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(level.color.opacity(isActive ? 0.16 : 0.08), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(level.color.opacity(isActive ? 0.45 : 0), lineWidth: 1)
            )
            .opacity(count == 0 && !isActive ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .help("显示「\(level.title)」及更严重等级的日志")
    }

    // MARK: - Diagnosis

    private var diagnosisCard: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: diagnosis.level.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(diagnosis.level.color)
                .frame(width: 34, height: 34)
                .background(diagnosis.level.color.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text(diagnosis.title)
                    .font(.headline)

                Text(diagnosis.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("建议")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(diagnosis.level.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(diagnosis.level.color.opacity(0.13), in: Capsule())
                    Text(diagnosis.suggestion)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 1)

                if let sourceLine = diagnosis.sourceLine {
                    Text(sourceLine)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            Color.primary.opacity(0.045),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .padding(.top, 4)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            diagnosis.level.color.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(diagnosis.level.color.opacity(0.16), lineWidth: 1)
        )
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("日志等级", selection: $minimumLevel) {
                ForEach(DiagnosticLogLevel.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 232)
            .help("日志等级：显示所选等级及更严重的日志")

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                TextField("搜索日志", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索内容")
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 220, height: 26)
            .background(
                Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )

            Spacer(minLength: 4)

            Text("\(visibleEntries.count) / \(entries.count) 条")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.05), in: Capsule())

            Button(action: model.refresh) {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .help("立即刷新日志")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    // MARK: - Content

    @ViewBuilder
    private var logContent: some View {
        if entries.isEmpty {
            logEmptyState(
                title: "暂无运行日志",
                detail: "启动本机服务并触发一次打印后，日志会自动出现在这里。",
                systemImage: "text.badge.plus"
            )
        } else if visibleEntries.isEmpty {
            logEmptyState(
                title: "没有符合条件的日志",
                detail: "尝试降低日志等级或清除搜索条件。",
                systemImage: "line.3.horizontal.decrease.circle"
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleEntries) { entry in
                        DiagnosticLogRow(entry: entry)
                    }
                }
                .padding(.vertical, 6)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func logEmptyState(title: String, detail: String, systemImage: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.secondary)
                .padding(.bottom, 2)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// 单条日志：行号 + 等级胶囊 + 等宽正文；错误/警告行带淡色底，悬停时高亮。
private struct DiagnosticLogRow: View {
    let entry: DiagnosticLogEntry
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(entry.id + 1)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 38, alignment: .trailing)
                .textSelection(.disabled)

            Text(entry.level.shortTitle)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(entry.level.color)
                .frame(width: 50)
                .padding(.vertical, 2)
                .background(
                    entry.level.color.opacity(0.13),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .textSelection(.disabled)

            Text(entry.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(rowTint)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.05))
                .frame(height: 0.5)
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var rowTint: Color {
        if isHovered { return Color.primary.opacity(0.05) }
        switch entry.level {
        case .error: return Color.red.opacity(0.05)
        case .warning: return Color.orange.opacity(0.04)
        case .info, .debug: return .clear
        }
    }
}
