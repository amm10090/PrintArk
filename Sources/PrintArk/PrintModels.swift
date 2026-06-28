import Foundation
import SwiftUI

enum WaybillLabelSpec {
    static let sizeText = "74 × 126 mm"
    static let renderSizeText = "592 × 1008 px"
    static let dpiText = "≈203 DPI"
    static let pixelsPerMillimeterText = "8"
    static let qrCodeText = "预留，未实现"
}

/// 面单内容原生绘制尺寸。无论选择哪种纸张，模板内容都按这个盒子绘制，
/// 再放入所选纸张外框（水平居中、垂直顶部对齐）。
enum WaybillContentBox {
    static let widthMM: CGFloat = 74
    static let heightMM: CGFloat = 126
}

/// 单台打印机的校准设置：mm 偏移、旋转角度、缩放、自适应纸张。
/// 按打印机名分别持久化（见 AppModel.printerCalibrations），切换打印机时自动加载。
struct PrinterCalibration: Codable, Equatable {
    /// 水平偏移（mm，+ 向右）。
    var offsetXMM: Double = 0
    /// 垂直偏移（mm，+ 向下，页面方向）。
    var offsetYMM: Double = 0
    /// 旋转角度，预设 0/90/180/270/360。
    var rotationDegrees: Int = 0
    /// 缩放比例，默认 1.0。
    var scaleRatio: Double = 1.0
    /// 自适应纸张：开启后按内容足迹自动选纸，而非手选纸张尺寸。
    var adaptivePaper: Bool = false

    static let identity = PrinterCalibration()

    /// 出厂默认校准：偏移/旋转/缩放保持基线（与 identity 相同），仅自适应纸张默认开启。
    /// 用于「某打印机尚无校准记录」时的初始回退值；不替换 identity 的增量预览基线语义。
    static let factoryDefault = PrinterCalibration(adaptivePaper: true)
}

/// 自适应纸张时的内容足迹尺寸（mm）：74×126 内容盒经旋转交换长短边、再乘缩放。
/// 渲染 mediaBox、lpr media 字符串、dedupe key 三处共用，确保一致。
func adaptiveFootprintMM(rotationDegrees: Int, scaleRatio: Double) -> (w: Double, h: Double) {
    let swap = (rotationDegrees % 180 == 90)
    let w = (swap ? WaybillContentBox.heightMM : WaybillContentBox.widthMM) * CGFloat(scaleRatio)
    let h = (swap ? WaybillContentBox.widthMM : WaybillContentBox.heightMM) * CGFloat(scaleRatio)
    return (Double(w), Double(h))
}

/// 纸张/面单尺寸的单一数据源。UI 选择、预览外框、PDF mediaBox 均从这里取值。
struct PaperSize: Identifiable, Hashable {
    enum Group: String, CaseIterable, Identifiable {
        case waybill = "标准面单"
        case paper = "通用纸张"

        var id: String { rawValue }
    }

    /// 稳定标识，等于持久化的 `media` 字符串，用于匹配旧值。
    let id: String
    /// 下拉项展示名。
    let displayName: String
    /// 传给 `lpr -o media=` 的值。
    let media: String
    let widthMM: CGFloat
    let heightMM: CGFloat
    let group: Group

    var aspectRatio: CGFloat { widthMM / heightMM }

    var sizeText: String {
        "\(PaperSize.trim(widthMM)) × \(PaperSize.trim(heightMM)) mm"
    }

    private static func trim(_ value: CGFloat) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }
}

enum PaperCatalog {
    /// 标准面单（热敏标签，常见快递）+ 通用纸张（CUPS 标准媒体名）。
    static let all: [PaperSize] = [
        PaperSize(id: "100x180mm", displayName: "100 × 180 mm 面单", media: "100x180mm", widthMM: 100, heightMM: 180, group: .waybill),
        PaperSize(id: "100x150mm", displayName: "100 × 150 mm 面单", media: "100x150mm", widthMM: 100, heightMM: 150, group: .waybill),
        PaperSize(id: "100x100mm", displayName: "100 × 100 mm 面单", media: "100x100mm", widthMM: 100, heightMM: 100, group: .waybill),
        PaperSize(id: "76x130mm", displayName: "76 × 130 mm 面单", media: "76x130mm", widthMM: 76, heightMM: 130, group: .waybill),
        PaperSize(id: "74x126mm", displayName: "74 × 126 mm 面单（原生模板）", media: "74x126mm", widthMM: 74, heightMM: 126, group: .waybill),
        PaperSize(id: "A4", displayName: "A4（210 × 297 mm）", media: "A4", widthMM: 210, heightMM: 297, group: .paper),
        PaperSize(id: "A5", displayName: "A5（148 × 210 mm）", media: "A5", widthMM: 148, heightMM: 210, group: .paper),
        PaperSize(id: "A6", displayName: "A6（105 × 148 mm）", media: "A6", widthMM: 105, heightMM: 148, group: .paper),
        PaperSize(id: "Letter", displayName: "Letter（216 × 279 mm）", media: "Letter", widthMM: 215.9, heightMM: 279.4, group: .paper),
    ]

