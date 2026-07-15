import AppKit
import SwiftUI

// MARK: - 设计 token（对照 tabooprint-statusbar-native-11.html 的 :root）

/// 菜单栏下拉弹窗的设计 token。颜色优先用系统语义色以自动适配明暗，
/// 与设计稿的 macOS system palette（#007AFF / #34C759 / #FF3B30 …）一致。
enum StatusMenuStyle {
    // 系统强调色（设计稿 system-blue/green/red/orange/gray）
    static let blue = Color(nsColor: .systemBlue)
    static let green = Color(nsColor: .systemGreen)
    static let red = Color(nsColor: .systemRed)
    static let orange = Color(nsColor: .systemOrange)
    static let gray = Color(nsColor: .systemGray)

    // 文本层级
    static let labelPrimary = Color.primary
    static let labelSecondary = Color.secondary
    static let labelTertiary = Color.secondary.opacity(0.55)

    // 卡片表面与描边
    static let cardSurface = Color(nsColor: .controlBackgroundColor)
    static let cardBorder = Color.primary.opacity(0.10)
    static let cardBorderHover = Color.primary.opacity(0.16)
    static let separator = Color(nsColor: .separatorColor)
    static let hoverBackground = Color.primary.opacity(0.06)
    static let selectedBackground = Color(nsColor: .systemBlue).opacity(0.12)
    static let menuSurface = Color(nsColor: .windowBackgroundColor).opacity(0.55)

    // 服务状态条 / 分组标题
    static let statusBarSurface = Color.primary.opacity(0.04)
    static let groupHeaderText = Color.secondary
    static let progressTrack = Color.primary.opacity(0.10)

    // 错误态
    static let errorSurface = Color(nsColor: .systemRed).opacity(0.07)
    static let errorBorder = Color(nsColor: .systemRed).opacity(0.22)

    // 骨架
    static let skeletonBase = Color.primary.opacity(0.07)
    static let skeletonShine = Color.primary.opacity(0.12)

    static let menuWidth: CGFloat = 360
    static let listMaxHeight: CGFloat = 372
    /// 弹窗整体固定高度。根视图、popover.contentSize、NSHostingController 三处共用此单一来源,
    /// 消除“声明尺寸 vs 固有尺寸”冲突导致的 NSPopover 锚定错位。
    static let menuHeight: CGFloat = 540

    // 入场动画曲线（设计稿 cubic-bezier(0.16,1,0.3,1) 的近似）
    static let entrance = Animation.spring(response: 0.34, dampingFraction: 0.82)
    static let perItemStagger = 0.024
}
// MARK: - 相对时间

enum RelativeTime {
    /// 把 Date 渲染成 “刚刚 / N 分钟前 / N 小时前 / N 天前”。
    static func text(from date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) 分钟前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时前" }
        let days = hours / 24
        return "\(days) 天前"
    }
}

// MARK: - 状态徽章映射

private extension QueueJobStatus {
    /// 设计稿徽章文案。
    var badgeText: String {
        switch self {
        case .printing: return "打印中"
        case .done: return "已完成"
        case .queued: return "排队"
        case .failed: return "失败"
        }
    }

    var badgeSymbol: String {
        switch self {
        case .printing: return "clock"
        case .done: return "checkmark"
        case .queued: return "hourglass"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var badgeColor: Color {
        switch self {
        case .printing: return StatusMenuStyle.blue
        case .done: return StatusMenuStyle.green
        case .queued: return StatusMenuStyle.gray
        case .failed: return StatusMenuStyle.red
        }
    }
}

// MARK: - 队列分组

/// 弹窗内的三个折叠分组。进行中(排队+打印) / 失败 / 已完成，失败优先展示以便及时处理。
enum QueueGroup: String, CaseIterable, Identifiable {
    case active
    case failed
    case done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: return "进行中"
        case .failed: return "失败"
        case .done: return "已完成"
        }
    }

    var accent: Color {
        switch self {
        case .active: return StatusMenuStyle.blue
        case .failed: return StatusMenuStyle.red
        case .done: return StatusMenuStyle.green
        }
    }

