import CryptoSwift
import PDFKit
import SwiftUI

struct LabelPreviewWorkspace: View {
    let pdfURL: URL?
    @ObservedObject var model: AppModel

    @AppStorage(SettingsKeys.printMedia) private var printMedia = "100x180mm"
    @AppStorage(SettingsKeys.printHideTaoLogo) private var hideTaoLogo = false
    @AppStorage(SettingsKeys.printHideCourierPackage) private var hideCourierPackage = false
    @AppStorage(SettingsKeys.printerName) private var printerName = "TAOBAO"
    @State private var samplePDFURL: URL?

    private var calibration: PrinterCalibration {
        model.printerCalibrations[printerName] ?? .identity
    }

    /// 预览外框尺寸：自适应纸张时按内容足迹，否则用手选纸张。
    private var paperSize: PaperSize {
        let cal = calibration
        guard cal.adaptivePaper else { return PaperCatalog.match(media: printMedia) }
        let f = adaptiveFootprintMM(rotationDegrees: cal.rotationDegrees, scaleRatio: cal.scaleRatio)
        return PaperSize(id: "adaptive", displayName: "自适应", media: "", widthMM: CGFloat(f.w), heightMM: CGFloat(f.h), group: .waybill)
    }

    private var displayURL: URL {
        pdfURL ?? samplePDFURL ?? Self.placeholderSampleURL
    }

    private static let placeholderSampleURL: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tabooprint-placeholder.pdf")
        let w: CGFloat = 370, h: CGFloat = 630
        var mediaBox = CGRect(x: 0, y: 0, width: w, height: h)
        if let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor.white)
            ctx.fill(mediaBox)
            let font = NSFont.systemFont(ofSize: 14)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let text = "样本面单加载中…"
            let textSize = text.size(withAttributes: attrs)
            let x = (w - textSize.width) / 2
            let y = (h - textSize.height) / 2
            text.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
            ctx.endPDFPage()
            ctx.closePDF()
        }
        return url
    }()

    @MainActor
    private func generateSamplePDF() -> URL {
        (try? WaybillPreviewSamplePDF.writeSample(hideTaoLogo: hideTaoLogo, hideCourierPackage: hideCourierPackage, paperSize: paperSize, calibration: calibration)) ?? Self.placeholderSampleURL
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            VStack(spacing: 18) {
                PreviewHeader(pdfURL: displayURL, paperSize: paperSize)

                TechnicalSpecStrip(paperSize: paperSize)

                GeometryReader { proxy in
                    let previewSize = WaybillPreviewLayout.fittedPDFSize(in: proxy.size, aspectRatio: paperSize.aspectRatio)

                    WaybillPDFCanvas(url: displayURL, size: previewSize)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(24)
        }
        .navigationTitle("面单预览")
        .onAppear {
            guard pdfURL == nil, samplePDFURL == nil else { return }
            samplePDFURL = generateSamplePDF()
        }
        .onChange(of: hideTaoLogo) { _ in regenerateSampleIfNeeded() }
        .onChange(of: hideCourierPackage) { _ in regenerateSampleIfNeeded() }
        .onChange(of: printMedia) { _ in regenerateSampleIfNeeded() }
        .onChange(of: printerName) { _ in regenerateSampleIfNeeded() }
        .onChange(of: calibration) { _ in regenerateSampleIfNeeded() }
    }

    /// 仅当展示样本面单（无真实任务 PDF）时，按当前设置重绘样本。
    private func regenerateSampleIfNeeded() {
        guard pdfURL == nil else { return }
        samplePDFURL = generateSamplePDF()
    }
}

enum WaybillPreviewLayout {
    static let maxPDFSize = CGSize(width: 370, height: 630)

    static func fittedPDFSize(in availableSize: CGSize, aspectRatio: CGFloat) -> CGSize {
        let ratio = aspectRatio > 0 ? aspectRatio : (74 / 126)
        let maxWidth = min(maxPDFSize.width, max(0, availableSize.width - 24))
        let maxHeight = min(maxPDFSize.height, max(0, availableSize.height - 6))
        let height = min(maxHeight, maxWidth / ratio)
        return CGSize(width: height * ratio, height: height)
    }
}