    static let `default`: PaperSize = all.first { $0.id == "100x180mm" } ?? all[0]

    /// 将持久化的 `media` 字符串映射回 `PaperSize`；未知值回退到默认项。
    static func match(media: String) -> PaperSize {
        let trimmed = media.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = all.first(where: { $0.media == trimmed || $0.id == trimmed }) {
            return exact
        }
        let lowered = trimmed.lowercased()
        if let caseInsensitive = all.first(where: { $0.media.lowercased() == lowered }) {
            return caseInsensitive
        }
        return `default`
    }

    static func grouped(_ group: PaperSize.Group) -> [PaperSize] {
        all.filter { $0.group == group }
    }
}

enum PrintJobStatus: String {
    case pending = "待打印"
    case dryRun = "模拟打印"
    case submitted = "已提交"
    case skippedDuplicate = "已跳过重复"
    case failed = "失败"

    var color: Color {
        switch self {
        case .pending:
            return .orange
        case .dryRun:
            return .blue
        case .submitted:
            return .green
        case .skippedDuplicate:
            return .secondary
        case .failed:
            return .red
        }
    }

    var systemImage: String {
        switch self {
        case .pending:
            return "clock"
        case .dryRun:
            return "doc.text.magnifyingglass"
        case .submitted:
            return "checkmark.circle.fill"
        case .skippedDuplicate:
            return "arrow.triangle.2.circlepath.circle"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }
}

struct PrinterDevice: Identifiable, Hashable {
    let name: String
    let isDefault: Bool
    let isEnabled: Bool

    var id: String { name }

    var displayName: String {
        if isDefault {
            return "\(name) · 默认"
        }
        return name
    }

    static let fallback = PrinterDevice(name: "TAOBAO", isDefault: true, isEnabled: true)
}

struct WaybillDocument: Identifiable {
    let id = UUID()

    var waybillCode: String
    var documentID: String

    var receiverName: String
    var receiverPhone: String
    var receiverAddress: String

    var senderName: String
    var senderPhone: String
    var senderAddress: String

    var sortingCode: String
    var consolidationInfo: String
    var blockCode: String

    var packageIndexText: String
    var itemInfo: String
    var itemTotalCount: String
    var orderID: String
    var buyerNick: String
    var buyerMemo: String
    var sellerMemo: String

    var printedAt: Date
}

/// 单个文档（一张运单）的真实展示数据。卡片按文档粒度展开，每张卡消费一个 QueueDocument。
/// 合规约定：waybillCode / receiverName / 省市区写进结构化事件日志（可重启恢复）；
/// receiverPhone 不落盘，仅在 snapshot() 从进程内存缓存按 key 注入。
struct QueueDocument: Equatable {
    let waybillCode: String
    let receiverName: String
    var receiverPhone: String
    let province: String
    let city: String
    let district: String

    init(
        waybillCode: String,
        receiverName: String,
        receiverPhone: String = "",
        province: String,
        city: String,
        district: String
    ) {
        self.waybillCode = waybillCode
        self.receiverName = receiverName
        self.receiverPhone = receiverPhone
        self.province = province
        self.city = city
        self.district = district
    }

    var regionText: String { province + city + district }
}

struct PrintJob: Identifiable {
    let id: String
    let waybillCode: String
    let printerName: String
    let pdfPath: String
    let status: PrintJobStatus
    let errorMessage: String?
    let commandText: String?
    /// 文档级真实数据（运单号/收件人/地区）。无真实数据（旧日志/示例）时为空，下游回退占位。
    var documents: [QueueDocument] = []
    /// 事件日志里的原始时间戳字符串（格式 `yyyy-MM-dd HH:mm:ss.SSS`）。解析失败/缺失为空，下游回退。
    var createdAtText: String = ""
}

extension WaybillDocument {
    static let sample = WaybillDocument(
        waybillCode: "90000000000001",
        documentID: "DEMO-DOC-0001",
        receiverName: "演示收件人",
        receiverPhone: "188****0001",
        receiverAddress: "示例省示例市示例区演示街道 100 号虚拟收货地址",
        senderName: "演示寄件人",
        senderPhone: "199****0002",
        senderAddress: "示例省样板市样板区测试路 200 号虚拟发货仓",
        sortingCode: "DEMO-A01",
        consolidationInfo: "演示集包地",
        blockCode: "演示路由",
        packageIndexText: "第 1/1 个",
        itemInfo: "演示商品 A；虚拟规格 B；样例配件套装",
        itemTotalCount: "2 件",
        orderID: "DEMO-ORDER-20260625-0001",
        buyerNick: "demo_buyer",
        buyerMemo: "演示买家备注",
        sellerMemo: "演示卖家备注",
        printedAt: .now
    )
}