    func contains(_ status: QueueJobStatus) -> Bool {
        switch self {
        case .active: return status == .printing || status == .queued
        case .failed: return status == .failed
        case .done: return status == .done
        }
    }
}

// MARK: - 服务状态映射

private extension ServiceState {
    /// 状态指示圆点颜色。
    var indicatorColor: Color {
        switch self {
        case .running: return StatusMenuStyle.green
        case .starting, .stopping: return StatusMenuStyle.orange
        case .stopped: return StatusMenuStyle.gray
        case .error: return StatusMenuStyle.red
        }
    }

    /// 是否需要脉冲动画（过渡态）。
    var isTransient: Bool { self == .starting || self == .stopping }
}

// MARK: - 右键上下文菜单动作

enum StatusMenuAction {
    case copy
    case reprint
    case export
    case errorDetail
    case delete
}

// MARK: - 弹窗外部动作

/// 弹窗向宿主（StatusItemController）回调的动作。复制/重打/导出/删除等任务级动作
/// 由弹窗直接消费 AppModel，这里只暴露需要操作窗口/进程的动作。
struct StatusBarPopoverActions {
    var openMainWindow: () -> Void
    var openPreferences: () -> Void
    var quit: () -> Void
}
// MARK: - 根视图

struct StatusBarPopoverView: View {
    @ObservedObject var model: AppModel
    let actions: StatusBarPopoverActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedID: QueueJob.ID?
    @State private var expandedErrorIDs: Set<QueueJob.ID> = []
    @State private var collapsedGroups: Set<QueueGroup> = [.done]
    @State private var didAppear = false

    // 右键浮层
    @State private var contextTarget: QueueJob?
    @State private var contextPoint: CGPoint = .zero
    @State private var contextVisible = false

    // Toast
    @State private var toastMessage: String?
    @State private var toastVisible = false
    @State private var toastWorkItem: DispatchWorkItem?

    // 键盘事件监听
    @State private var keyMonitor: Any?

    private var jobs: [QueueJob] { model.menuBarQueueJobs }

    private var showsSkeleton: Bool { !model.hasLoadedOnce }
    private var showsEmpty: Bool { model.hasLoadedOnce && jobs.isEmpty }

    /// 分组后的任务：保持 menuBarQueueJobs 原有顺序，仅按组切片。
    private func jobs(in group: QueueGroup) -> [QueueJob] {
        jobs.filter { group.contains($0.status) }
    }