enum WaybillPreviewSamplePDF {
    private static let requestID = "SAMPLE_PREVIEW"
    private static let taskID = "tabooprint-sample"
    private static let sampleDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tabooprint", isDirectory: true)
        .appendingPathComponent("preview-samples", isDirectory: true)

    static func writeSample(to outputDirectory: URL = sampleDirectory, hideTaoLogo: Bool = false, hideCourierPackage: Bool = false, paperSize: PaperSize = PaperCatalog.default, calibration: PrinterCalibration = .identity) throws -> URL {
        let renderer = NativeWaybillRenderer()
        // 文件名随所有影响渲染的输入变化，确保 URL 改变后 PDFView 一定重新加载。
        let calToken = "\(Int((calibration.offsetXMM * 10).rounded()))_\(Int((calibration.offsetYMM * 10).rounded()))_\(calibration.rotationDegrees)_\(Int((calibration.scaleRatio * 100).rounded()))_\(calibration.adaptivePaper ? "a" : "f")"
        let variantTaskID = "\(taskID)-\(hideTaoLogo ? "1" : "0")\(hideCourierPackage ? "1" : "0")-\(paperSize.id)-\(calToken)"
        let result = try renderer.render(
            payload: try samplePayload(for: .sample),
            outputDirectory: outputDirectory,
            requestID: requestID,
            taskID: variantTaskID,
            paperSize: paperSize,
            hideTaoLogo: hideTaoLogo,
            hideCourierPackage: hideCourierPackage,
            calibration: calibration
        )
        return result.url
    }

    static func samplePayload(for document: WaybillDocument) throws -> [String: JSONValue] {
        let standard = sampleStandardData(for: document)
        let custom = sampleCustomData(for: document)

        return [
            "cmd": .string("print"),
            "requestID": .string(requestID),
            "task": .object([
                "taskID": .string(taskID),
                "printer": .string("TAOBAO"),
                "preview": .bool(true),
                "documents": .array([
                    .object([
                        "documentID": .string(document.documentID),
                        "contents": .array([
                            .object([
                                "ver": .string("waybill_print_secret_version_1"),
                                "encryptedData": .string(try encryptedStandardData(standard)),
                                "templateURL": .string("https://cloudprint.cainiao.com/template/standard/300336/92"),
                            ]),
                            .object([
                                "data": .object(custom),
                                "templateURL": .string("https://cloudprint.cainiao.com/template/customArea/73159162/10"),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ]
    }

    private static func sampleStandardData(for document: WaybillDocument) -> [String: JSONValue] {
        [
            "waybillCode": .string(document.waybillCode),
            "routingInfo": .object([
                "routeCode": .string("演示路由"),
                "newBlockCode": .string(document.blockCode),
                "blockCode": .string(document.blockCode),
                "sortation": .object([
                    "name": .string(document.sortingCode),
                ]),
                "consolidation": .object([
                    "name": .string(document.consolidationInfo),
                ]),
            ]),
            "recipient": .object([
                "name": .string(document.receiverName),
                "mobile": .string(document.receiverPhone),
                "phone": .string(document.receiverPhone),
                "secretConsigneeMobile": .string(""),
                "address": .object([
                    "province": .string("示例省"),
                    "city": .string("示例市"),
                    "district": .string("示例区"),
                    "town": .string("演示街道"),
                    "detail": .string("100 号虚拟收货地址"),
                ]),
            ]),
            "sender": .object([
                "name": .string(document.senderName),
                "mobile": .string(document.senderPhone),
                "phone": .string(document.senderPhone),
                "address": .object([
                    "province": .string("示例省"),
                    "city": .string("样板市"),
                    "district": .string("样板区"),
                    "town": .string("测试路"),
                    "detail": .string("200 号虚拟发货仓"),
                ]),
            ]),
            "extraInfo": .object([
                "staDoorHome": .string("false"),
            ]),
        ]
    }

    private static func sampleCustomData(for document: WaybillDocument) -> [String: JSONValue] {
        [
            "WAIBILLNO_BAR_CODE": .string(document.waybillCode),
            "ITEM_INFO": .string(document.itemInfo),
            "ITEM_TOTAL_COUNT": .string(document.itemTotalCount),
            "ORDER_ID": .string(document.orderID),
            "BUYER_MEMO": .string(document.buyerMemo),
            "SELLER_MEMO": .string(document.sellerMemo),
            "PAGE_PRINT_TIPS": .string("演示打印备注"),
            "showItemInfo": .bool(true),
            "itemInfoFontSize": .string("10"),
        ]
    }

    private static func encryptedStandardData(_ standard: [String: JSONValue]) throws -> String {
        let payload = try JSONValue.object(standard).encodedData()
        let key: [UInt8] = [0xCD, 0xBF, 0xFD, 0x0A, 0xC5, 0x9D, 0xE5, 0x6D, 0x3F, 0x17, 0xF9, 0x3A, 0x7E, 0xED, 0xFF, 0x57]
        let aes = try AES(key: key, blockMode: ECB(), padding: .pkcs7)
        let encrypted = try aes.encrypt(Array(payload))
        return "AES:" + Data(encrypted).base64EncodedString()
    }
}

struct PreviewHeader: View {
    let pdfURL: URL?
    let paperSize: PaperSize

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(paperSize.sizeText) 面单预览")
                    .font(.title2.weight(.semibold))

                Text(pdfURL?.lastPathComponent ?? "暂无预览 PDF")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                SpecPill(text: "竖向")
                SpecPill(text: "PDF")
                SpecPill(text: "fit-to-page")
            }
        }
    }
}

struct SpecPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
    }
}

struct WaybillPDFCanvas: View {
    let url: URL
    var size = WaybillPreviewLayout.maxPDFSize

    var body: some View {
        PDFPreviewView(url: url)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.black.opacity(0.06))
            }
            .shadow(color: .black.opacity(0.16), radius: 32, x: 0, y: 18)
    }
}

struct EmptyPreviewState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("暂无预览 PDF")
                .font(.headline.weight(.semibold))

            Text("收到打印 payload 后会显示最新面单。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(width: 370, height: 630)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(0.06))
        }
    }
}

struct PDFPreviewView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePage
        view.displayDirection = .vertical
        view.displaysPageBreaks = false
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        let signature = PDFFileSignature(url: url)
        guard context.coordinator.currentURL != url || context.coordinator.currentSignature != signature else {
            view.autoScales = true
            return
        }

