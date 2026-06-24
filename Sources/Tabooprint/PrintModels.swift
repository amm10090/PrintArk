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
    case dryRun = "模拟打印"
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