    /// 当前可见（未折叠分组内）任务的扁平序列，供键盘上下键导航。
    private var visibleJobs: [QueueJob] {
        QueueGroup.allCases
            .filter { !collapsedGroups.contains($0) }
            .flatMap { jobs(in: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            serviceStatusBar
            content
            Divider().overlay(StatusMenuStyle.separator)
            footer
        }
        .frame(width: StatusMenuStyle.menuWidth, height: StatusMenuStyle.menuHeight)
        .background(StatusMenuStyle.menuSurface)
        .overlay(alignment: .topLeading) { contextMenuOverlay }
        .overlay(alignment: .bottom) { toastOverlay }
        .opacity(didAppear || reduceMotion ? 1 : 0)
        .scaleEffect(didAppear || reduceMotion ? 1 : 0.97, anchor: .top)
        .onAppear(perform: handleAppear)
        .onDisappear(perform: handleDisappear)
    }
    // MARK: 服务状态条

    /// 顶部单行仪表盘：状态圆点 + 服务态 + 端口 + 浏览器连接数。
    private var serviceStatusBar: some View {
        HStack(spacing: 9) {
            StatusIndicatorDot(
                color: model.serviceState.indicatorColor,
                pulsing: model.serviceState.isTransient && !reduceMotion
            )

            Text(model.serviceState.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StatusMenuStyle.labelPrimary)

            if let ws = wsPort {
                metadataDot
                Text(":\(ws)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(StatusMenuStyle.labelSecondary)
            }

            Spacer(minLength: 0)

            if model.serviceState == .running {
                HStack(spacing: 4) {
                    Image(systemName: "personalhotspot").font(.system(size: 10))
                    Text("\(model.activeBrowserConnections) 连接")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                }
                .foregroundStyle(model.activeBrowserConnections > 0 ? StatusMenuStyle.blue : StatusMenuStyle.labelTertiary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(StatusMenuStyle.statusBarSurface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(StatusMenuStyle.separator).frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(serviceAccessibilityText)
    }

    /// 从 ports 里取 WebSocket 端口；缺失时回退协议固定的 13528。
    private var wsPort: Int? {
        model.ports.first { $0.label.uppercased().hasPrefix("WS") && !$0.label.uppercased().hasPrefix("WSS") }?.port
            ?? model.ports.first { $0.label.uppercased() == "WSS" }?.port
            ?? (model.serviceState == .running ? 13528 : nil)
    }

    private var metadataDot: some View {
        Circle().fill(StatusMenuStyle.labelTertiary).frame(width: 2.5, height: 2.5)
    }

    private var serviceAccessibilityText: String {
        var parts = ["服务\(model.serviceState.title)"]
        if let ws = wsPort { parts.append("端口 \(ws)") }
        if model.serviceState == .running { parts.append("\(model.activeBrowserConnections) 个浏览器连接") }
        return parts.joined(separator: "，")
    }

    // MARK: 内容区（三态）

    // 根视图整体固定 menuHeight,内容区填充状态条/footer 之间的剩余空间。
    // 三态(骨架/空/列表)都在此区域内,弹窗总尺寸恒定,NSPopover 锚定确定。
    private var content: some View {
        Group {
            if showsSkeleton {
                skeletonList
            } else if showsEmpty {
                emptyState
            } else {
                queueList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var queueList: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(QueueGroup.allCases) { group in
                    let groupJobs = jobs(in: group)
                    if !groupJobs.isEmpty {
                        groupSection(group, jobs: groupJobs)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .frame(maxHeight: StatusMenuStyle.listMaxHeight)
    }

    @ViewBuilder
    private func groupSection(_ group: QueueGroup, jobs groupJobs: [QueueJob]) -> some View {
        let collapsed = collapsedGroups.contains(group)
        VStack(spacing: 6) {
            GroupHeaderView(
                group: group,
                count: groupJobs.count,
                collapsed: collapsed,
                onToggle: { toggleGroup(group) }
            )

            if !collapsed {
                ForEach(Array(groupJobs.enumerated()), id: \.element.id) { index, job in
                    QueueItemView(
                        job: job,
                        isSelected: selectedID == job.id,
                        errorExpanded: expandedErrorIDs.contains(job.id),
                        relativeTime: job.createdAt.map { RelativeTime.text(from: $0) },
                        onTap: { select(job) },
                        onRightClick: { point in openContextMenu(at: point, job: job) }
                    )
                    .opacity(didAppear || reduceMotion ? 1 : 0)
                    .offset(y: didAppear || reduceMotion ? 0 : 6)
                    .animation(
                        reduceMotion ? nil : StatusMenuStyle.entrance.delay(0.08 + Double(index) * StatusMenuStyle.perItemStagger),
                        value: didAppear
                    )
                }
            }
        }
    }

    private func toggleGroup(_ group: QueueGroup) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)) {
            if collapsedGroups.contains(group) {
                collapsedGroups.remove(group)
            } else {
                collapsedGroups.insert(group)
            }
        }
        closeContextMenu()
    }

    private var skeletonList: some View {
        VStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { _ in SkeletonItemView() }
        }
        .padding(8)
        .accessibilityLabel("正在加载打印任务，请稍候")
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Image(systemName: model.serviceState == .running ? "tray" : "pause.circle")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(StatusMenuStyle.labelSecondary.opacity(0.5))
                .padding(.bottom, 16)
            Text(model.serviceState == .running ? "暂无打印任务" : "服务未运行")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(StatusMenuStyle.labelPrimary)
                .padding(.bottom, 6)
            Text(model.serviceState == .running ? "队列为空，等待新的打印任务到来" : "启动服务后即可接收 Taobao / 千牛的打印请求")
                .font(.system(size: 12))
                .foregroundStyle(StatusMenuStyle.labelSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
        .padding(.horizontal, 32)
    }
    // MARK: 底部菜单

    private var footer: some View {
        VStack(spacing: 0) {
            MenuFooterItem(symbol: "checkmark", title: "清空已完成", shortcut: nil) {
                let n = jobs(in: .done).count
                model.clearCompleted()
                showToast(n > 0 ? "已清空 \(n) 个已完成任务" : "没有可清空的已完成任务")
            }
            Divider().overlay(StatusMenuStyle.separator).padding(.horizontal, 8)
            MenuFooterItem(symbol: "macwindow", title: "打开主窗口", shortcut: "⌘O", action: actions.openMainWindow)
            MenuFooterItem(symbol: "gearshape", title: "偏好设置…", shortcut: "⌘,", action: actions.openPreferences)
            Divider().overlay(StatusMenuStyle.separator).padding(.horizontal, 8)
            MenuFooterItem(symbol: "power", title: "退出 印舟", shortcut: "⌘Q", action: actions.quit)
        }
        .padding(.vertical, 6)
        .background(StatusMenuStyle.menuSurface)
    }

    // MARK: 右键浮层

    @ViewBuilder
    private var contextMenuOverlay: some View {
        if contextVisible, let job = contextTarget {
            StatusContextMenu(
                isFailed: job.status == .failed,
                canExport: !job.pdfPath.isEmpty,
                reduceMotion: reduceMotion,
                onAction: { action in perform(action, on: job) }
            )
            .offset(x: clampedContextX, y: clampedContextY)
            .transition(.identity)
        }
    }

    private var clampedContextX: CGFloat {
        min(contextPoint.x, StatusMenuStyle.menuWidth - 214)
    }

    private var clampedContextY: CGFloat {
        max(8, min(contextPoint.y, StatusMenuStyle.menuHeight - 240))
    }

    // MARK: Toast

    @ViewBuilder
    private var toastOverlay: some View {
        if let toastMessage {
            Text(toastMessage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.86), in: Capsule())
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                .padding(.bottom, 70)
                .opacity(toastVisible ? 1 : 0)
                .offset(y: toastVisible ? 0 : 16)
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: toastVisible)
        }
    }
    // MARK: 行为

    private func handleAppear() {
        expandedErrorIDs = []
        contextVisible = false
        contextTarget = nil
        didAppear = false
        // 有失败任务时自动展开失败组，方便立刻看到。
        if !jobs(in: .failed).isEmpty { collapsedGroups.remove(.failed) }
        if reduceMotion {
            didAppear = true
        } else {
            DispatchQueue.main.async {
                withAnimation(StatusMenuStyle.entrance) { didAppear = true }
            }
        }
        installKeyMonitor()
    }

    private func handleDisappear() {
        removeKeyMonitor()
        toastWorkItem?.cancel()
    }

    private func select(_ job: QueueJob) {
        selectedID = job.id
        closeContextMenu()
    }

    private func openContextMenu(at point: CGPoint, job: QueueJob) {
        selectedID = job.id
        contextTarget = job
        contextPoint = point
        if reduceMotion {
            contextVisible = true
        } else {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.82)) { contextVisible = true }
        }
    }

    private func closeContextMenu() {
        guard contextVisible else { return }
        if reduceMotion {
            contextVisible = false
        } else {
            withAnimation(.easeOut(duration: 0.12)) { contextVisible = false }
        }
    }

    private func perform(_ action: StatusMenuAction, on job: QueueJob) {
        closeContextMenu()
        switch action {
        case .copy:
            let code = job.waybillCode.isEmpty ? job.id : job.waybillCode
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            showToast("已复制运单号 \(code)")
        case .reprint:
            model.retry(job: job)
            showToast("正在重新打印 \(job.receiverName)")
        case .export:
            if model.exportPDF(job: job) {
                showToast(model.lastActionOutput)
            } else if !model.lastActionOutput.isEmpty {
                showToast(model.lastActionOutput)
            }
        case .errorDetail:
            toggleError(job)
        case .delete:
            let code = job.waybillCode.isEmpty ? job.id : job.waybillCode
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                model.dismiss(job: job)
            }
            if selectedID == job.id { selectedID = nil }
            showToast("已删除任务 \(code)")
        }
    }

    private func toggleError(_ job: QueueJob) {
        if expandedErrorIDs.contains(job.id) {
            expandedErrorIDs.remove(job.id)
        } else {
            expandedErrorIDs.insert(job.id)
        }
    }

    private func showToast(_ message: String) {
        guard !message.isEmpty else { return }
        toastMessage = message
        toastVisible = true
        toastWorkItem?.cancel()
        let work = DispatchWorkItem {
            toastVisible = false
        }
        toastWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }
    // MARK: 键盘导航

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKey(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// 返回 true 表示已消费该键。
    private func handleKey(_ event: NSEvent) -> Bool {
        // Esc：关右键浮层
        if event.keyCode == 53 {
            if contextVisible { closeContextMenu(); return true }
            return false
        }
        let cmd = event.modifierFlags.contains(.command)
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c" where cmd:
            if let job = currentJob { perform(.copy, on: job); return true }
        case "p" where cmd:
            if let job = currentJob { perform(.reprint, on: job); return true }
        default:
            break
        }
        // ↑↓ 与 删除
        switch event.keyCode {
        case 126: moveSelection(-1); return true            // Up
        case 125: moveSelection(1); return true             // Down
        case 51, 117:                                       // Delete / Forward delete
            if let job = currentJob { perform(.delete, on: job); return true }
        default:
            break
        }
        return false
    }

    private var currentJob: QueueJob? {
        let list = visibleJobs
        guard let selectedID else { return list.first }
        return list.first { $0.id == selectedID } ?? list.first
    }

    private func moveSelection(_ delta: Int) {
        let list = visibleJobs
        guard !list.isEmpty else { return }
        let currentIndex = list.firstIndex { $0.id == selectedID } ?? -1
        let next = max(0, min(list.count - 1, currentIndex + delta))
        selectedID = list[next].id
        closeContextMenu()
    }
}
// MARK: - 服务状态指示圆点

/// 带光晕的服务状态圆点，过渡态时脉冲呼吸。
private struct StatusIndicatorDot: View {
    let color: Color
    let pulsing: Bool

    @State private var animate = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.35), lineWidth: 4)
                    .scaleEffect(animate ? 1.9 : 1)
                    .opacity(animate ? 0 : 0.7)
            )
            .shadow(color: color.opacity(0.6), radius: 3)
            .onAppear {
                guard pulsing else { return }
                withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { animate = true }
            }
    }
}