        view.document = PDFDocument(url: url)
        view.autoScales = true
        context.coordinator.currentURL = url
        context.coordinator.currentSignature = signature
    }

    final class Coordinator {
        var currentURL: URL?
        var currentSignature: PDFFileSignature?
    }
}

struct PDFFileSignature: Equatable {
    let modificationDate: Date?
    let fileSize: Int64?

    init(url: URL) {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        modificationDate = values?.contentModificationDate
        fileSize = values?.fileSize.map(Int64.init)
    }
}

struct WaybillCanvas: View {
    let document: WaybillDocument

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.16), radius: 32, x: 0, y: 18)

            VStack(spacing: 0) {
                HeaderBlock(document: document)

                Divider()

                ReceiverBlock(document: document)

                Divider()

                RouteBlock(document: document)

                Divider()

                ItemBlock(document: document)

                Spacer(minLength: 0)

                BottomBarcodeBlock(document: document)
            }
            .padding(18)
            .foregroundStyle(Color.black)
            .tint(Color.black)

            RotatedWaybillText(text: document.waybillCode)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            RotatedWaybillText(text: document.waybillCode)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .frame(width: 370, height: 630)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(0.06))
        }
        .environment(\.colorScheme, .light)
    }
}

struct HeaderBlock: View {
    let document: WaybillDocument

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("电子面单")
                        .font(.headline.weight(.semibold))

                    Text("打印时间 \(document.printedAt.formatted(date: .numeric, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(Color.black.opacity(0.58))
                }

                Spacer()

                Text(document.packageIndexText)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.06), in: Capsule())
            }

            MainBarcodeView(code: document.waybillCode)

            Text(document.waybillCode)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
        }
        .padding(.bottom, 12)
    }
}

struct ReceiverBlock: View {
    let document: WaybillDocument

    var body: some View {
        VStack(spacing: 10) {
            AddressRow(
                title: "收",
                name: document.receiverName,
                phone: document.receiverPhone,
                address: document.receiverAddress
            )

            AddressRow(
                title: "寄",
                name: document.senderName,
                phone: document.senderPhone,
                address: document.senderAddress
            )
        }
        .padding(.vertical, 12)
    }
}

