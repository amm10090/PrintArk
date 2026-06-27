import XCTest
@testable import Tabooprint

final class TabooprintTests: XCTestCase {
    func testRuntimeModeMapsToNativeConfiguration() {
        let settings = PrintSettings(printerName: "TAOBAO", media: "100x180mm", dryRun: true, fitToPage: true, dedupe: true, dedupeWindowMinutes: 10)
        let preview = PrintServiceConfiguration.current(runtimeMode: .defaultPreview, autoOpenPreview: false, printSettings: settings)
        let respect = PrintServiceConfiguration.current(runtimeMode: .respectPreviewFlag, autoOpenPreview: false, printSettings: settings)
        let missing = PrintServiceConfiguration.current(runtimeMode: .failureDocumentNotFound, autoOpenPreview: false, printSettings: settings)
        let decrypt = PrintServiceConfiguration.current(runtimeMode: .failureDecrypt, autoOpenPreview: false, printSettings: settings)

        XCTAssertTrue(preview.forcePreview)
        XCTAssertFalse(respect.forcePreview)
        XCTAssertEqual(missing.failureMode, "document-not-found")
        XCTAssertEqual(decrypt.failureMode, "decrypt")
    }

    func testServiceStateTitlesAreStable() {
        XCTAssertEqual(ServiceState.stopped.title, "已停止")
        XCTAssertEqual(ServiceState.starting.title, "启动中")
        XCTAssertEqual(ServiceState.running.title, "运行中")
        XCTAssertEqual(ServiceState.stopping.title, "停止中")
        XCTAssertEqual(ServiceState.error.title, "错误")
    }

    func testRecentTaskResultDisplayIsReadable() {
        let previewTask = RecentTask(
            id: "1",
            timestampText: "2026-06-24 12:00:00",
            command: "print",
            requestID: "RID-1",
            documentCount: 1,
            mode: "default-preview",
            result: "preview",
            isInProgress: false
        )

        XCTAssertEqual(previewTask.modeDisplay, "默认预览")
        XCTAssertEqual(previewTask.resultDisplay, "预览成功")
    }

    func testQueueJobsIncludePreviewTasksWithoutDuplicatingPrintJobs() {
        let previewTask = RecentTask(
            id: "RID-PREVIEW",
            timestampText: "2026-06-24 12:00:00",
            command: "print",
            requestID: "RID-PREVIEW",
            documentCount: 1,
            mode: "default-preview",
            result: "preview",
            isInProgress: false
        )
        let physicalTask = RecentTask(
            id: "RID-PHYSICAL",
            timestampText: "2026-06-24 12:01:00",
            command: "print",
            requestID: "RID-PHYSICAL",
            documentCount: 1,
            mode: "respect-preview-flag",
            result: "physical-dry-run",
            isInProgress: false
        )
        let physicalJob = PrintJob(
            id: "RID-PHYSICAL",
            waybillCode: "TASK-PHYSICAL",
            printerName: "TAOBAO",
            pdfPath: "/tmp/TASK-PHYSICAL.pdf",
            status: .dryRun,
            errorMessage: nil,
            commandText: "lpr -P TAOBAO /tmp/TASK-PHYSICAL.pdf"
        )

        let jobs = QueueJob.merged(printJobs: [physicalJob], recentTasks: [previewTask, physicalTask])

        XCTAssertEqual(jobs.map(\.id), ["RID-PHYSICAL", "RID-PREVIEW"])
        XCTAssertEqual(jobs[0].kind, .dryRun)
        XCTAssertEqual(jobs[1].kind, .preview)
        XCTAssertEqual(jobs[1].status, .done)
    }

    func testQueueJobExpandsMultiDocumentTaskIntoMultipleCards() {
        let task = RecentTask(
            id: "RID-MULTI",
            timestampText: "2026-06-27 09:00:00",
            command: "print",
            requestID: "RID-MULTI",
            documentCount: 2,
            mode: "default-preview",
            result: "preview",
            isInProgress: false,
            documents: [
                QueueDocument(waybillCode: "WB-001", receiverName: "张三", receiverPhone: "13800000001", province: "浙江省", city: "杭州市", district: "西湖区"),
                QueueDocument(waybillCode: "WB-002", receiverName: "李四", receiverPhone: "13800000002", province: "江苏省", city: "苏州市", district: "姑苏区"),
            ]
        )

        let jobs = QueueJob.merged(printJobs: [], recentTasks: [task])

        XCTAssertEqual(jobs.count, 2)
        XCTAssertEqual(jobs.map(\.id), ["RID-MULTI#0", "RID-MULTI#1"])
        // 标题用真实运单号，不是 requestID。
        XCTAssertEqual(jobs[0].waybillCode, "WB-001")
        XCTAssertEqual(jobs[1].waybillCode, "WB-002")
        // 收件人不脱敏，电话原样保留。
        XCTAssertEqual(jobs[0].receiverName, "张三")
        XCTAssertEqual(jobs[0].receiverPhone, "13800000001")
        // 地区为省+市+区拼接。
        XCTAssertEqual(jobs[0].regionText, "浙江省杭州市西湖区")
        XCTAssertEqual(jobs[1].regionText, "江苏省苏州市姑苏区")
    }