// MARK: - 分组标题

/// 可点击折叠的分组标题：三角指示 + 名称 + 计数徽章。
private struct GroupHeaderView: View {
    let group: QueueGroup
    let count: Int
    let collapsed: Bool
    let onToggle: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(StatusMenuStyle.labelTertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))

                Text(group.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StatusMenuStyle.groupHeaderText)
                    .kerning(0.3)
                    .textCase(.uppercase)

                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(group.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(group.accent.opacity(0.14), in: Capsule())

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(hovering ? StatusMenuStyle.hoverBackground : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(group.title)，\(count) 个任务，\(collapsed ? "已折叠" : "已展开")")
    }
}
// MARK: - 队列卡片

struct QueueItemView: View {
    let job: QueueJob
    let isSelected: Bool
    let errorExpanded: Bool
    let relativeTime: String?
    let onTap: () -> Void
    let onRightClick: (CGPoint) -> Void

    @State private var hovering = false

    private var isError: Bool { job.status == .failed }
    private var showsProgress: Bool { job.status == .printing }

    var body: some View {
        GeometryReader { geo in
            cardBody
                .background(
                    RightClickCatcher { local in
                        let origin = geo.frame(in: .named("popover")).origin
                        onRightClick(CGPoint(x: origin.x + local.x, y: origin.y + local.y))
                    }
                )
        }
        .frame(height: cardHeight)
    }

