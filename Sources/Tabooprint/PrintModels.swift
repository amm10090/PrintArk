import Foundation
import SwiftUI

enum WaybillLabelSpec {
    static let sizeText = "74 × 126 mm"
    static let renderSizeText = "592 × 1008 px"
    static let dpiText = "≈203 DPI"
    static let pixelsPerMillimeterText = "8"
    static let qrCodeText = "预留，未实现"
}

enum PrintMode: String, CaseIterable, Identifiable {
    case dryRun = "Dry-run"
    case realPrint = "真实打印"

    var id: String { rawValue }

    var isDryRun: Bool {
        self == .dryRun
    }

    init(dryRun: Bool) {
        self = dryRun ? .dryRun : .realPrint
    }
}

enum PrintJobStatus: String {
    case pending = "待打印"
    case dryRun = "Dry-run"
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

struct PrintJob: Identifiable {
    let id: String
    let waybillCode: String
    let printerName: String
    let pdfPath: String
    let status: PrintJobStatus
    let errorMessage: String?
    let commandText: String?
}

extension WaybillDocument {
    static let sample = WaybillDocument(
        waybillCode: "YT1234567890123",
        documentID: "DOC-20260624-0001",
        receiverName: "李明",
        receiverPhone: "138****2468",
        receiverAddress: "浙江省杭州市余杭区文一西路 969 号未来科技城 3 号楼 1206",
        senderName: "淘宝商家",
        senderPhone: "0571****8888",
        senderAddress: "浙江省杭州市滨江区网商路 699 号",
        sortingCode: "杭A-07",
        consolidationInfo: "杭州集包",
        blockCode: "HZ-XN-03",
        packageIndexText: "第 1/1 个",
        itemInfo: "蓝牙标签打印机配件套装",
        itemTotalCount: "1",
        orderID: "ORDER-883920194",
        buyerNick: "mango_2026",
        buyerMemo: "请尽快发货",
        sellerMemo: "已核对地址",
        printedAt: .now
    )
}