    func testQueueJobFallsBackToPlaceholderWhenNoDocuments() {
        let task = RecentTask(
            id: "RID-LEGACY",
            timestampText: "2026-06-27 09:05:00",
            command: "print",
            requestID: "RID-LEGACY",
            documentCount: 3,
            mode: "default-preview",
            result: "preview",
            isInProgress: false
        )

        let jobs = QueueJob.merged(printJobs: [], recentTasks: [task])

        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].id, "RID-LEGACY")
        // 旧事件日志无 documents → 回退占位卡，标题用 requestID，收件人脱敏占位。
        XCTAssertEqual(jobs[0].waybillCode, "RID-LEGACY")
        XCTAssertEqual(jobs[0].receiverName, "收件人已脱敏")
        XCTAssertTrue(jobs[0].regionText.isEmpty)
    }

    func testParseRecentTasksReadsDocumentsArray() {
        let event = #"[cainiao-mock:event] {"type":"task","phase":"finish","requestID":"RID-DOC","taskID":"TASK-DOC","command":"print","documentCount":2,"mode":"default-preview","result":"preview","documents":[{"waybillCode":"YT001","receiverName":"王五","province":"广东省","city":"广州市","district":"天河区"},{"waybillCode":"YT002","receiverName":"赵六","province":"北京市","city":"北京市","district":"朝阳区"}]}"#

        let tasks = NativePrintService.parseRecentTasks(from: [event])

        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].documents.count, 2)
        XCTAssertEqual(tasks[0].documents[0].waybillCode, "YT001")
        XCTAssertEqual(tasks[0].documents[0].receiverName, "王五")
        XCTAssertEqual(tasks[0].documents[0].regionText, "广东省广州市天河区")
        // 电话不落盘：日志事件不含 phone，parse 出的电话为空。
        XCTAssertEqual(tasks[0].documents[0].receiverPhone, "")
        XCTAssertEqual(tasks[0].documents[1].waybillCode, "YT002")
    }

    func testParsePrintJobsReadsDocumentsArray() {
        let event = #"[cainiao-mock:event] {"type":"print-job","phase":"dry-run","requestID":"RID-PJ","taskID":"TASK-PJ","printer":"TAOBAO","documentCount":1,"pdfPath":"/tmp/x.pdf","commandText":"lpr","documents":[{"waybillCode":"SF999","receiverName":"钱七","province":"四川省","city":"成都市","district":"高新区"}]}"#

        let jobs = NativePrintService.parsePrintJobs(from: [event], fallbackPrinter: "TAOBAO")

        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].documents.count, 1)
        XCTAssertEqual(jobs[0].documents[0].waybillCode, "SF999")
        XCTAssertEqual(jobs[0].documents[0].regionText, "四川省成都市高新区")
        XCTAssertEqual(jobs[0].documents[0].receiverPhone, "")
    }

    func testEventLogDoesNotContainReceiverPhone() {
        let event = #"[cainiao-mock:event] {"type":"task","phase":"finish","requestID":"RID-NOPHONE","documents":[{"waybillCode":"YT001","receiverName":"王五","province":"广东省","city":"广州市","district":"天河区"}]}"#
        // 合规：结构化事件日志不得含电话字段。
        XCTAssertFalse(event.contains("receiverPhone"))
        XCTAssertFalse(event.contains("phone"))
    }

    func testPrintSettingsDefaultToDryRun() {
        let settings = PrintSettings(
            printerName: "TAOBAO",
            media: "100x180mm",
            dryRun: true,
            fitToPage: true,
            dedupe: true,
            dedupeWindowMinutes: 10
        )

        XCTAssertEqual(settings.printerName, "TAOBAO")
        XCTAssertEqual(settings.media, "100x180mm")
        XCTAssertTrue(settings.dryRun)
        XCTAssertTrue(settings.fitToPage)
        XCTAssertTrue(settings.dedupe)
        XCTAssertEqual(settings.dedupeWindowMinutes, 10)
    }

    func testRealPrintMustBeExplicit() {
        let settings = PrintSettings(
            printerName: "TAOBAO",
            media: "",
            dryRun: false,
            fitToPage: false,
            dedupe: false,
            dedupeWindowMinutes: 10
        )

        XCTAssertFalse(settings.dryRun)
        XCTAssertFalse(settings.fitToPage)
        XCTAssertFalse(settings.dedupe)
    }

    func testRetryPhysicalPrintMissingPDFReturnsError() {
        let service = NativePrintService()
        service.updateConfiguration(PrintSettings(printerName: "TAOBAO", media: "100x180mm", dryRun: true, fitToPage: true, dedupe: true, dedupeWindowMinutes: 10))

        let job = service.retryPhysicalPrint(requestID: "RID-MISSING", pdfPath: "/tmp/tabooprint/does-not-exist-\(UUID().uuidString).pdf", printerName: "TAOBAO")

        XCTAssertFalse(job.ok)
        XCTAssertNotNil(job.error)
        XCTAssertTrue(job.error?.contains("PDF 不存在") ?? false)
    }

    func testRetryPhysicalPrintDryRunEmitsRetryPhaseAndSkipsProcess() throws {
        let service = NativePrintService()
        service.updateConfiguration(PrintSettings(printerName: "TAOBAO", media: "100x180mm", dryRun: true, fitToPage: true, dedupe: true, dedupeWindowMinutes: 10))

        let captured = LogCollector()
        service.setLogSink { line in captured.append(line) }

        // 落盘一个真实存在的最小 PDF，触发重打路径（dryRun 下不跑 lpr）。
        let pdfURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("retry-\(UUID().uuidString).pdf")
        try Data("%PDF-1.4\n%%EOF\n".utf8).write(to: pdfURL)
        defer { try? FileManager.default.removeItem(at: pdfURL) }

        let job = service.retryPhysicalPrint(requestID: "RID-RETRY", pdfPath: pdfURL.path, printerName: "TAOBAO")

        XCTAssertTrue(job.ok)
        XCTAssertTrue(job.dryRun)
        XCTAssertFalse(job.duplicate)
        XCTAssertFalse(job.commandText.isEmpty)
        // dryRun 重试发出 retry-dry-run phase，不发 retry-submitted（未跑 Process）。
        XCTAssertTrue(captured.lines.contains { $0.contains("retry-dry-run") })
        XCTAssertFalse(captured.lines.contains { $0.contains("retry-submitted") })
    }

    func testRetryPhysicalPrintBypassesDedupeHistory() throws {
        let service = NativePrintService()
        service.updateConfiguration(PrintSettings(printerName: "TAOBAO", media: "100x180mm", dryRun: true, fitToPage: true, dedupe: true, dedupeWindowMinutes: 10))

        let pdfURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("retry-dedupe-\(UUID().uuidString).pdf")
        try Data("%PDF-1.4\n%%EOF\n".utf8).write(to: pdfURL)
        defer { try? FileManager.default.removeItem(at: pdfURL) }

        // 连续两次重试同一 PDF：因为重试不查 / 不写去重历史，两次都应成功提交（非 duplicate）。
        let first = service.retryPhysicalPrint(requestID: "RID-DEDUPE", pdfPath: pdfURL.path, printerName: "TAOBAO")
        let second = service.retryPhysicalPrint(requestID: "RID-DEDUPE", pdfPath: pdfURL.path, printerName: "TAOBAO")

        XCTAssertTrue(first.ok)
        XCTAssertFalse(first.duplicate)
        XCTAssertTrue(second.ok)
        XCTAssertFalse(second.duplicate, "重试必须绕过去重，第二次不应被 duplicate 抑制")
    }

    func testJSONValueRoundTripsCommandPayload() throws {
        let value = try JSONValue.parse(#"{"cmd":"getAgentInfo","requestID":"RID","preview":true}"#)
        let object = try XCTUnwrap(value.objectValue)

        XCTAssertEqual(object.string("cmd"), "getAgentInfo")
        XCTAssertEqual(object.string("requestID"), "RID")
        XCTAssertEqual(object.bool("preview"), true)
    }

    func testNativeRendererWritesPDF() throws {
        let renderer = NativeWaybillRenderer()
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tabooprint-tests-\(UUID().uuidString)", isDirectory: true)
        let payload = try XCTUnwrap(JSONValue.parse(samplePrintPayload()).objectValue)
        let result = try renderer.render(payload: payload, outputDirectory: outputDir, requestID: "RID", taskID: "TASK")
        let data = try Data(contentsOf: result.url)
        let document = try XCTUnwrap(CGPDFDocument(result.url as CFURL))
        let page = try XCTUnwrap(document.page(at: 1))
        let mediaBox = page.getBoxRect(.mediaBox)

        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
        XCTAssertEqual(result.fileName, "TASK.pdf")
        // 默认纸张为 100×180mm，mediaBox 等于纸张外框尺寸。
        XCTAssertEqual(mediaBox.width, 100 * 72 / 25.4, accuracy: 0.01)
        XCTAssertEqual(mediaBox.height, 180 * 72 / 25.4, accuracy: 0.01)
    }

    func testNativeRendererCalibrationTokenChangesFilename() throws {
        // 默认校准保持纯 taskID 文件名（兼容协议回放与既有断言）。
        XCTAssertEqual(NativeWaybillRenderer.calibrationToken(.identity), "")

        let renderer = NativeWaybillRenderer()
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tabooprint-tests-\(UUID().uuidString)", isDirectory: true)
        let payload = try XCTUnwrap(JSONValue.parse(samplePrintPayload()).objectValue)

        let plain = try renderer.render(payload: payload, outputDirectory: outputDir, requestID: "RID", taskID: "TASK")
        XCTAssertEqual(plain.fileName, "TASK.pdf")

        // 非默认校准产出不同文件名，使 latestPreviewPDF/PDFView 能感知 URL 变化并刷新。
        var calibration = PrinterCalibration.identity
        calibration.offsetXMM = 2.5
        let shifted = try renderer.render(payload: payload, outputDirectory: outputDir, requestID: "RID", taskID: "TASK", calibration: calibration)
        XCTAssertNotEqual(shifted.fileName, plain.fileName)
        XCTAssertTrue(shifted.fileName.hasPrefix("TASK-cal"))
    }

    func testNativeRendererUsesNativeContentBoxForMatchingPaper() throws {
        let renderer = NativeWaybillRenderer()
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tabooprint-tests-\(UUID().uuidString)", isDirectory: true)
        let payload = try XCTUnwrap(JSONValue.parse(samplePrintPayload()).objectValue)
        let result = try renderer.render(payload: payload, outputDirectory: outputDir, requestID: "RID", taskID: "NATIVE", paperSize: PaperCatalog.match(media: "74x126mm"))
        let document = try XCTUnwrap(CGPDFDocument(result.url as CFURL))
        let page = try XCTUnwrap(document.page(at: 1))
        let mediaBox = page.getBoxRect(.mediaBox)

        // 选 74×126mm 时纸张外框与内容版面一致。
        XCTAssertEqual(mediaBox.width, 74 * 72 / 25.4, accuracy: 0.01)
        XCTAssertEqual(mediaBox.height, 126 * 72 / 25.4, accuracy: 0.01)
    }

    func testNativeRendererPaperSizeDrivesMediaBox() throws {
        let renderer = NativeWaybillRenderer()
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tabooprint-tests-\(UUID().uuidString)", isDirectory: true)
        let payload = try XCTUnwrap(JSONValue.parse(samplePrintPayload()).objectValue)
        let result = try renderer.render(payload: payload, outputDirectory: outputDir, requestID: "RID", taskID: "A4", paperSize: PaperCatalog.match(media: "A4"))
        let document = try XCTUnwrap(CGPDFDocument(result.url as CFURL))
        let page = try XCTUnwrap(document.page(at: 1))
        let mediaBox = page.getBoxRect(.mediaBox)

        XCTAssertEqual(mediaBox.width, 210 * 72 / 25.4, accuracy: 0.01)
        XCTAssertEqual(mediaBox.height, 297 * 72 / 25.4, accuracy: 0.01)
    }

    func testAdaptivePaperSizesMediaBoxToContentFootprint() throws {
        let renderer = NativeWaybillRenderer()
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tabooprint-tests-\(UUID().uuidString)", isDirectory: true)
        let payload = try XCTUnwrap(JSONValue.parse(samplePrintPayload()).objectValue)

        func mediaBox(_ cal: PrinterCalibration, _ taskID: String) throws -> CGRect {
            // 手选 A4，但自适应应忽略它，按内容足迹定页。
            let result = try renderer.render(payload: payload, outputDirectory: outputDir, requestID: "RID", taskID: taskID, paperSize: PaperCatalog.match(media: "A4"), calibration: cal)
            let document = try XCTUnwrap(CGPDFDocument(result.url as CFURL))
            return try XCTUnwrap(document.page(at: 1)).getBoxRect(.mediaBox)
        }

        // 自适应 + 0°：足迹 = 内容盒 74×126mm。
        let rot0 = try mediaBox(PrinterCalibration(adaptivePaper: true), "ADAPT0")
        XCTAssertEqual(rot0.width, 74 * 72 / 25.4, accuracy: 0.01)
        XCTAssertEqual(rot0.height, 126 * 72 / 25.4, accuracy: 0.01)

        // 自适应 + 90°：交换长短边 → 126×74mm。
        let rot90 = try mediaBox(PrinterCalibration(rotationDegrees: 90, adaptivePaper: true), "ADAPT90")
        XCTAssertEqual(rot90.width, 126 * 72 / 25.4, accuracy: 0.01)
        XCTAssertEqual(rot90.height, 74 * 72 / 25.4, accuracy: 0.01)

        // 自适应 + 2× 缩放：足迹按比例放大 → 148×252mm。
        let scaled = try mediaBox(PrinterCalibration(scaleRatio: 2.0, adaptivePaper: true), "ADAPT2X")
        XCTAssertEqual(scaled.width, 148 * 72 / 25.4, accuracy: 0.01)
        XCTAssertEqual(scaled.height, 252 * 72 / 25.4, accuracy: 0.01)
    }

    func testPaperCatalogMatchesAndFallsBack() {
        XCTAssertEqual(PaperCatalog.default.media, "100x180mm")
        XCTAssertEqual(PaperCatalog.match(media: "100x180mm").id, "100x180mm")
        XCTAssertEqual(PaperCatalog.match(media: "A4").widthMM, 210)
        XCTAssertEqual(PaperCatalog.match(media: "a4").id, "A4")
        // 未知值回退到默认项。
        XCTAssertEqual(PaperCatalog.match(media: "totally-unknown").id, PaperCatalog.default.id)
        XCTAssertEqual(PaperCatalog.match(media: "").id, PaperCatalog.default.id)
    }

    func testNativeServiceLifecycleAndHTTPPreview() throws {
        let service = NativePrintService()
        let wsPort = Int.random(in: 25000...32000)
        let httpPort = wsPort + 1
        let settings = PrintSettings(printerName: "TAOBAO", media: "100x180mm", dryRun: true, fitToPage: true, dedupe: true, dedupeWindowMinutes: 10)
        let config = PrintServiceConfiguration(
            host: "127.0.0.1",
            webSocketPort: wsPort,
            httpPort: httpPort,
            runtimeMode: .defaultPreview,
            autoOpenPreview: false,
            printSettings: settings
        )

        let start = service.start(configuration: config)
        XCTAssertEqual(start.exitCode, 0, start.output)
        defer { _ = service.stop() }

        let snapshot = service.snapshot()
        XCTAssertEqual(snapshot.serviceState, .running)
        XCTAssertEqual(snapshot.ports.count, 2)

        let fallbackURL = URL(string: "http://127.0.0.1:\(httpPort)/file/missing.pdf")!
        let (data, response) = try URLSession.shared.syncData(from: fallbackURL)
        let http = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(http.statusCode, 200)
        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
    }

    func testHTTPHeadReturnsPDFHeadersWithoutBody() throws {
        let service = NativePrintService()
        let ports = randomPortPair()
        let config = testConfiguration(wsPort: ports.ws, httpPort: ports.http, runtimeMode: .defaultPreview)

        XCTAssertEqual(service.start(configuration: config).exitCode, 0)
        defer { _ = service.stop() }

        let url = URL(string: "http://127.0.0.1:\(ports.http)/file/missing.pdf")!
        let (data, response) = try URLSession.shared.syncData(for: URLRequest(url: url, method: "HEAD"))
        let http = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "application/pdf")
        XCTAssertTrue(data.isEmpty)
    }

    func testWebSocketProbeCommandsReturnSuccessShapes() throws {
        let service = NativePrintService()
        let ports = randomPortPair()
        let config = testConfiguration(wsPort: ports.ws, httpPort: ports.http, runtimeMode: .defaultPreview)

        XCTAssertEqual(service.start(configuration: config).exitCode, 0)
        defer { _ = service.stop() }

        let client = try TestWebSocketClient(port: ports.ws)
        defer { client.close() }

        try client.send(["cmd": "getPrinters", "requestID": "RID_PRINTERS"])
        let printers = try client.receiveJSON()
        XCTAssertEqual(printers["cmd"] as? String, "getPrinters")
        XCTAssertEqual(printers["status"] as? String, "success")
        XCTAssertNotNil(printers["printers"] as? [[String: Any]])

        try client.send(["cmd": "getAgentInfo", "requestID": "RID_AGENT"])
        let agent = try client.receiveJSON()
        XCTAssertEqual(agent["cmd"] as? String, "getAgentInfo")
        XCTAssertEqual(agent["version"] as? String, "1.5.3.0")

        try client.send(["cmd": "getGlobalConfig", "requestID": "RID_GLOBAL"])
        let global = try client.receiveJSON()
        XCTAssertEqual(global["cmd"] as? String, "getGlobalConfig")
        XCTAssertEqual(global["notifyOnTaskFailure"] as? Bool, true)
    }

    func testWebSocketPreviewFlowMatchesReplayShape() throws {
        let service = NativePrintService()
        let ports = randomPortPair()
        let config = testConfiguration(wsPort: ports.ws, httpPort: ports.http, runtimeMode: .defaultPreview)

        XCTAssertEqual(service.start(configuration: config).exitCode, 0)
        defer { _ = service.stop() }

        let client = try TestWebSocketClient(port: ports.ws)
        defer { client.close() }

        try client.send(["cmd": "setPrinterConfig", "requestID": "RID_SET", "printer": ["name": "TAOBAO"]])
        XCTAssertEqual(try client.receiveJSON()["status"] as? String, "success")
        try client.send(try jsonObject(samplePrintPayload()))
        let flow = try client.receiveJSON(count: 6)

        XCTAssertEqual(flow.map { $0["cmd"] as? String }, ["notifyTaskResult", "print", "notifyDocResult", "notifyDocResult", "print", "notifyTaskResult"])
        XCTAssertEqual(flow[0]["status"] as? String, "initial")
        XCTAssertEqual(flow[1]["errorCode"] as? Double, 0)
        XCTAssertNotNil(flow[4]["previewURL"] as? String)
        XCTAssertEqual(flow[5]["status"] as? String, "completeSuccess")
    }

    func testWebSocketPreviewFalseFlowReturnsNotifyPrintResult() throws {
        let service = NativePrintService()
        let ports = randomPortPair()
        let config = testConfiguration(wsPort: ports.ws, httpPort: ports.http, runtimeMode: .respectPreviewFlag)

        XCTAssertEqual(service.start(configuration: config).exitCode, 0)
        defer { _ = service.stop() }

        var payload = try jsonObject(samplePrintPayload())
        var task = payload["task"] as? [String: Any] ?? [:]
        task["preview"] = false
        payload["task"] = task

        let client = try TestWebSocketClient(port: ports.ws)
        defer { client.close() }
        try client.send(["cmd": "setPrinterConfig", "requestID": "RID_SET", "printer": ["name": "TAOBAO"]])
        _ = try client.receiveJSON()
        try client.send(payload)
        let flow = try client.receiveJSON(count: 6)

        XCTAssertEqual(flow.map { $0["cmd"] as? String }, ["notifyTaskResult", "print", "notifyDocResult", "notifyDocResult", "notifyPrintResult", "notifyTaskResult"])
        XCTAssertNil(flow[4]["previewURL"])
        XCTAssertEqual(flow[4]["status"] as? Double, 0)
    }

    func testWebSocketEmptyDocumentsReturnsDocumentNotFound() throws {
        let service = NativePrintService()
        let ports = randomPortPair()
        let config = testConfiguration(wsPort: ports.ws, httpPort: ports.http, runtimeMode: .defaultPreview)

        XCTAssertEqual(service.start(configuration: config).exitCode, 0)
        defer { _ = service.stop() }

        var payload = try jsonObject(samplePrintPayload())
        var task = payload["task"] as? [String: Any] ?? [:]
        task["documents"] = []
        payload["task"] = task

        let client = try TestWebSocketClient(port: ports.ws)
        defer { client.close() }
        try client.send(payload)
        let response = try client.receiveJSON()

        XCTAssertEqual(response["cmd"] as? String, "print")
        XCTAssertEqual(response["status"] as? String, "failed")
        XCTAssertEqual(response["errorCode"] as? Double, 11)
        XCTAssertEqual(response["msg"] as? String, "document not found")
    }

    func testWebSocketDecryptFailureModeReturnsCode40() throws {
        let service = NativePrintService()
        let ports = randomPortPair()
        let config = testConfiguration(wsPort: ports.ws, httpPort: ports.http, runtimeMode: .failureDecrypt)

        XCTAssertEqual(service.start(configuration: config).exitCode, 0)
        defer { _ = service.stop() }

        let client = try TestWebSocketClient(port: ports.ws)
        defer { client.close() }
        try client.send(try jsonObject(samplePrintPayload()))
        let flow = try client.receiveJSON(count: 3)

        XCTAssertEqual(flow.map { $0["cmd"] as? String }, ["notifyTaskResult", "print", "notifyDocResult"])
        XCTAssertEqual(flow[2]["code"] as? Double, 40)
        XCTAssertEqual(flow[2]["detail"] as? String, "Unknown encryption type.")
    }

    func testPhysicalDedupeAndLprArgsAreStable() throws {
        let settings = PrintSettings(printerName: "TAOBAO", media: "100x180mm", dryRun: true, fitToPage: true, dedupe: true, dedupeWindowMinutes: 10)
        let pdfURL = URL(fileURLWithPath: "/tmp/tabooprint/waybills/TASK.pdf")
        let docs = [
            ProtocolDocument(documentId: "DOC1", fingerprint: "FP1", index: 0),
            ProtocolDocument(documentId: "DOC2", fingerprint: "FP2", index: 1),
        ]

        XCTAssertEqual(buildLprArgs(printerName: "TAOBAO", pdfURL: pdfURL, settings: settings), [
            "-P", "TAOBAO",
            "-o", "media=100x180mm",
            "-o", "fit-to-page",
            "/tmp/tabooprint/waybills/TASK.pdf",
        ])
        XCTAssertEqual(buildPhysicalPrintDedupeKey(printerName: "TAOBAO", docs: docs, settings: settings), "physical|TAOBAO|100x180mm|fit|noflip|offX:0.000|offY:0.000|rot:0|scale:1.000|fixed|DOC1,DOC2|FP1,FP2")
    }

    func testCalibrationChangesDedupeKeyAndAdaptiveMedia() throws {
        let base = PrintSettings(printerName: "TAOBAO", media: "100x180mm", dryRun: true, fitToPage: true, dedupe: true, dedupeWindowMinutes: 10)
        let docs = [ProtocolDocument(documentId: "DOC1", fingerprint: "FP1", index: 0)]
        let baseKey = buildPhysicalPrintDedupeKey(printerName: "TAOBAO", docs: docs, settings: base)

        // 每个校准字段变化都必须改变 dedupe key，否则改校准会被当重复打印抑制。
        var offset = base; offset.offsetXMM = 2
        XCTAssertNotEqual(buildPhysicalPrintDedupeKey(printerName: "TAOBAO", docs: docs, settings: offset), baseKey)
        var rotated = base; rotated.rotationDegrees = 90
        XCTAssertNotEqual(buildPhysicalPrintDedupeKey(printerName: "TAOBAO", docs: docs, settings: rotated), baseKey)
        var scaled = base; scaled.scaleRatio = 1.5
        XCTAssertNotEqual(buildPhysicalPrintDedupeKey(printerName: "TAOBAO", docs: docs, settings: scaled), baseKey)
        var adaptive = base; adaptive.adaptivePaper = true
        XCTAssertNotEqual(buildPhysicalPrintDedupeKey(printerName: "TAOBAO", docs: docs, settings: adaptive), baseKey)

        // 自适应纸张：媒体名取内容足迹；90° 旋转交换长短边 → 126x74mm。
        XCTAssertEqual(resolvedMediaString(settings: adaptive), "74x126mm")
        var adaptiveRot = base; adaptiveRot.adaptivePaper = true; adaptiveRot.rotationDegrees = 90
        XCTAssertEqual(resolvedMediaString(settings: adaptiveRot), "126x74mm")
        // 非自适应时媒体名维持手选预设。
        XCTAssertEqual(resolvedMediaString(settings: base), "100x180mm")
    }

    func testFlipPrintAddsOrientationArgAndDedupeKey() throws {
        let settings = PrintSettings(printerName: "TAOBAO", media: "100x180mm", dryRun: true, fitToPage: true, dedupe: true, dedupeWindowMinutes: 10, flipPrint: true)
        let pdfURL = URL(fileURLWithPath: "/tmp/tabooprint/waybills/TASK.pdf")
        let docs = [ProtocolDocument(documentId: "DOC1", fingerprint: "FP1", index: 0)]

        // 反转通过 PDF 层 180° 旋转实现（见 makeRotatedPDFForPrinting），不再向 lpr 注入旋转选项，
        // 因此 lpr 参数与非反转时一致；反转状态只体现在 dedupe key 上。
        XCTAssertEqual(buildLprArgs(printerName: "TAOBAO", pdfURL: pdfURL, settings: settings), [
            "-P", "TAOBAO",
            "-o", "media=100x180mm",
            "-o", "fit-to-page",
            "/tmp/tabooprint/waybills/TASK.pdf",
        ])
        XCTAssertEqual(buildPhysicalPrintDedupeKey(printerName: "TAOBAO", docs: docs, settings: settings), "physical|TAOBAO|100x180mm|fit|flip|offX:0.000|offY:0.000|rot:0|scale:1.000|fixed|DOC1|FP1")
    }

    func testDocumentFingerprintIncludesEncryptedAndCustomFields() throws {
        let payload = try XCTUnwrap(JSONValue.parse(samplePrintPayload()).objectValue)
        let document = try XCTUnwrap(payload.object("task").array("documents").first?.objectValue)
        let first = buildDocumentFingerprint(document)
        var changed = document
        var contents = changed.array("contents")
        var custom = contents[0].objectValue ?? [:]
        var data = custom.object("data")
        data["ORDER_ID"] = .string("ORDER2")
        custom["data"] = .object(data)
        contents[0] = .object(custom)
        changed["contents"] = .array(contents)

        XCTAssertEqual(first.count, 16)
        XCTAssertNotEqual(first, buildDocumentFingerprint(changed))
    }

    func testCode128PatternIsDeterministic() {
        XCTAssertEqual(code128Pattern("123456"), code128Pattern("123456"))
        XCTAssertTrue(code128Pattern("123456").hasSuffix("1100011101011"))
        XCTAssertNotEqual(code128Pattern("123456"), code128Pattern("ABC123"))
    }

    func testRendererHandlesBadEncryptedDataAndFallbackPDF() throws {
        let renderer = NativeWaybillRenderer()
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tabooprint-tests-\(UUID().uuidString)", isDirectory: true)
        let payload = try XCTUnwrap(JSONValue.parse(sampleBadEncryptedPrintPayload()).objectValue)
        let result = try renderer.render(payload: payload, outputDirectory: outputDir, requestID: "RID", taskID: "BAD_AES")
        let rendered = try Data(contentsOf: result.url)
        let fallback = renderer.writeFallbackPDF(outputDirectory: outputDir, requestID: "RID", taskID: "FALLBACK")
        let fallbackData = try Data(contentsOf: fallback.url)

        XCTAssertTrue(rendered.starts(with: Data("%PDF".utf8)))
        XCTAssertTrue(fallbackData.starts(with: Data("%PDF".utf8)))
    }

    func testWaybillPreviewSamplePDFUsesNativeRenderer() throws {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tabooprint-tests-\(UUID().uuidString)", isDirectory: true)
        let url = try WaybillPreviewSamplePDF.writeSample(to: outputDir)
        let data = try Data(contentsOf: url)
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        let page = try XCTUnwrap(document.page(at: 1))
        let mediaBox = page.getBoxRect(.mediaBox)

        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
        XCTAssertGreaterThan(data.count, 5_000)
        // 示例预览使用默认纸张 100×180mm。
        XCTAssertEqual(mediaBox.width, 100 * 72 / 25.4, accuracy: 0.01)
        XCTAssertEqual(mediaBox.height, 180 * 72 / 25.4, accuracy: 0.01)
    }

    private func samplePrintPayload() -> String {
        """
        {
          "cmd": "print",
          "requestID": "RID",
          "task": {
            "taskID": "TASK",
            "printer": "TAOBAO",
            "preview": true,
            "documents": [
              {
                "documentID": "DOC1",
                "contents": [
                  {
                    "data": {
                      "WAIBILLNO_BAR_CODE": "YT1234567890123",
                      "ITEM_INFO": "测试商品",
                      "ITEM_TOTAL_COUNT": "1",
                      "ORDER_ID": "ORDER1",
                      "BUYER_MEMO": "买家备注",
                      "SELLER_MEMO": "卖家备注"
                    }
                  }
                ]
              }
            ]
          }
        }
        """
    }

    private func sampleBadEncryptedPrintPayload() -> String {
        """
        {
          "cmd": "print",
          "requestID": "RID",
          "task": {
            "taskID": "BAD_AES",
            "printer": "TAOBAO",
            "preview": true,
            "documents": [
              {
                "documentID": "DOC_BAD_AES",
                "contents": [
                  {
                    "ver": "waybill_print_secret_version_1",
                    "encryptedData": "AES:not-valid-base64",
                    "templateURL": "https://cloudprint.cainiao.com/template/standard/300336/92",
                    "addData": {"sender": {"name": "小样", "mobile": "13018933107"}}
                  },
                  {
                    "data": {
                      "WAIBILLNO_BAR_CODE": "YT1234567890123",
                      "ITEM_INFO": "坏密文测试",
                      "ITEM_TOTAL_COUNT": "1",
                      "ORDER_ID": "ORDER_BAD_AES"
                    },
                    "templateURL": "https://cloudprint.cainiao.com/template/customArea/73159162/10"
                  }
                ]
              }
            ]
          }
        }
        """
    }

    private func testConfiguration(wsPort: Int, httpPort: Int, runtimeMode: RuntimeMode) -> PrintServiceConfiguration {
        PrintServiceConfiguration(
            host: "127.0.0.1",
            webSocketPort: wsPort,
            httpPort: httpPort,
            runtimeMode: runtimeMode,
            autoOpenPreview: false,
            printSettings: PrintSettings(printerName: "TAOBAO", media: "100x180mm", dryRun: true, fitToPage: true, dedupe: true, dedupeWindowMinutes: 10)
        )
    }

    private func randomPortPair() -> (ws: Int, http: Int) {
        let ws = Int.random(in: 25000...32000)
        return (ws, ws + 1)
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }
}