    private var cardHeight: CGFloat {
        var base: CGFloat = 60
        if showsProgress { base += 10 }
        if isError && errorExpanded { base += 38 }
        return base
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Text(job.waybillCode.isEmpty ? job.id : job.waybillCode)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(isSelected ? StatusMenuStyle.labelPrimary : StatusMenuStyle.labelSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                StatusPill(status: job.status)
            }

            HStack(spacing: 10) {
                Label {
                    Text(job.receiverName.isEmpty ? "—" : job.receiverName)
                } icon: {
                    Image(systemName: "person").font(.system(size: 10))
                }
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11))
                .foregroundStyle(StatusMenuStyle.labelSecondary)

                metadataDivider
                Text("× \(job.copies) 份").font(.system(size: 11)).foregroundStyle(StatusMenuStyle.labelSecondary)

                if let relativeTime {
                    metadataDivider
                    Text(relativeTime).font(.system(size: 11)).foregroundStyle(StatusMenuStyle.labelSecondary)
                }
                Spacer(minLength: 0)
            }
            .monospacedDigit()

            if showsProgress {
                QueueProgressBar(progress: job.progress)
            }

            if isError, errorExpanded, let error = job.errorMessage, !error.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 11))
                    Text(error).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(StatusMenuStyle.red)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StatusMenuStyle.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(cardBorderColor, lineWidth: isSelected ? 1 : 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var cardBackground: some ShapeStyle {
        if isSelected { return AnyShapeStyle(StatusMenuStyle.selectedBackground) }
        if isError { return AnyShapeStyle(StatusMenuStyle.errorSurface) }
        return AnyShapeStyle(StatusMenuStyle.cardSurface)
    }

    private var cardBorderColor: Color {
        if isSelected { return StatusMenuStyle.blue }
        if isError { return StatusMenuStyle.errorBorder }
        return hovering ? StatusMenuStyle.cardBorderHover : StatusMenuStyle.cardBorder
    }

    private var metadataDivider: some View {
        Circle().fill(StatusMenuStyle.labelTertiary).frame(width: 2.5, height: 2.5)
    }

    private var accessibilityText: String {
        let code = job.waybillCode.isEmpty ? job.id : job.waybillCode
        return "运单 \(code)，收件人 \(job.receiverName)，\(job.copies) 份，\(job.status.badgeText)"
    }
}

