import PDFKit
import SwiftUI

struct LabelPreviewWorkspace: View {
    let pdfURL: URL?

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            VStack(spacing: 18) {
                PreviewHeader(pdfURL: pdfURL)

                ScrollView {
                    VStack(spacing: 18) {
                        if let pdfURL {
                            WaybillPDFCanvas(url: pdfURL)
                        } else {
                            EmptyPreviewState()
                        }

                        TechnicalSpecStrip()
                    }
                    .padding(.vertical, 24)
                }
            }
            .padding(24)
        }
        .navigationTitle("面单预览")
    }
}

struct PreviewHeader: View {
    let pdfURL: URL?

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(WaybillLabelSpec.sizeText) 面单预览")
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

    var body: some View {
        PDFPreviewView(url: url)
            .frame(width: 370, height: 630)
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
        guard context.coordinator.currentURL != url else {
            view.autoScales = true
            return
        }

        view.document = PDFDocument(url: url)
        view.autoScales = true
        context.coordinator.currentURL = url
    }

    final class Coordinator {
        var currentURL: URL?
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
            InfoLine(label: "订单号", value: document.orderID)
            InfoLine(label: "买家昵称", value: document.buyerNick)
            InfoLine(label: "买家备注", value: document.buyerMemo)
            InfoLine(label: "卖家备注", value: document.sellerMemo)
        }
        .padding(.vertical, 12)
    }
}

struct InfoLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(Color.black.opacity(0.58))
                .frame(width: 56, alignment: .leading)

            Text(value.isEmpty ? "-" : value)
                .font(.caption)
                .lineLimit(1)

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
    var body: some View {
        HStack(spacing: 10) {
            TechnicalSpecItem(title: "标签尺寸", value: WaybillLabelSpec.sizeText)
            TechnicalSpecItem(title: "渲染尺寸", value: WaybillLabelSpec.renderSizeText)
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