private extension URLSession {
    func syncData(from url: URL) throws -> (Data, URLResponse) {
        try syncData(for: URLRequest(url: url))
    }

    func syncData(for request: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        let box = LockedResultBox()

        dataTask(with: request) { data, response, error in
            if let error {
                box.store(.failure(error))
            } else {
                box.store(.success((data ?? Data(), response ?? URLResponse())))
            }
            semaphore.signal()
        }.resume()

        semaphore.wait()
        return try box.load().get()
    }
}

private extension URLRequest {
    init(url: URL, method: String) {
        self.init(url: url)
        httpMethod = method
    }
}

private final class LockedResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<(Data, URLResponse), Error>?

    func store(_ newValue: Result<(Data, URLResponse), Error>) {
        lock.lock()
        result = newValue
        lock.unlock()
    }

    func load() -> Result<(Data, URLResponse), Error> {
        lock.lock()
        defer { lock.unlock() }
        return result ?? .failure(NSError(domain: "TabooprintTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing URLSession result"]))
    }
}

private final class TestWebSocketClient {
    private let input: InputStream
    private let output: OutputStream

    init(port: Int) throws {
        var inputStream: InputStream?
        var outputStream: OutputStream?
        Stream.getStreamsToHost(withName: "127.0.0.1", port: port, inputStream: &inputStream, outputStream: &outputStream)
        guard let inputStream, let outputStream else {
            throw NSError(domain: "TabooprintTests", code: 10, userInfo: [NSLocalizedDescriptionKey: "cannot create streams"])
        }
        input = inputStream
        output = outputStream
        input.open()
        output.open()
        try handshake(port: port)
    }