// MARK: - 进度条

/// 打印中任务的细进度条。progress<=0 时退化为不确定态的轻微流光，否则显示确定进度。
private struct QueueProgressBar: View {
    let progress: Double

    @State private var sweep = false

    private var determinate: Bool { progress > 0.001 }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(StatusMenuStyle.progressTrack)
                if determinate {
                    Capsule()
                        .fill(StatusMenuStyle.blue)
                        .frame(width: max(4, width * CGFloat(min(1, progress))))
                        .animation(.easeInOut(duration: 0.3), value: progress)
                } else {
                    Capsule()
                        .fill(StatusMenuStyle.blue)
                        .frame(width: width * 0.35)
                        .offset(x: sweep ? width * 0.65 : -width * 0.35)
                }
            }
        }
        .frame(height: 3)
        .onAppear {
            guard !determinate else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { sweep = true }
        }
    }
}
// MARK: - 状态药丸徽章

private struct StatusPill: View {
    let status: QueueJobStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.badgeSymbol).font(.system(size: 8, weight: .bold))
            Text(status.badgeText)
        }
        .font(.system(size: 9, weight: .semibold))
        .kerning(0.4)
        .textCase(.uppercase)
        .foregroundStyle(status.badgeColor)
        .padding(.leading, 5)
        .padding(.trailing, 7)
        .padding(.vertical, 3)
        .background(status.badgeColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

// MARK: - 骨架卡

private struct SkeletonItemView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SkeletonBar(width: 120)
                Spacer()
                SkeletonBar(width: 44)
            }
            SkeletonBar(width: 160)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StatusMenuStyle.cardSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(StatusMenuStyle.cardBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SkeletonBar: View {
    let width: CGFloat
    @State private var shimmer = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(StatusMenuStyle.skeletonBase)
            .frame(width: width, height: 11)
            .overlay(
                LinearGradient(
                    colors: [.clear, StatusMenuStyle.skeletonShine, .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: width * 0.5)
                .offset(x: shimmer ? width : -width)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .onAppear {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) { shimmer = true }
            }
    }
}

// MARK: - 底部菜单项

private struct MenuFooterItem: View {
    let symbol: String
    let title: String
    let shortcut: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(StatusMenuStyle.labelSecondary)
                    .frame(width: 16)
                Text(title).font(.system(size: 13)).foregroundStyle(StatusMenuStyle.labelPrimary)
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut).font(.system(size: 12)).foregroundStyle(StatusMenuStyle.labelTertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(hovering ? StatusMenuStyle.hoverBackground : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
// MARK: - 右键上下文菜单

private struct StatusContextMenu: View {
    let isFailed: Bool
    let canExport: Bool
    let reduceMotion: Bool
    let onAction: (StatusMenuAction) -> Void

    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            ContextItem(symbol: "doc.on.doc", title: "复制运单号", shortcut: "⌘C") { onAction(.copy) }
            ContextItem(symbol: "printer", title: "重新打印", shortcut: "⌘P") { onAction(.reprint) }
            ContextItem(symbol: "arrow.down.doc", title: "导出 PDF", shortcut: nil, disabled: !canExport) { onAction(.export) }
            if isFailed {
                ContextItem(symbol: "exclamationmark.circle", title: "查看错误详情", shortcut: nil) { onAction(.errorDetail) }
            }
            Divider().overlay(StatusMenuStyle.separator).padding(.vertical, 4)
            ContextItem(symbol: "trash", title: "删除任务", shortcut: "⌫", destructive: true) { onAction(.delete) }
        }
        .padding(.vertical, 4)
        .frame(width: 206)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(StatusMenuStyle.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.26), radius: 12, y: 6)
        .scaleEffect(shown || reduceMotion ? 1 : 0.95, anchor: .topLeading)
        .opacity(shown || reduceMotion ? 1 : 0)
        .onAppear {
            if reduceMotion { shown = true }
            else { withAnimation(.spring(response: 0.18, dampingFraction: 0.82)) { shown = true } }
        }
    }
}