struct AddressRow: View {
    let title: String
    let name: String
    let phone: String
    let address: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.title3.weight(.bold))
                .frame(width: 28, height: 28)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))

                    Text(phone)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.black.opacity(0.58))
                }

                Text(address)
                    .font(.caption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }
}

struct RouteBlock: View {
    let document: WaybillDocument

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("大头笔 / 分拣码")
                    .font(.caption2)
                    .foregroundStyle(Color.black.opacity(0.58))

                Text(document.sortingCode)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 5) {
                Text("集包地")
                    .font(.caption2)
                    .foregroundStyle(Color.black.opacity(0.58))

                Text(document.consolidationInfo)
                    .font(.caption.weight(.semibold))

                Text("路由码 \(document.blockCode)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.black.opacity(0.58))
            }
        }
        .padding(.vertical, 12)
    }
}

struct ItemBlock: View {
    let document: WaybillDocument

    var body: some View {
        VStack(spacing: 7) {
            InfoLine(label: "商品信息", value: document.itemInfo)
            InfoLine(label: "商品数量", value: document.itemTotalCount)
            InfoLine(label: "买家昵称", value: document.buyerNick)
            InfoLine(label: "买家备注", value: document.buyerMemo, lineLimit: nil)
            InfoLine(label: "卖家备注", value: document.sellerMemo, lineLimit: nil)
        }
        .padding(.vertical, 12)
    }
}

struct InfoLine: View {
    let label: String
    let value: String
    var lineLimit: Int? = 1

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(Color.black.opacity(0.58))
                .frame(width: 56, alignment: .leading)
                .padding(.top, 1)

            Text(value.isEmpty ? "-" : value)
                .font(.caption)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }
}

struct BottomBarcodeBlock: View {
    let document: WaybillDocument

    var body: some View {
        VStack(spacing: 5) {
            SmallBarcodeView(code: document.waybillCode)
                .frame(height: 34)

            Text(document.waybillCode)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.black.opacity(0.58))
        }
        .padding(.top, 10)
    }
}

struct RotatedWaybillText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .foregroundStyle(Color.black.opacity(0.42))
            .rotationEffect(.degrees(-90))
            .padding(.horizontal, -26)
    }
}

struct MainBarcodeView: View {
    let code: String

    var body: some View {
        VStack(spacing: 6) {
            BarcodeBars()
                .frame(height: 58)

            Text("Code128 · 运单号主条码")
                .font(.caption2)
                .foregroundStyle(Color.black.opacity(0.58))
        }
        .accessibilityLabel("Code128 主条码，内容 \(code)")
    }
}

struct SmallBarcodeView: View {
    let code: String

    var body: some View {
        BarcodeBars()
            .accessibilityLabel("底部小条码，内容 \(code)")
    }
}

struct BarcodeBars: View {
    private let widths: [CGFloat] = [3, 5, 2, 7, 4, 2, 6, 3, 8, 2, 4, 6, 3, 2, 7, 5, 2, 4, 8, 3]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(widths.indices, id: \.self) { index in
                Rectangle()
                    .fill(Color.black.opacity(index.isMultiple(of: 4) ? 0.72 : 1))
                    .frame(width: widths[index])
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct TechnicalSpecStrip: View {
    let paperSize: PaperSize

    var body: some View {
        HStack(spacing: 10) {
            TechnicalSpecItem(title: "纸张外框", value: paperSize.sizeText)
            TechnicalSpecItem(title: "内容版面", value: WaybillLabelSpec.sizeText)
            TechnicalSpecItem(title: "渲染精度", value: WaybillLabelSpec.dpiText)
            TechnicalSpecItem(title: "PX_PER_MM", value: WaybillLabelSpec.pixelsPerMillimeterText)
            TechnicalSpecItem(title: "二维码", value: WaybillLabelSpec.qrCodeText)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct TechnicalSpecItem: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.caption.weight(.semibold))
        }
        .frame(minWidth: 96, alignment: .leading)
    }
}

#if DEBUG
struct LabelPreviewWorkspace_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            LabelPreviewWorkspace(pdfURL: nil, model: PreviewSamples.consoleModel)
                .frame(width: 760, height: 720)
                .previewDisplayName("预览工作台")

            WaybillCanvas(document: .sample)
                .padding(32)
                .background(Color(nsColor: .windowBackgroundColor))
                .previewDisplayName("面单画布")
        }
    }
}
#endif