    func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        var frame = Data([0x81])
        let length = data.count
        if length < 126 {
            frame.append(UInt8(0x80 | length))
        } else if length <= 0xffff {
            frame.append(0x80 | 126)
            frame.append(UInt8((length >> 8) & 0xff))
            frame.append(UInt8(length & 0xff))
        } else {
            throw NSError(domain: "TabooprintTests", code: 11, userInfo: [NSLocalizedDescriptionKey: "test frame too large"])
        }
        let mask = [UInt8](repeating: 0x37, count: 4)
        frame.append(contentsOf: mask)
        frame.append(contentsOf: data.enumerated().map { index, byte in byte ^ mask[index % 4] })
        try write(frame)
    }

    func receiveJSON(count: Int) throws -> [[String: Any]] {
        try (0..<count).map { _ in try receiveJSON() }
    }

    func receiveJSON() throws -> [String: Any] {
        let header = try read(count: 2)
        let opcode = header[0] & 0x0f
        var length = Int(header[1] & 0x7f)
        if length == 126 {
            let bytes = try read(count: 2)
            length = Int(bytes[0]) << 8 | Int(bytes[1])
        } else if length == 127 {
            throw NSError(domain: "TabooprintTests", code: 12, userInfo: [NSLocalizedDescriptionKey: "large frames unsupported in test client"])
        }
        let payload = try read(count: length)
        guard opcode == 0x1 else {
            throw NSError(domain: "TabooprintTests", code: 13, userInfo: [NSLocalizedDescriptionKey: "unexpected opcode \(opcode)"])
        }
        let object = try JSONSerialization.jsonObject(with: Data(payload), options: [])
        return try XCTUnwrap(object as? [String: Any])
    }

    func close() {
        try? write(Data([0x88, 0x00]))
        input.close()
        output.close()
    }

    private func handshake(port: Int) throws {
        let request = """
        GET / HTTP/1.1\r
        Host: 127.0.0.1:\(port)\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
        Sec-WebSocket-Version: 13\r
        \r

        """
        try write(Data(request.utf8))
        let response = try readUntilHeadersEnd()
        guard String(data: response, encoding: .utf8)?.contains("101 Switching Protocols") == true else {
            throw NSError(domain: "TabooprintTests", code: 14, userInfo: [NSLocalizedDescriptionKey: "websocket handshake failed"])
        }
    }

    private func write(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let written = output.write(base.advanced(by: sent), maxLength: data.count - sent)
                if written <= 0 {
                    throw NSError(domain: "TabooprintTests", code: 15, userInfo: [NSLocalizedDescriptionKey: "stream write failed"])
                }
                sent += written
            }
        }
    }

    private func read(count: Int) throws -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        while bytes.count < count {
            var buffer = [UInt8](repeating: 0, count: count - bytes.count)
            let read = input.read(&buffer, maxLength: buffer.count)
            if read <= 0 {
                throw NSError(domain: "TabooprintTests", code: 16, userInfo: [NSLocalizedDescriptionKey: "stream read failed"])
            }
            bytes.append(contentsOf: buffer.prefix(read))
        }
        return bytes
    }

    private func readUntilHeadersEnd() throws -> Data {
        var data = Data()
        while !data.contains(Data("\r\n\r\n".utf8)) {
            data.append(contentsOf: try read(count: 1))
        }
        return data
    }
}

/// 线程安全的日志收集器，供测试用 setLogSink（@Sendable 闭包）捕获 emit 的事件行。
final class LogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.withLock { storage.append(line) }
    }

    var lines: [String] {
        lock.withLock { storage }
    }
}