private struct ContextItem: View {
    let symbol: String
    let title: String
    let shortcut: String?
    var disabled: Bool = false
    var destructive: Bool = false
    let action: () -> Void

    @State private var hovering = false

    private var tint: Color { destructive ? StatusMenuStyle.red : StatusMenuStyle.labelPrimary }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 14)
                Text(title).font(.system(size: 13))
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut).font(.system(size: 12)).opacity(0.5)
                }
            }
            .foregroundStyle(hovering && !disabled ? .white : tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background((hovering && !disabled ? (destructive ? StatusMenuStyle.red : StatusMenuStyle.blue) : .clear))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { hovering = $0 }
    }
}

// MARK: - 右键捕获（自绘菜单需要拿到点击位置）

/// 透明 NSView，捕获 rightMouseDown 并回调命中点（已转换为视图本地、左上原点坐标）。
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onRightClick = onRightClick
    }

    final class CatcherView: NSView {
        var onRightClick: ((CGPoint) -> Void)?
        override var isFlipped: Bool { true }
        override func rightMouseDown(with event: NSEvent) {
            let local = convert(event.locationInWindow, from: nil)
            onRightClick?(CGPoint(x: local.x, y: local.y))
        }
    }
}
#if DEBUG
@MainActor
private func previewActions() -> StatusBarPopoverActions {
    StatusBarPopoverActions(openMainWindow: {}, openPreferences: {}, quit: {})
}

#Preview("默认队列") {
    let model = PreviewSamples.model(.busyQueue)
    model.hasLoadedOnce = true
    return StatusBarPopoverView(model: model, actions: previewActions())
}

#Preview("队列为空") {
    let model = PreviewSamples.model(.stoppedEmpty)
    model.hasLoadedOnce = true
    return StatusBarPopoverView(model: model, actions: previewActions())
}

#Preview("加载骨架") {
    let model = PreviewSamples.model(.stoppedEmpty)
    model.hasLoadedOnce = false
    return StatusBarPopoverView(model: model, actions: previewActions())
}
#endif












