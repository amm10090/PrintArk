import AppKit
import CryptoSwift
import CryptoKit
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import PDFKit

struct PrintServiceConfiguration: Sendable {
    var host: String = "127.0.0.1"
    var webSocketPort = 13528
    var httpPort = 13525
    var runtimeMode: RuntimeMode
    var autoOpenPreview: Bool
    var printSettings: PrintSettings

    var forcePreview: Bool {
        runtimeMode != .respectPreviewFlag
    }

    var failureMode: String {
        switch runtimeMode {
        case .failureDocumentNotFound:
            return "document-not-found"
        case .failureDecrypt:
            return "decrypt"
        case .defaultPreview, .respectPreviewFlag:
            return "none"
        }
    }

    static func current(runtimeMode: RuntimeMode, autoOpenPreview: Bool, printSettings: PrintSettings) -> PrintServiceConfiguration {
        PrintServiceConfiguration(
            runtimeMode: runtimeMode,
            autoOpenPreview: autoOpenPreview,
            printSettings: printSettings
        )
    }
}

struct PrintServiceEvent: Sendable {
    var type: String
    var fields: [String: JSONValue]

    func logLine() -> String {
        var payload = fields
        payload["type"] = .string(type)
        payload["time"] = .string(nowTimestamp())
        let data = (try? JSONValue.object(payload).encodedData()) ?? Data("{}".utf8)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        return "[cainiao-mock:event] \(text)"
    }
}

struct NativeServiceRuntime: Sendable {
    let eventLoopGroup: MultiThreadedEventLoopGroup
    let webSocketChannel: Channel
    let httpChannel: Channel
}

final class NativePrintService: @unchecked Sendable {
    private let lock = NSLock()
    private var runtime: NativeServiceRuntime?
    private var logSink: (@Sendable (String) -> Void)?
    private var configuration = PrintServiceConfiguration.current(
        runtimeMode: .defaultPreview,
        autoOpenPreview: true,
        printSettings: PrintSettings.current
    )
    private var activeConnections = 0
    private var logLines: [String] = []
    private var renderedPDFs: [String: URL] = [:]
    private var physicalPrintHistory: [String: PhysicalPrintHistoryItem] = [:]
    private var lastRenderContext: (payload: [String: JSONValue], requestID: String, taskID: String)?
    private var lastError = ""
    private let renderer = NativeWaybillRenderer()
    private let renderedDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tabooprint", isDirectory: true)
        .appendingPathComponent("waybills", isDirectory: true)

    var latestPreviewPDF: URL? {
        lock.withLock {
            renderedPDFs.values
                .sorted { modificationDate($0) > modificationDate($1) }
                .first
        }
    }

    func setLogSink(_ sink: (@Sendable (String) -> Void)?) {
        lock.withLock {
            logSink = sink
        }
    }

    func start(configuration newConfiguration: PrintServiceConfiguration) -> CommandResult {
        lock.withLock {
            configuration = newConfiguration
            lastError = ""
        }

        if isRunning {
            return CommandResult(exitCode: 0, output: "native service already running")
        }

        do {
            try FileManager.default.createDirectory(at: renderedDirectory, withIntermediateDirectories: true)
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
            let service = self

            let wsBootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 128)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    let upgrader = NIOWebSocketServerUpgrader(
                        shouldUpgrade: { _, _ in
                            channel.eventLoop.makeSucceededFuture([:])
                        },
                        upgradePipelineHandler: { channel, _ in
                            channel.pipeline.addHandler(WebSocketProtocolHandler(service: service))
                        }
                    )
                    let config = NIOHTTPServerUpgradeSendableConfiguration(upgraders: [upgrader], completionHandler: { _ in })
                    return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: config)
                }
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

            let httpBootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 128)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(PreviewHTTPHandler(service: service))
                    }
                }
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

            let wsChannel = try wsBootstrap.bind(host: newConfiguration.host, port: newConfiguration.webSocketPort).wait()
            let httpChannel: Channel
            do {
                httpChannel = try httpBootstrap.bind(host: newConfiguration.host, port: newConfiguration.httpPort).wait()
            } catch {
                try? wsChannel.close().wait()
                try? group.syncShutdownGracefully()
                throw error
            }
            lock.withLock {
                runtime = NativeServiceRuntime(eventLoopGroup: group, webSocketChannel: wsChannel, httpChannel: httpChannel)
            }
            appendLog("Native WebSocket listening on ws://\(newConfiguration.host):\(newConfiguration.webSocketPort)/")
            appendLog("Native HTTP preview listening on http://\(newConfiguration.host):\(newConfiguration.httpPort)/file/<pdf>")
            emit("connection", [
            "phase": .string("service-start"),
            "activeConnections": .number(Double(activeConnections)),
            "runtimeMode": .string(describeRuntimeMode(newConfiguration)),
            "autoOpenPreview": .bool(newConfiguration.autoOpenPreview),
            "dryRun": .bool(newConfiguration.printSettings.dryRun),
        ])
        return CommandResult(exitCode: 0, output: "native service started")
        } catch {
            lock.withLock { lastError = error.localizedDescription }
            return CommandResult(exitCode: 1, output: "native service failed: \(error.localizedDescription)")
        }
    }

    func stop() -> CommandResult {
        guard let current = lock.withLock({ runtime }) else {
            return CommandResult(exitCode: 0, output: "native service not running")
        }

        lock.withLock {
            runtime = nil
            activeConnections = 0
        }

        do {
            try current.webSocketChannel.close().wait()
            try current.httpChannel.close().wait()
            try current.eventLoopGroup.syncShutdownGracefully()
            emit("connection", [
                "phase": .string("service-stop"),
                "activeConnections": .number(0),
            ])
            appendLog("Native service stopped")
            return CommandResult(exitCode: 0, output: "native service stopped")
        } catch {
            lock.withLock { lastError = error.localizedDescription }
            return CommandResult(exitCode: 1, output: "native service stop failed: \(error.localizedDescription)")
        }
    }

    func restart(configuration: PrintServiceConfiguration) -> CommandResult {
        let stopResult = stop()
        let startResult = start(configuration: configuration)
        let output = [stopResult.output, startResult.output].filter { !$0.isEmpty }.joined(separator: "\n")
        return CommandResult(exitCode: startResult.exitCode, output: output)
    }

    /// 应用最新的打印设置，并在已有渲染上下文时按新设置重渲染最近一张面单。
    /// 返回是否实际重绘了预览。
    @discardableResult
    func applyPrintSettings(_ settings: PrintSettings) -> Bool {
        let context = lock.withLock { () -> (payload: [String: JSONValue], requestID: String, taskID: String)? in
            configuration = PrintServiceConfiguration(
                host: configuration.host,
                webSocketPort: configuration.webSocketPort,
                httpPort: configuration.httpPort,
                runtimeMode: configuration.runtimeMode,
                autoOpenPreview: configuration.autoOpenPreview,
                printSettings: settings
            )
            return lastRenderContext
        }
        guard let context else { return false }
        let docs = context.payload.object("task").array("documents").compactMap(\.objectValue).enumerated().map { index, document in
            ProtocolDocument(
                documentId: document.string("documentID", default: document.string("documentId", default: "MOCK_DOC_\(index + 1)")),
                fingerprint: buildDocumentFingerprint(document),
                index: index
            )
        }
        guard !docs.isEmpty else { return false }
        _ = renderWaybill(
            payload: context.payload,
            requestID: context.requestID,
            taskID: context.taskID,
            docs: docs,
            paperSize: PaperCatalog.match(media: settings.media),
            hideTaoLogo: settings.hideTaoLogo,
            hideCourierPackage: settings.hideCourierPackage
        )
        return true
    }

    func snapshot() -> SupervisorSnapshot {
        let stateValues = lock.withLock {
            (configuration, lastError, activeConnections, logLines)
        }
        let config = stateValues.0
        let error = stateValues.1
        let connections = stateValues.2
        let lines = stateValues.3
        let running = isRunning
        let ports = [
            PortStatus(id: config.webSocketPort, port: config.webSocketPort, label: "WS", isListening: running, listenerCount: running ? 1 : 0),
            PortStatus(id: config.httpPort, port: config.httpPort, label: "HTTP", isListening: running, listenerCount: running ? 1 : 0),
        ]
        let tasks = Self.parseRecentTasks(from: lines)
        let jobs = Self.parsePrintJobs(from: lines, fallbackPrinter: config.printSettings.printerName)
        let state: ServiceState = running ? .running : (error.isEmpty ? .stopped : .error)
        let portSummary = ports.map { "\($0.label)\($0.stateText)" }.joined(separator: " · ")
        let connectionText = connections == 1 ? "1 个浏览器连接" : "\(connections) 个浏览器连接"
        let summary = state == .error ? "错误 • \(error)" : "\(state.title) • \(portSummary) • \(connectionText)"
        return SupervisorSnapshot(
            serviceState: state,
            serviceSummary: summary,
            ports: ports,
            activeBrowserConnections: connections,
            recentTasks: tasks,
            printJobs: jobs,
            printerDevices: discoverPrinterDevices(defaultPrinterName: config.printSettings.printerName),
            rawLogLines: lines,
            latestPreviewPDF: latestPreviewPDF,
            pidIsAlive: running
        )
    }

    func handleWebSocketText(_ text: String, on channel: Channel) {
        guard let payload = try? JSONValue.parse(text).objectValue else {
            sendJSON([
                "cmd": .string("unknown"),
                "status": .string("failed"),
                "msg": .string("invalid json"),
                "errorCode": .number(400),
            ], on: channel)
            return
        }

        let cmd = payload.string("cmd", default: "unknown")
        let requestID = payload.string("requestID", default: "MOCK_\(millisecondsNow())")
        appendLog("recv cmd=\(cmd) requestID=\(requestID)")

        switch cmd {
        case "getPrinters":
            let printers = discoverProtocolPrinters()
            let defaultPrinter = defaultPrinterName(from: printers)
            sendJSON([
                "cmd": .string(cmd),
                "requestID": .string(requestID),
                "status": .string("success"),
                "msg": .string("no error"),
                "defaultPrinter": .string(defaultPrinter),
                "printers": .array(printers.map { printer in
                    .object([
                        "name": .string(printer.name),
                        "status": .string(printer.isEnabled ? "enable" : "disable"),
                        "type": .string("RAW"),
                        "printerType": .string("NORMAL"),
                        "supportRfid": .bool(false),
                    ])
                }),
                "errorCode": .number(0),
            ], on: channel)
        case "getAgentInfo":
            sendJSON([
                "cmd": .string(cmd),
                "requestID": .string(requestID),
                "status": .string("success"),
                "msg": .string("no error"),
                "version": .string("1.5.3.0"),
                "errorCode": .number(0),
            ], on: channel)
        case "getGlobalConfig":
            sendJSON([
                "cmd": .string(cmd),
                "requestID": .string(requestID),
                "status": .string("success"),
                "msg": .string("no error"),
                "notifyOnTaskFailure": .bool(true),
                "ignoreFontCanNotDisplay": .bool(true),
                "errorCode": .number(0),
            ], on: channel)
        case "setGlobalConfig":
            sendJSON([
                "cmd": .string(cmd),
                "requestID": .string(requestID),
                "status": .string("success"),
                "msg": .string("no error"),
                "errorCode": .number(0),
            ], on: channel)
        case "setPrinterConfig":
            let printerName = payload.object("printer").string("name", default: "TAOBAO")
            sendJSON([
                "cmd": .string(cmd),
                "requestID": .string(requestID),
                "status": .string("success"),
                "msg": .string("no error"),
                "printer": .string(printerName),
                "errorCode": .number(0),
            ], on: channel)
        case "print":
            handlePrint(payload, requestID: requestID, on: channel)
        default:
            sendJSON([
                "cmd": .string(cmd),
                "requestID": .string(requestID),
                "status": .string("failed"),
                "msg": .string("unsupported cmd: \(cmd)"),
                "errorCode": .number(404),
            ], on: channel)
        }
    }

    func connectionOpened() {
        let count = lock.withLock { () -> Int in
            activeConnections += 1
            return activeConnections
        }
        emit("connection", [
            "phase": .string("open"),
            "activeConnections": .number(Double(count)),
        ])
    }

    func connectionClosed(_ reason: String) {
        let count = lock.withLock { () -> Int in
            activeConnections = max(0, activeConnections - 1)
            return activeConnections
        }
        emit("connection", [
            "phase": .string("close"),
            "reason": .string(reason),
            "activeConnections": .number(Double(count)),
        ])
    }

    func servePDF(named rawName: String) -> Data? {
        let name = rawName.removingPercentEncoding ?? rawName
        guard !name.contains("/"), name.lowercased().hasSuffix(".pdf") else {
            return nil
        }
        let url = lock.withLock { renderedPDFs[name] } ?? renderedDirectory.appendingPathComponent(name)
        return try? Data(contentsOf: url)
    }

    func recordPreviewHTTPRequest(method: String, path: String, status: HTTPResponseStatus, byteCount: Int) {
        appendLog("http \(method) \(path) -> \(status.code) bytes=\(byteCount)")
    }

    private var isRunning: Bool {
        lock.withLock { runtime != nil }
    }

    private func handlePrint(_ payload: [String: JSONValue], requestID: String, on channel: Channel) {
        let config = lock.withLock { configuration }
        let task = payload.object("task")
        let taskID = task.string("taskID", default: requestID)
        let printer = task.string("printer", default: "TAOBAO")
        let documents = task.array("documents").compactMap(\.objectValue)
        let runtimeMode = describeRuntimeMode(config)

        emit("task", [
            "phase": .string("start"),
            "command": .string("print"),
            "requestID": .string(requestID),
            "taskID": .string(taskID),
            "printer": .string(printer),
            "documentCount": .number(Double(documents.count)),
            "mode": .string(runtimeMode),
        ])

        if documents.isEmpty || config.failureMode == "document-not-found" {
            emit("task", [
                "phase": .string("finish"),
                "command": .string("print"),
                "requestID": .string(requestID),
                "taskID": .string(taskID),
                "printer": .string(printer),
                "documentCount": .number(Double(documents.count)),
                "mode": .string(runtimeMode),
                "result": .string("document-not-found"),
                "errorCode": .number(11),
            ])
            sendJSON(documentNotFoundResponse(requestID: requestID, taskID: taskID), on: channel)
            return
        }

        let docs = documents.enumerated().map { index, document in
            ProtocolDocument(
                documentId: document.string("documentID", default: document.string("documentId", default: "MOCK_DOC_\(index + 1)")),
                fingerprint: buildDocumentFingerprint(document),
                index: index
            )
        }

        let shouldReturnPreview = config.forcePreview || task.bool("preview") == true
        let physicalMode = task.bool("preview") == false
        let spendTime: [String: JSONValue] = [
            "total": .number(220),
            "downloading": .number(15),
            "pending": .number(45),
            "rendering": .number(160),
        ]
        let renderResult = renderWaybill(payload: payload, requestID: requestID, taskID: taskID, docs: docs, paperSize: PaperCatalog.match(media: config.printSettings.media), hideTaoLogo: config.printSettings.hideTaoLogo, hideCourierPackage: config.printSettings.hideCourierPackage)
        let previewURL = "http://localhost:\(config.httpPort)/file/\(renderResult.fileName)"
        var physicalPrintJob: PhysicalPrintJob?

        var flow: [(Int64, [String: JSONValue])] = [
            (0, [
                "cmd": .string("notifyTaskResult"),
                "requestID": .string(requestID),
                "status": .string("initial"),
                "printer": .string(printer),
                "taskId": .string(taskID),
            ]),
            (15, [
                "cmd": .string("print"),
                "requestID": .string(requestID),
                "taskID": .string(taskID),
                "status": .string("success"),
                "msg": .string("no error"),
                "errorCode": .number(0),
            ]),
        ]

        if config.failureMode == "decrypt" {
            for (index, doc) in docs.enumerated() {
                flow.append((Int64(50 + index * 20), decryptFailureResponse(requestID: requestID, taskID: taskID, printer: printer, documentId: doc.documentId)))
            }
            sendFlow(flow, on: channel)
            emit("task", [
                "phase": .string("finish"),
                "command": .string("print"),
                "requestID": .string(requestID),
                "taskID": .string(taskID),
                "printer": .string(printer),
                "documentCount": .number(Double(docs.count)),
                "mode": .string(runtimeMode),
                "result": .string("decrypt-failure"),
                "errorCode": .number(40),
            ])
            return
        }

        for (index, doc) in docs.enumerated() {
            flow.append((Int64(50 + index * 20), [
                "cmd": .string("notifyDocResult"),
                "requestID": .string(requestID),
                "status": .string("rendered"),
                "printer": .string(printer),
                "taskId": .string(taskID),
                "documentId": .string(doc.documentId),
                "code": .number(0),
                "detail": .string("success"),
            ]))
            flow.append((Int64(85 + index * 20), [
                "cmd": .string("notifyDocResult"),
                "requestID": .string(requestID),
                "status": .string("printed"),
                "printer": .string(printer),
                "taskId": .string(taskID),
                "documentId": .string(doc.documentId),
                "code": .number(0),
                "detail": .string("success"),
                "spendTime": .object(spendTime),
            ]))
        }

        if shouldReturnPreview {
            flow.append((130, [
                "cmd": .string("print"),
                "requestID": .string(requestID),
                "taskID": .string(taskID),
                "status": .string("success"),
                "msg": .string("no error"),
                "responses": .array(docs.map { doc in
                    .object([
                        "documentId": .string(doc.documentId),
                        "urls": .array([.string(previewURL)]),
                    ])
                }),
                "previewURL": .string(previewURL),
            ]))
            if config.autoOpenPreview {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    NSWorkspace.shared.open(URL(string: previewURL)!)
                }
            }
        } else if physicalMode {
            let job = submitPhysicalPrint(requestID: requestID, taskID: taskID, taskPrinter: printer, docs: docs, pdfURL: renderResult.url, config: config)
            physicalPrintJob = job
            flow.append((130, job.ok
                ? buildNotifyPrintResult(requestID: requestID, taskID: taskID, printer: job.printerName, docs: docs, spendTime: spendTime)
                : buildNotifyPrintFailureResult(requestID: requestID, taskID: taskID, printer: job.printerName, docs: docs, error: job.error ?? "print failed")
            ))
        }

        var docsMap: [String: JSONValue] = [:]
        for doc in docs {
            docsMap[doc.documentId] = .object([
                "cmd": .string("notifyDocResult"),
                "requestID": .string(requestID),
                "status": .string("printed"),
                "printer": .string(printer),
                "taskId": .string(taskID),
                "documentId": .string(doc.documentId),
                "code": .number(0),
                "detail": .string("success"),
                "spendTime": .object(spendTime),
            ])
        }
        flow.append((shouldReturnPreview || physicalMode ? 240 : 170, [
            "cmd": .string("notifyTaskResult"),
            "requestID": .string(requestID),
            "status": .string(physicalPrintJob?.ok == false ? "completeFailed" : "completeSuccess"),
            "printer": .string(printer),
            "taskId": .string(taskID),
            "spendTime": .object(spendTime),
            "docs": .object(docsMap),
        ]))

        sendFlow(flow, on: channel)
        var fields: [String: JSONValue] = [
            "phase": .string("finish"),
            "command": .string("print"),
            "requestID": .string(requestID),
            "taskID": .string(taskID),
            "printer": .string(printer),
            "documentCount": .number(Double(docs.count)),
            "mode": .string(runtimeMode),
            "result": .string(describeTaskResult(shouldReturnPreview: shouldReturnPreview, physicalPrintJob: physicalPrintJob)),
            "renderedPdf": .string(renderResult.url.path),
        ]
        if shouldReturnPreview {
            fields["previewURL"] = .string(previewURL)
        }
        if let error = renderResult.error {
            fields["renderError"] = .string(error)
        }
        if let job = physicalPrintJob {
            fields["printDryRun"] = .bool(job.dryRun)
            fields["printCommand"] = .string(job.commandText)
            fields["commandText"] = .string(job.commandText)
            fields["pdfPath"] = .string(job.pdfURL.path)
            if let error = job.error {
                fields["printError"] = .string(error)
                fields["error"] = .string(error)
            }
        }
        emit("task", fields)
    }

    private func sendFlow(_ flow: [(Int64, [String: JSONValue])], on channel: Channel) {
        for item in flow {
            let deadline = NIODeadline.now() + .milliseconds(item.0)
            channel.eventLoop.scheduleTask(deadline: deadline) { [weak self, weak channel] in
                guard let self, let channel else { return }
                self.sendJSON(item.1, on: channel)
            }
        }
    }

    private func sendJSON(_ object: [String: JSONValue], on channel: Channel) {
        let data = (try? JSONValue.object(object).encodedData()) ?? Data("{}".utf8)
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
        appendLog("send cmd=\(object.string("cmd")) requestID=\(object.string("requestID")) status=\(object["status"]?.stringValue ?? "")")
        channel.writeAndFlush(frame, promise: nil)
    }

    private func renderWaybill(payload: [String: JSONValue], requestID: String, taskID: String, docs: [ProtocolDocument], paperSize: PaperSize, hideTaoLogo: Bool, hideCourierPackage: Bool) -> RenderResult {
        do {
            let result = try renderer.render(payload: payload, outputDirectory: renderedDirectory, requestID: requestID, taskID: taskID, paperSize: paperSize, hideTaoLogo: hideTaoLogo, hideCourierPackage: hideCourierPackage)
            lock.withLock {
                renderedPDFs[result.fileName] = result.url
                lastRenderContext = (payload: payload, requestID: requestID, taskID: taskID)
            }
            emit("render", [
                "phase": .string("success"),
                "requestID": .string(requestID),
                "taskID": .string(taskID),
                "pdfPath": .string(result.url.path),
                "fileName": .string(result.fileName),
                "documentIds": .array(docs.map { .string($0.documentId) }),
            ])
            return result
        } catch {
            let fallback = renderer.writeFallbackPDF(outputDirectory: renderedDirectory, requestID: requestID, taskID: taskID)
            lock.withLock {
                renderedPDFs[fallback.fileName] = fallback.url
            }
            emit("render", [
                "phase": .string("failed"),
                "requestID": .string(requestID),
                "taskID": .string(taskID),
                "error": .string(error.localizedDescription),
                "fallbackPdf": .string(fallback.url.path),
            ])
            return RenderResult(url: fallback.url, fileName: fallback.fileName, documentIds: docs.map(\.documentId), error: error.localizedDescription)
        }
    }

    private func submitPhysicalPrint(requestID: String, taskID: String, taskPrinter: String, docs: [ProtocolDocument], pdfURL: URL, config: PrintServiceConfiguration) -> PhysicalPrintJob {
        let resolved = config.printSettings.printerName.isEmpty ? taskPrinter : config.printSettings.printerName
        // 兜底：清洗可能被旧版解析器写入 UserDefaults 的脏名（如「TAOBAO闲置」），避免 lpr -P 找不到目标。
        let printerName = sanitizePrinterName(resolved)
        // 反转打印：不同驱动对 lpr 的 Rotate/orientation 选项映射不一致（实测本机 Rotate=2 变成了 90°），
        // 因此改在 PDF 层做确定性 180° 旋转，只旋转送打印机的副本，原始预览 PDF 不动。
        let printURL = config.printSettings.flipPrint ? makeRotatedPDFForPrinting(source: pdfURL) : pdfURL
        let lprArgs = buildLprArgs(printerName: printerName, pdfURL: printURL, settings: config.printSettings)
        let commandText = (["/usr/bin/lpr"] + lprArgs).map(shellDisplay(_:)).joined(separator: " ")
        let dedupeKey = buildPhysicalPrintDedupeKey(printerName: printerName, docs: docs, settings: config.printSettings)

        if let duplicate = findDuplicatePhysicalPrint(dedupeKey, settings: config.printSettings) {
            emit("print-job", [
                "phase": .string("duplicate-suppressed"),
                "command": .string("lpr"),
                "requestID": .string(requestID),
                "taskID": .string(taskID),
                "printer": .string(printerName),
                "documentCount": .number(Double(docs.count)),
                "pdfPath": .string(pdfURL.path),
                "previousPdfPath": .string(duplicate.pdfPath),
                "previousRequestID": .string(duplicate.requestID),
                "previousTaskID": .string(duplicate.taskID),
                "previousCommandText": .string(duplicate.commandText),
                "duplicateAgeMs": .number(Double(Int(Date().timeIntervalSince1970 * 1000) - duplicate.timestampMs)),
                "dedupeKey": .string(dedupeKey),
            ])
            return PhysicalPrintJob(
                ok: true,
                dryRun: duplicate.dryRun,
                duplicate: true,
                printerName: printerName,
                commandText: duplicate.commandText,
                pdfURL: URL(fileURLWithPath: duplicate.pdfPath),
                error: nil
            )
        }

        emit("print-job", [
            "phase": .string(config.printSettings.dryRun ? "dry-run" : "submit"),
            "command": .string("lpr"),
            "requestID": .string(requestID),
            "taskID": .string(taskID),
            "printer": .string(printerName),
            "documentCount": .number(Double(docs.count)),
            "pdfPath": .string(pdfURL.path),
            "commandText": .string(commandText),
            "media": .string(config.printSettings.media),
        ])

        if config.printSettings.dryRun {
            rememberPhysicalPrint(dedupeKey, item: PhysicalPrintHistoryItem(
                timestampMs: Int(Date().timeIntervalSince1970 * 1000),
                requestID: requestID,
                taskID: taskID,
                printerName: printerName,
                commandText: commandText,
                pdfPath: pdfURL.path,
                dryRun: true
            ), settings: config.printSettings)
            return PhysicalPrintJob(ok: true, dryRun: true, duplicate: false, printerName: printerName, commandText: commandText, pdfURL: pdfURL, error: nil)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lpr")
        process.arguments = lprArgs
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw NSError(domain: "Tabooprint", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: stderr.isEmpty ? "lpr failed" : stderr])
            }
            emit("print-job", [
                "phase": .string("submitted"),
                "command": .string("lpr"),
                "requestID": .string(requestID),
                "taskID": .string(taskID),
                "printer": .string(printerName),
                "documentCount": .number(Double(docs.count)),
                "pdfPath": .string(pdfURL.path),
                "commandText": .string(commandText),
            ])
            rememberPhysicalPrint(dedupeKey, item: PhysicalPrintHistoryItem(
                timestampMs: Int(Date().timeIntervalSince1970 * 1000),
                requestID: requestID,
                taskID: taskID,
                printerName: printerName,
                commandText: commandText,
                pdfPath: pdfURL.path,
                dryRun: false
            ), settings: config.printSettings)
            return PhysicalPrintJob(ok: true, dryRun: false, duplicate: false, printerName: printerName, commandText: commandText, pdfURL: pdfURL, error: nil)
        } catch {
            emit("print-job", [
                "phase": .string("failed"),
                "command": .string("lpr"),
                "requestID": .string(requestID),
                "taskID": .string(taskID),
                "printer": .string(printerName),
                "documentCount": .number(Double(docs.count)),
                "pdfPath": .string(pdfURL.path),
                "commandText": .string(commandText),
                "error": .string(error.localizedDescription),
            ])
            return PhysicalPrintJob(ok: false, dryRun: false, duplicate: false, printerName: printerName, commandText: commandText, pdfURL: pdfURL, error: error.localizedDescription)
        }
    }

    /// 为物理打印生成一个 180° 旋转的 PDF 副本（PDF 标准 /Rotate，CUPS 栅格化必然遵守），
    /// 不修改原始预览 PDF。失败时回退到原 PDF，保证打印不中断。
    private func makeRotatedPDFForPrinting(source: URL) -> URL {
        guard let document = PDFDocument(url: source) else { return source }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            // PDFPage.rotation 以度为单位，按 90 的倍数累加，得到 180° 反转。
            page.rotation = (page.rotation + 180) % 360
        }
        let rotatedURL = source.deletingPathExtension()
            .appendingPathExtension("flipped.pdf")
        guard document.write(to: rotatedURL) else { return source }
        return rotatedURL
    }

    private func emit(_ type: String, _ fields: [String: JSONValue]) {
        let line = PrintServiceEvent(type: type, fields: fields).logLine()
        appendLogLine(line)
    }

    private func appendLog(_ line: String) {
        appendLogLine(line)
    }

    private func appendLogLine(_ line: String) {
        let sink = lock.withLock { () -> (@Sendable (String) -> Void)? in
            logLines.append(line)
            if logLines.count > 1200 {
                logLines.removeFirst(logLines.count - 1200)
            }
            return logSink
        }
        sink?(line)
    }
}

private final class WebSocketProtocolHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private weak var service: NativePrintService?
    private var buffer = ByteBuffer()
    private var opened = false

    init(service: NativePrintService) {
        self.service = service
    }

    func handlerAdded(context: ChannelHandlerContext) {
        opened = true
        service?.connectionOpened()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .connectionClose:
            context.close(promise: nil)
        case .ping:
            let data = frame.unmaskedData
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: data)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .text, .continuation:
            var data = frame.unmaskedData
            buffer.writeBuffer(&data)
            if frame.fin, let text = buffer.readString(length: buffer.readableBytes) {
                service?.handleWebSocketText(text, on: context.channel)
                buffer.clear()
            }
        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if opened {
            opened = false
            service?.connectionClosed("close")
        }
    }
}

private final class PreviewHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private weak var service: NativePrintService?
    private var requestHead: HTTPRequestHead?

    init(service: NativePrintService) {
        self.service = service
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            requestHead = head
        case .body:
            break
        case .end:
            respond(context: context)
        }
    }

    private func respond(context: ChannelHandlerContext) {
        guard let head = requestHead else { return }
        let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.uri
        if head.method == .OPTIONS {
            service?.recordPreviewHTTPRequest(method: head.method.rawValue, path: path, status: .noContent, byteCount: 0)
            send(context: context, status: .noContent, body: nil, method: head.method)
            return
        }
        guard path.hasPrefix("/file/") else {
            let body = Data("not found".utf8)
            service?.recordPreviewHTTPRequest(method: head.method.rawValue, path: path, status: .notFound, byteCount: body.count)
            send(context: context, status: .notFound, body: body, contentType: "text/plain; charset=utf-8", method: head.method)
            return
        }
        let name = String(path.dropFirst("/file/".count))
        let body = service?.servePDF(named: name) ?? NativeWaybillRenderer.minimalPDFData(title: "Cainiao Mock PDF")
        service?.recordPreviewHTTPRequest(method: head.method.rawValue, path: path, status: .ok, byteCount: body.count)
        send(context: context, status: .ok, body: body, contentType: "application/pdf", method: head.method)
    }

    private func send(context: ChannelHandlerContext, status: HTTPResponseStatus, body: Data?, contentType: String = "text/plain; charset=utf-8", method: HTTPMethod) {
        var headers = HTTPHeaders()
        headers.add(name: "Access-Control-Allow-Origin", value: "*")
        headers.add(name: "Access-Control-Allow-Methods", value: "GET, HEAD, OPTIONS")
        headers.add(name: "Access-Control-Allow-Headers", value: "*")
        headers.add(name: "Cache-Control", value: "no-store")
        if let body {
            headers.add(name: "Content-Type", value: contentType)
            headers.add(name: "Content-Length", value: "\(body.count)")
        }
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if let body, method != .HEAD {
            var buffer = context.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}

struct RenderResult: Sendable {
    let url: URL
    let fileName: String
    let documentIds: [String]
    var error: String?
}

struct ProtocolDocument: Sendable {
    let documentId: String
    let fingerprint: String
    let index: Int
}

private struct PhysicalPrintJob: Sendable {
    let ok: Bool
    let dryRun: Bool
    let duplicate: Bool
    let printerName: String
    let commandText: String
    let pdfURL: URL
    let error: String?
}

private struct PhysicalPrintHistoryItem: Sendable {
    let timestampMs: Int
    let requestID: String
    let taskID: String
    let printerName: String
    let commandText: String
    let pdfPath: String
    let dryRun: Bool
}

final class NativeWaybillRenderer: @unchecked Sendable {
    private let contentWidthMM: CGFloat = WaybillContentBox.widthMM
    private let contentHeightMM: CGFloat = WaybillContentBox.heightMM
    private let mmToPoint: CGFloat = 72 / 25.4

    func render(payload: [String: JSONValue], outputDirectory: URL, requestID: String, taskID: String, paperSize: PaperSize = PaperCatalog.default, hideTaoLogo: Bool = false, hideCourierPackage: Bool = false) throws -> RenderResult {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let fileName = "\(safeFilename(taskID)).pdf"
        let outputURL = outputDirectory.appendingPathComponent(fileName)
        let task = payload.object("task")
        let documents = task.array("documents").compactMap(\.objectValue)
        let ids = documents.enumerated().map { index, doc in
            doc.string("documentID", default: doc.string("documentId", default: "MOCK_DOC_\(index + 1)"))
        }

        // 外框 = 所选纸张尺寸（PDF mediaBox）。
        var pageRect = CGRect(x: 0, y: 0, width: paperSize.widthMM * mmToPoint, height: paperSize.heightMM * mmToPoint)
        // 内容盒固定 74×126mm，水平居中、垂直顶部对齐放入外框。
        let contentRect = contentRect(in: pageRect, paperSize: paperSize)
        guard let consumer = CGDataConsumer(url: outputURL as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &pageRect, nil) else {
            throw NSError(domain: "Tabooprint", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot create PDF"])
        }

        if documents.isEmpty {
            drawPage(context: context, pageRect: pageRect, contentRect: contentRect) {
                drawText("Tabooprint 空任务", at: CGPoint(x: 18, y: 32), size: 16, weight: .bold)
                drawText("requestID: \(requestID)", at: CGPoint(x: 18, y: 62), size: 8, weight: .regular)
                drawText("taskID: \(taskID)", at: CGPoint(x: 18, y: 76), size: 8, weight: .regular)
            }
        } else {
            for (index, document) in documents.enumerated() {
                drawDocument(context: context, pageRect: pageRect, contentRect: contentRect, payload: payload, document: document, requestID: requestID, taskID: taskID, index: index, count: documents.count, hideTaoLogo: hideTaoLogo, hideCourierPackage: hideCourierPackage)
            }
        }
        context.closePDF()
        return RenderResult(url: outputURL, fileName: fileName, documentIds: ids, error: nil)
    }

    /// 把 74×126mm 内容盒水平居中、顶部对齐放入纸张外框。
    private func contentRect(in pageRect: CGRect, paperSize: PaperSize) -> CGRect {
        let contentWidth = contentWidthMM * mmToPoint
        let contentHeight = contentHeightMM * mmToPoint
        let originX = max(0, (pageRect.width - contentWidth) / 2)
        // 顶部对齐：PDF 坐标系原点在左下，内容盒顶边贴纸张顶边。
        let originY = max(0, pageRect.height - contentHeight)
        return CGRect(x: originX, y: originY, width: contentWidth, height: contentHeight)
    }

    func writeFallbackPDF(outputDirectory: URL, requestID: String, taskID: String) -> RenderResult {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let fileName = "\(safeFilename(taskID)).pdf"
        let outputURL = outputDirectory.appendingPathComponent(fileName)
        try? Self.minimalPDFData(title: "Cainiao Mock PDF").write(to: outputURL)
        return RenderResult(url: outputURL, fileName: fileName, documentIds: [], error: nil)
    }

    static func minimalPDFData(title: String) -> Data {
        let text = """
        %PDF-1.4
        1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
        2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
        3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 300 144] /Contents 4 0 R >> endobj
        4 0 obj << /Length 44 >> stream
        BT /F1 18 Tf 36 72 Td (\(title)) Tj ET
        endstream endobj
        xref
        0 5
        0000000000 65535 f
        trailer << /Root 1 0 R /Size 5 >>
        startxref
        0
        %%EOF
        """
        return Data(text.utf8)
    }

    private func drawDocument(context: CGContext, pageRect: CGRect, contentRect: CGRect, payload: [String: JSONValue], document: [String: JSONValue], requestID: String, taskID: String, index: Int, count: Int, hideTaoLogo: Bool, hideCourierPackage: Bool) {
        drawPage(context: context, pageRect: pageRect, contentRect: contentRect) {
            let parts = splitContents(document)
            let decrypted = decryptWaybillContent(parts.standard)
            let customData = parts.custom.object("data")
            let docID = document.string("documentID", default: document.string("documentId", default: customData.string("WAIBILLNO_BAR_CODE", default: "MOCK_DOC")))
            drawCainiao300336(
                pageRect: pageRect,
                data: decrypted,
                standard: parts.standard,
                customData: customData,
                documentID: docID,
                pageNumber: index + 1,
                pageCount: count,
                hideTaoLogo: hideTaoLogo,
                hideCourierPackage: hideCourierPackage
            )
        }
    }

    private func drawPage(context: CGContext, pageRect: CGRect, contentRect: CGRect, draw: () -> Void) {
        context.beginPDFPage(nil)
        context.saveGState()
        context.setFillColor(NSColor.white.cgColor)
        context.fill(pageRect)
        // 平移到内容盒左上角，使内 mm() 绝对坐标落在居中/顶部对齐后的内容盒内。
        context.translateBy(x: contentRect.minX, y: contentRect.minY + contentRect.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
        context.endPDFPage()
    }

    private func splitContents(_ document: [String: JSONValue]) -> (standard: [String: JSONValue], custom: [String: JSONValue]) {
        var standard: [String: JSONValue] = [:]
        var custom: [String: JSONValue] = [:]
        for item in document.array("contents").compactMap(\.objectValue) {
            if item["encryptedData"] != nil || item["ver"] != nil {
                standard = item
            } else if item["data"] != nil {
                custom = item
            }
        }
        return (standard, custom)
    }

    private func decryptWaybillContent(_ standard: [String: JSONValue]) -> [String: JSONValue] {
        let encrypted = standard.string("encryptedData")
        guard encrypted.hasPrefix("AES:"),
              let cipherData = Data(base64Encoded: String(encrypted.dropFirst(4))) else {
            return [:]
        }
        let key = [UInt8]([0xCD, 0xBF, 0xFD, 0x0A, 0xC5, 0x9D, 0xE5, 0x6D, 0x3F, 0x17, 0xF9, 0x3A, 0x7E, 0xED, 0xFF, 0x57])
        do {
            let aes = try AES(key: key, blockMode: ECB(), padding: .pkcs7)
            let bytes = try aes.decrypt(Array(cipherData))
            return (try? JSONValue.parse(Data(bytes)).objectValue) ?? [:]
        } catch {
            return [:]
        }
    }

    private func drawCainiao300336(
        pageRect: CGRect,
        data: [String: JSONValue],
        standard: [String: JSONValue],
        customData: [String: JSONValue],
        documentID: String,
        pageNumber: Int,
        pageCount: Int,
        hideTaoLogo: Bool,
        hideCourierPackage: Bool
    ) {
        let values = buildTemplateValues(data: data, standard: standard, customData: customData, documentID: documentID, pageNumber: pageNumber, pageCount: pageCount)
        strokeMMRect(x: 5, y: 0.6, width: 65, height: 125.4, lineWidth: 0.4)
        if !hideTaoLogo {
            drawTemplateText("淘", x: 6.4, y: 2.58, width: 6.92, height: 5.31, size: 5.4, weight: .bold, align: .center, valign: .middle)
        }
        if !hideCourierPackage {
            drawTemplateText("快递\n包裹", x: 59, y: 0.8, width: 11, height: 11, size: 5.4, weight: .bold, align: .center, valign: .middle)
        }
        drawRotatedTemplateText(values.waybillCode, x: 0.6, y: 22, angle: 90, size: 3.2)
        drawRotatedTemplateText(values.waybillCode, x: 74.1, y: 22, angle: 90, size: 3.2)
        drawTemplateText(values.dateText, x: 5.8, y: 9, width: 13.4, height: 3, size: 2.7)
        drawTemplateText(values.timeText, x: 20.2, y: 9, width: 11.8, height: 3, size: 2.7, align: .center)
        drawTemplateText("第\(pageNumber)/\(pageCount)个", x: 34, y: 9, width: 16.03, height: 3, size: 2.7)
        drawTemplateText(values.datoubi.isEmpty ? "分拣码" : values.datoubi, x: 7.33, y: 12.24, width: 61, height: 8.41, size: 7, weight: .bold, align: .center, valign: .bottom)
        drawCode128(value: values.waybillCode, x: 8.65, y: 21.76, width: 57.85, height: 15.56, showText: true)
        drawTemplateText(values.consolidation, x: 12.86, y: 37.98, width: 27.44, height: 6.83, size: 5.2, weight: .bold, valign: .middle)
        drawTemplateText(values.prefixCode, x: 40.66, y: 38.1, width: 8.86, height: 6.85, size: 5.3, weight: .bold, fill: .white, background: .black, align: .center, valign: .middle)
        drawTemplateText(values.blockCode, x: 49.89, y: 38.58, width: 18.67, height: 6.42, size: 4.5, valign: .middle)

        drawTemplateText("收", x: 5.4, y: 37.97, width: 7, height: 7, size: 5.8, weight: .bold, align: .center, valign: .middle)
        drawTemplateText("寄", x: 5.1, y: 51.03, width: 6, height: 6, size: 4.8, weight: .bold, align: .center, valign: .middle)
        drawTemplateText("验", x: 5.44, y: 62.92, width: 4, height: 4, size: 3.2, weight: .bold, align: .center, valign: .middle)

        [
            (5.35, 12, 70, 12),
            (5.08, 21, 70, 21),
            (5.19, 37.79, 69.99, 37.79),
            (5.08, 45, 70, 45),
            (5.08, 50.03, 70, 50.03),
            (5.48, 63, 70, 63),
            (5.09, 68, 70, 68),
            (5.09, 76, 70.27, 76),
            (33, 68.5, 33, 76),
        ].forEach { line in
            strokeMMLine(x1: line.0, y1: line.1, x2: line.2, y2: line.3)
        }

        drawTemplateText(
            "\(values.recipientName)  \(values.recipientMobile)\n\(values.recipientAddress)",
            x: 11.84,
            y: 50.32,
            width: 57.74,
            height: 12.04,
            size: 3.7,
            wrap: true
        )
        drawTemplateText(
            "\(values.senderName)  \(values.senderMobile) \(values.senderAddressShort)",
            x: 9.97,
            y: 63.34,
            width: 58.82,
            height: 4.52,
            size: 2.8,
            valign: .middle,
            wrap: true
        )
        drawTemplateText(
            "本次服务适用中通官网(www.zto.com)公示的快递服务协议条款。您对此单的签收代表您已收到快件且包装完好无损。",
            x: 5.42,
            y: 68.68,
            width: 27.38,
            height: 6.61,
            size: 1.8,
            wrap: true
        )
        drawCode128(value: values.waybillCode, x: 34.51, y: 68.8, width: 32.86, height: 6.91, showText: false)

        if !values.privacyNumber.isEmpty {
            drawTemplateText("虚拟号码", x: 5.55, y: 45.51, width: 14.69, height: 4.48, size: 3.2, weight: .bold, fill: .white, background: .black, align: .center, valign: .middle)
            drawTemplateText(values.privacyNumber, x: 20.86, y: 45.3, width: 42.47, height: 4.81, size: 4.3, weight: .bold, valign: .middle)
        }

        drawCustomArea(customData)
    }

    private func buildTemplateValues(
        data: [String: JSONValue],
        standard: [String: JSONValue],
        customData: [String: JSONValue],
        documentID: String,
        pageNumber: Int,
        pageCount: Int
    ) -> WaybillTemplateValues {
        let routing = data.object("routingInfo")
        let sortation = routing.object("sortation")
        let consolidation = routing.object("consolidation")
        let sender = mergedSender(data: data, standard: standard)
        let recipient = data.object("recipient")
        let senderAddress = sender.object("address")
        let recipientAddress = recipient.object("address")
        let extra = data.object("extraInfo")
        let routeCode = routing.string("routeCode")
        let newBlockCode = routing.string("newBlockCode")
        let datoubi = [sortation.string("name"), routeCode, newBlockCode]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let secretMobile = recipient.string("secretConsigneeMobile")
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy/MM/dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"

        return WaybillTemplateValues(
            waybillCode: firstNonEmpty([data.string("waybillCode"), customData.string("WAIBILLNO_BAR_CODE"), documentID]),
            dateText: dateFormatter.string(from: now),
            timeText: timeFormatter.string(from: now),
            datoubi: datoubi,
            consolidation: consolidation.string("name"),
            blockCode: routing.string("blockCode"),
            prefixCode: extra.string("staDoorHome") == "true" ? "驿" : "末",
            privacyNumber: secretMobile.replacingOccurrences(of: "-", with: "转"),
            recipientName: recipient.string("name"),
            recipientMobile: firstNonEmpty([recipient.string("mobile"), recipient.string("phone")]),
            recipientAddress: formatAddress(recipientAddress, includeProvince: true),
            senderName: sender.string("name"),
            senderMobile: firstNonEmpty([sender.string("mobile"), sender.string("phone")]),
            senderAddressShort: formatAddress(senderAddress, includeProvince: false),
            itemInfo: customData.bool("showItemInfo") == false ? customData.string("PAGE_PRINT_TIPS") : customData.string("ITEM_INFO"),
            sellerMemo: customData.string("SELLER_MEMO"),
            buyerMemo: customData.string("BUYER_MEMO"),
            itemTotalCount: customData.string("ITEM_TOTAL_COUNT")
        )
    }

    private func mergedSender(data: [String: JSONValue], standard: [String: JSONValue]) -> [String: JSONValue] {
        var sender = data.object("sender")
        let addSender = standard.object("addData").object("sender")
        for (key, value) in addSender where sender[key] == nil || sender[key] == .string("") {
            sender[key] = value
        }
        return sender
    }

    private func drawCustomArea(_ customData: [String: JSONValue]) {
        let showItem = customData.bool("showItemInfo") ?? true
        let itemText = showItem ? customData.string("ITEM_INFO") : customData.string("PAGE_PRINT_TIPS")
        let itemFontSize = min(4.2, max(2.6, (Double(customData.string("itemInfoFontSize")) ?? 10) * 0.32))
        let contentX: CGFloat = 5.4
        let contentWidth: CGFloat = 53.2
        drawTemplateText(itemText, x: contentX, y: 76.6, width: 62, height: 7.4, size: itemFontSize, weight: .bold, wrap: true)
        drawTemplateText(customData.string("SELLER_MEMO"), x: contentX, y: 85.0, width: contentWidth, height: 7.0, size: 2.5, wrap: true)
        drawTemplateText(customData.string("BUYER_MEMO"), x: contentX, y: 92.8, width: contentWidth, height: 7.0, size: 2.5, wrap: true)
        drawTemplateText(customData.string("ITEM_TOTAL_COUNT"), x: 58.8, y: 97, width: 10.6, height: 9, size: 6.8, weight: .bold, fill: .darkGray, align: .center, valign: .middle)
    }

    private func drawTemplateText(
        _ value: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        fill: NSColor = .black,
        background: NSColor? = nil,
        align: TextAlign = .left,
        valign: VerticalAlign = .top,
        wrap: Bool = false
    ) {
        let rect = mmRect(x: x, y: y, width: width, height: height)
        if let background {
            background.setFill()
            rect.fill()
        }
        guard !value.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = align.nsAlignment
        paragraph.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        let font = NSFont.systemFont(ofSize: max(4.5, mm(size) * 0.72), weight: weight)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fill,
            .paragraphStyle: paragraph,
        ]
        let attributed = NSAttributedString(string: value, attributes: attrs)
        let measured = attributed.boundingRect(
            with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let drawHeight = min(rect.height, measured.height)
        let drawY: CGFloat
        switch valign {
        case .top:
            drawY = rect.minY
        case .middle:
            drawY = rect.minY + max(0, (rect.height - drawHeight) / 2)
        case .bottom:
            drawY = rect.maxY - drawHeight
        }
        attributed.draw(with: CGRect(x: rect.minX, y: drawY, width: rect.width, height: drawHeight), options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    private func drawRotatedTemplateText(_ value: String, x: CGFloat, y: CGFloat, angle: CGFloat, size: CGFloat) {
        guard !value.isEmpty else { return }
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        context?.translateBy(x: mm(x), y: mm(y))
        context?.rotate(by: angle * .pi / 180)
        drawTemplateText(value, x: 0, y: 0, width: 40, height: 4, size: size)
        context?.restoreGState()
    }

    private func drawCode128(value: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, showText: Bool) {
        guard !value.isEmpty else { return }
        let rect = mmRect(x: x, y: y, width: width, height: height)
        let pattern = code128Pattern(value)
        let barHeight = rect.height - (showText ? mm(3.8) : 0)
        let moduleWidth = max(0.45, rect.width / CGFloat(max(pattern.count, 1)))
        let barcodeWidth = min(rect.width, moduleWidth * CGFloat(pattern.count))
        var cursor = rect.minX + max(0, (rect.width - barcodeWidth) / 2)
        NSColor.black.setFill()
        for bit in pattern {
            if bit == "1" {
                CGRect(x: cursor, y: rect.minY, width: max(0.35, moduleWidth), height: barHeight).fill()
            }
            cursor += moduleWidth
        }
        if showText {
            drawTemplateText(value, x: x, y: y + height - 3.4, width: width, height: 3.2, size: 2.6, weight: .bold, align: .center)
        }
    }

    private func strokeMMRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, lineWidth: CGFloat) {
        NSColor.black.setStroke()
        let path = NSBezierPath(rect: mmRect(x: x, y: y, width: width, height: height))
        path.lineWidth = max(0.3, mm(lineWidth))
        path.stroke()
    }

    private func strokeMMLine(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat) {
        NSColor.black.setStroke()
        let path = NSBezierPath()
        path.move(to: CGPoint(x: mm(x1), y: mm(y1)))
        path.line(to: CGPoint(x: mm(x2), y: mm(y2)))
        path.lineWidth = 0.5
        path.stroke()
    }

    private func mmRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: mm(x), y: mm(y), width: mm(width), height: mm(height))
    }

    private func mm(_ value: CGFloat) -> CGFloat {
        value * mmToPoint
    }
}

private struct WaybillTemplateValues {
    let waybillCode: String
    let dateText: String
    let timeText: String
    let datoubi: String
    let consolidation: String
    let blockCode: String
    let prefixCode: String
    let privacyNumber: String
    let recipientName: String
    let recipientMobile: String
    let recipientAddress: String
    let senderName: String
    let senderMobile: String
    let senderAddressShort: String
    let itemInfo: String
    let sellerMemo: String
    let buyerMemo: String
    let itemTotalCount: String
}

private enum TextAlign {
    case left
    case center
    case right

    var nsAlignment: NSTextAlignment {
        switch self {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }
}

private enum VerticalAlign {
    case top
    case middle
    case bottom
}

private func documentNotFoundResponse(requestID: String, taskID: String) -> [String: JSONValue] {
    [
        "cmd": .string("print"),
        "requestID": .string(requestID),
        "taskID": .string(taskID),
        "status": .string("failed"),
        "msg": .string("document not found"),
        "errorCode": .number(11),
    ]
}

private func decryptFailureResponse(requestID: String, taskID: String, printer: String, documentId: String) -> [String: JSONValue] {
    [
        "cmd": .string("notifyDocResult"),
        "requestID": .string(requestID),
        "status": .string("rendered"),
        "printer": .string(printer),
        "taskId": .string(taskID),
        "documentId": .string(documentId),
        "code": .number(40),
        "detail": .string("Unknown encryption type."),
        "from": .object(["source": .string("decrypt")]),
    ]
}

private func buildNotifyPrintResult(requestID: String, taskID: String, printer: String, docs: [ProtocolDocument], spendTime: [String: JSONValue]) -> [String: JSONValue] {
    [
        "cmd": .string("notifyPrintResult"),
        "requestID": .string(requestID),
        "taskID": .string(taskID),
        "status": .number(0),
        "msg": .string("no error"),
        "taskStatus": .string("printed"),
        "printer": .string(printer),
        "evaluationSpendTime": spendTime["rendering"] ?? .number(160),
        "pendingSpendTime": spendTime["pending"] ?? .number(45),
        "downloadingSpendTime": spendTime["downloading"] ?? .number(15),
        "totalSpendTime": spendTime["total"] ?? .number(220),
        "printStatus": .array(docs.map { doc in
            .object([
                "documentID": .string(doc.documentId),
                "detail": .string(""),
                "msg": .string("no error"),
                "printer": .string(printer),
                "renderingSpendTime": spendTime["rendering"] ?? .number(160),
                "renderingStartTime": .string(nowTimestamp()),
                "status": .string("success"),
            ])
        }),
    ]
}

private func buildNotifyPrintFailureResult(requestID: String, taskID: String, printer: String, docs: [ProtocolDocument], error: String) -> [String: JSONValue] {
    [
        "cmd": .string("notifyPrintResult"),
        "requestID": .string(requestID),
        "taskID": .string(taskID),
        "status": .number(1),
        "msg": .string(error),
        "taskStatus": .string("failed"),
        "printer": .string(printer),
        "printStatus": .array(docs.map { doc in
            .object([
                "documentID": .string(doc.documentId),
                "detail": .string(error),
                "msg": .string(error),
                "printer": .string(printer),
                "status": .string("failed"),
            ])
        }),
    ]
}

private func describeRuntimeMode(_ config: PrintServiceConfiguration) -> String {
    switch config.runtimeMode {
    case .defaultPreview:
        return "default-preview"
    case .respectPreviewFlag:
        return "respect-preview-flag"
    case .failureDocumentNotFound:
        return "failure-document-not-found"
    case .failureDecrypt:
        return "failure-decrypt"
    }
}

private func describeTaskResult(shouldReturnPreview: Bool, physicalPrintJob: PhysicalPrintJob?) -> String {
    if shouldReturnPreview { return "preview" }
    guard let physicalPrintJob else { return "notifyPrintResult" }
    if !physicalPrintJob.ok { return "physical-print-failed" }
    if physicalPrintJob.duplicate { return "physical-duplicate-suppressed" }
    return physicalPrintJob.dryRun ? "physical-dry-run" : "physical-print"
}

func buildLprArgs(printerName: String, pdfURL: URL, settings: PrintSettings) -> [String] {
    var args = ["-P", printerName]
    if !settings.media.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        args += ["-o", "media=\(settings.media)"]
    }
    if settings.fitToPage {
        args += ["-o", "fit-to-page"]
    }
    args.append(pdfURL.path)
    return args
}

func buildPhysicalPrintDedupeKey(printerName: String, docs: [ProtocolDocument], settings: PrintSettings) -> String {
    let ids = docs.map(\.documentId).joined(separator: ",")
    let fingerprints = docs.map(\.fingerprint).joined(separator: ",")
    return [
        "physical",
        printerName,
        settings.media.isEmpty ? "(default-media)" : settings.media,
        settings.fitToPage ? "fit" : "nofit",
        settings.flipPrint ? "flip" : "noflip",
        ids,
        fingerprints,
    ].joined(separator: "|")
}

func buildDocumentFingerprint(_ document: [String: JSONValue]) -> String {
    var parts: [String] = [
        document.string("documentID", default: document.string("documentId")),
    ]
    for content in document.array("contents").compactMap(\.objectValue) {
        if let encrypted = content["encryptedData"]?.stringValue {
            parts.append("encrypted:\(content.string("ver")):\(content.string("templateURL")):\(hashText(encrypted))")
        }
        let data = content.object("data")
        if !data.isEmpty {
            parts.append("custom-template:\(content.string("templateURL"))")
            for key in ["ORDER_ID", "WAIBILLNO_BAR_CODE", "ITEM_INFO", "ITEM_TOTAL_COUNT", "SELLER_MEMO", "BUYER_MEMO"] {
                let value = data.string(key)
                if !value.isEmpty {
                    parts.append("\(key):\(value)")
                }
            }
        }
    }
    return hashText(parts.joined(separator: "|"))
}

private func hashText(_ text: String) -> String {
    let digest = SHA256.hash(data: Data(text.utf8))
    return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
}

private func shellDisplay(_ value: String) -> String {
    if value.range(of: #"^[A-Za-z0-9_./:=+-]+$"#, options: .regularExpression) != nil {
        return value
    }
    return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func nowTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter.string(from: Date())
}

private func millisecondsNow() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}

private func safeFilename(_ value: String) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
    let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
    let text = String(scalars)
    return text.isEmpty ? "tabooprint_\(millisecondsNow())" : text
}

/// 中文 lpstat 把打印机名与状态词连写（如「TAOBAO闲置」）。此函数剥掉分隔符及状态后缀，
/// 还原真实打印机名。既用于解析 lpstat 输出，也作为物理打印前的兜底清洗。
private func sanitizePrinterName(_ raw: String) -> String {
    var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let cut = name.firstIndex(where: { $0.isWhitespace || $0 == "，" || $0 == "," }) {
        name = String(name[..<cut])
    }
    for suffix in ["闲置", "现在正在打印", "正在打印", "已禁用", "已停用", "已停止"] {
        if let range = name.range(of: suffix) {
            name = String(name[..<range.lowerBound])
            break
        }
    }
    let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? raw : cleaned
}

private func discoverPrinterDevices(defaultPrinterName configuredDefault: String) -> [PrinterDevice] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/lpstat")
    process.arguments = ["-p", "-d"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return [PrinterDevice(name: configuredDefault, isDefault: true, isEnabled: true)]
    }

    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    var defaultPrinter = configuredDefault
    var devices: [PrinterDevice] = []
    for rawLine in output.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("system default destination:") || line.hasPrefix("系统默认目的位置") {
            defaultPrinter = line.components(separatedBy: CharacterSet(charactersIn: ":：")).last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? configuredDefault
            continue
        }
        let name: String?
        if line.hasPrefix("printer ") {
            name = line.split(separator: " ").dropFirst().first.map(String.init)
        } else if line.hasPrefix("打印机") {
            // 中文 lpstat 形如「打印机TAOBAO闲置，启用时间始于…」——名字后直接跟状态词，
            // 既无空格也无逗号分隔，交由 sanitizePrinterName 按状态关键词或标点截断。
            let stripped = sanitizePrinterName(line.replacingOccurrences(of: "打印机", with: ""))
            name = stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : stripped
        } else {
            name = nil
        }
        if let name, !name.isEmpty {
            let enabled = !line.localizedCaseInsensitiveContains("disabled") && !line.localizedCaseInsensitiveContains("已禁用")
            devices.append(PrinterDevice(name: name, isDefault: name == defaultPrinter, isEnabled: enabled))
        }
    }
    if !devices.contains(where: { $0.name == configuredDefault }) {
        devices.insert(PrinterDevice(name: configuredDefault, isDefault: devices.isEmpty, isEnabled: true), at: 0)
    }
    return devices
}

private func discoverProtocolPrinters() -> [PrinterDevice] {
    let configName = PrintSettings.current.printerName
    return discoverPrinterDevices(defaultPrinterName: configName)
}

private func defaultPrinterName(from printers: [PrinterDevice]) -> String {
    printers.first(where: \.isDefault)?.name ?? printers.first?.name ?? "TAOBAO"
}

private func modificationDate(_ url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
}

private func firstNonEmpty(_ values: [String]) -> String {
    values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
}

private func formatAddress(_ address: [String: JSONValue], includeProvince: Bool) -> String {
    let keys = includeProvince
        ? ["province", "city", "district", "town", "detail"]
        : ["city", "district", "town", "detail"]
    return keys.map { address.string($0) }.joined()
}

private func maskPhone(_ value: String) -> String {
    guard value.count >= 7 else { return value }
    let prefix = value.prefix(3)
    let suffix = value.suffix(4)
    return "\(prefix)****\(suffix)"
}

private func drawText(_ text: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    NSString(string: text.isEmpty ? "-" : text).draw(at: point, withAttributes: attrs)
}

private func drawWrapped(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat, maxLines: Int) {
    let font = NSFont.systemFont(ofSize: size)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    var currentY = y
    let chars = Array(text.isEmpty ? "-" : text)
    let perLine = max(1, Int(width / max(size * 0.62, 1)))
    for lineIndex in 0..<maxLines {
        let start = lineIndex * perLine
        guard start < chars.count else { break }
        let end = min(chars.count, start + perLine)
        NSString(string: String(chars[start..<end])).draw(at: CGPoint(x: x, y: currentY), withAttributes: attrs)
        currentY += size + 3
    }
}

private func strokeRect(_ rect: CGRect, width: CGFloat) {
    NSColor.black.setStroke()
    let path = NSBezierPath(rect: rect)
    path.lineWidth = width
    path.stroke()
}

private func strokeLine(y: CGFloat, pageRect: CGRect) {
    NSColor.black.setStroke()
    let path = NSBezierPath()
    path.move(to: CGPoint(x: 5, y: y))
    path.line(to: CGPoint(x: pageRect.width - 5, y: y))
    path.lineWidth = 0.8
    path.stroke()
}

private func drawBarcode(code: String, rect: CGRect) {
    NSColor.black.setFill()
    let chars = Array(code.isEmpty ? "TABOOPRINT" : code)
    let unit = rect.width / CGFloat(max(chars.count * 3, 1))
    var x = rect.minX
    for (index, char) in chars.enumerated() {
        let value = Int(char.unicodeScalars.first?.value ?? 1)
        let width = unit * CGFloat((value % 3) + 1)
        if index % 2 == 0 || value % 2 == 0 {
            CGRect(x: x, y: rect.minY, width: width, height: rect.height).fill()
        }
        x += width + unit
        if x > rect.maxX { break }
    }
}

private let code128Patterns = [
    "11011001100", "11001101100", "11001100110", "10010011000", "10010001100", "10001001100",
    "10011001000", "10011000100", "10001100100", "11001001000", "11001000100", "11000100100",
    "10110011100", "10011011100", "10011001110", "10111001100", "10011101100", "10011100110",
    "11001110010", "11001011100", "11001001110", "11011100100", "11001110100", "11101101110",
    "11101001100", "11100101100", "11100100110", "11101100100", "11100110100", "11100110010",
    "11011011000", "11011000110", "11000110110", "10100011000", "10001011000", "10001000110",
    "10110001000", "10001101000", "10001100010", "11010001000", "11000101000", "11000100010",
    "10110111000", "10110001110", "10001101110", "10111011000", "10111000110", "10001110110",
    "11101110110", "11010001110", "11000101110", "11011101000", "11011100010", "11011101110",
    "11101011000", "11101000110", "11100010110", "11101101000", "11101100010", "11100011010",
    "11101111010", "11001000010", "11110001010", "10100110000", "10100001100", "10010110000",
    "10010000110", "10000101100", "10000100110", "10110010000", "10110000100", "10011010000",
    "10011000010", "10000110100", "10000110010", "11000010010", "11001010000", "11110111010",
    "11000010100", "10001111010", "10100111100", "10010111100", "10010011110", "10111100100",
    "10011110100", "10011110010", "11110100100", "11110010100", "11110010010", "11011011110",
    "11011110110", "11110110110", "10101111000", "10100011110", "10001011110", "10111101000",
    "10111100010", "11110101000", "11110100010", "10111011110", "10111101110", "11101011110",
    "11110101110", "11010000100", "11010010000", "11010011100", "1100011101011",
]

func code128Pattern(_ value: String) -> String {
    guard !value.isEmpty else { return "" }
    var codes: [Int]
    if value.allSatisfy(\.isNumber), value.count >= 2 {
        let normalized = value.count.isMultiple(of: 2) ? value : "0\(value)"
        codes = [105]
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            codes.append(Int(normalized[index..<next]) ?? 0)
            index = next
        }
    } else {
        codes = [104]
        codes += value.map { char in
            let scalar = Int(char.unicodeScalars.first?.value ?? 32)
            return max(0, min(95, scalar - 32))
        }
    }
    var checksum = codes[0]
    for (index, code) in codes.dropFirst().enumerated() {
        checksum += (index + 1) * code
    }
    codes.append(checksum % 103)
    codes.append(106)
    return codes.map { code128Patterns[$0] }.joined()
}

extension NativePrintService {
    private func findDuplicatePhysicalPrint(_ dedupeKey: String, settings: PrintSettings) -> PhysicalPrintHistoryItem? {
        guard settings.dedupe, settings.dedupeWindowMinutes > 0 else { return nil }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        return lock.withLock {
            purgePhysicalPrintHistory(now: now, settings: settings)
            guard let item = physicalPrintHistory[dedupeKey],
                  now - item.timestampMs <= settings.dedupeWindowMinutes * 60 * 1000 else {
                physicalPrintHistory.removeValue(forKey: dedupeKey)
                return nil
            }
            return item
        }
    }

    private func rememberPhysicalPrint(_ dedupeKey: String, item: PhysicalPrintHistoryItem, settings: PrintSettings) {
        guard settings.dedupe, settings.dedupeWindowMinutes > 0 else { return }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        lock.withLock {
            purgePhysicalPrintHistory(now: now, settings: settings)
            physicalPrintHistory[dedupeKey] = item
        }
    }

    private func purgePhysicalPrintHistory(now: Int, settings: PrintSettings) {
        let window = settings.dedupeWindowMinutes * 60 * 1000
        for (key, item) in physicalPrintHistory where now - item.timestampMs > window {
            physicalPrintHistory.removeValue(forKey: key)
        }
    }

    static func parseRecentTasks(from lines: [String]) -> [RecentTask] {
        var tasks: [String: RecentTask] = [:]
        for line in lines {
            guard let event = decodeEvent(from: line),
                  event.string("type") == "task",
                  let requestID = event["requestID"]?.stringValue else {
                continue
            }
            let phase = event.string("phase")
            var task = tasks[requestID] ?? RecentTask(
                id: requestID,
                timestampText: event.string("time"),
                command: event.string("command", default: "print"),
                requestID: requestID,
                documentCount: Int(Double(event["documentCount"]?.stringValue ?? "0") ?? 0),
                mode: event.string("mode"),
                result: event.string("result", default: "in-progress"),
                isInProgress: phase != "finish"
            )
            task.timestampText = event.string("time", default: task.timestampText)
            task.command = event.string("command", default: task.command)
            task.documentCount = Int(Double(event["documentCount"]?.stringValue ?? "\(task.documentCount)") ?? Double(task.documentCount))
            task.mode = event.string("mode", default: task.mode)
            task.result = event.string("result", default: task.result)
            if phase == "finish" {
                task.isInProgress = false
            } else if phase == "start" {
                task.isInProgress = true
            }
            tasks[requestID] = task
        }
        return tasks.values.sorted {
            if $0.timestampText == $1.timestampText { return $0.requestID > $1.requestID }
            return $0.timestampText > $1.timestampText
        }
    }

    static func parsePrintJobs(from lines: [String], fallbackPrinter: String) -> [PrintJob] {
        var jobs: [String: (job: PrintJob, timestampText: String)] = [:]
        for line in lines {
            guard let event = decodeEvent(from: line),
                  event.string("type") == "print-job",
                  let id = event["requestID"]?.stringValue ?? event["taskID"]?.stringValue else {
                continue
            }
            let phase = event.string("phase")
            let status: PrintJobStatus
            switch phase {
            case "duplicate-suppressed":
                status = .skippedDuplicate
            case "dry-run":
                status = .dryRun
            case "submitted":
                status = .submitted
            case "failed":
                status = .failed
            default:
                status = .pending
            }
            let error = event.string("error")
            let duplicateMessage = phase == "duplicate-suppressed" ? "10 分钟窗口内重复提交，已按去重依据跳过 lpr" : nil
            jobs[id] = (PrintJob(
                id: id,
                waybillCode: event.string("taskID", default: id),
                printerName: event.string("printer", default: fallbackPrinter),
                pdfPath: event.string("pdfPath", default: event.string("previousPdfPath")),
                status: status,
                errorMessage: error.isEmpty ? duplicateMessage : error,
                commandText: event.string("commandText", default: event.string("previousCommandText"))
            ), event.string("time"))
        }
        return jobs.values.sorted {
            if $0.timestampText == $1.timestampText { return $0.job.id > $1.job.id }
            return $0.timestampText > $1.timestampText
        }.map(\.job)
    }

    private static func decodeEvent(from line: String) -> [String: JSONValue]? {
        let prefix = "[cainiao-mock:event] "
        guard line.hasPrefix(prefix) else { return nil }
        return try? JSONValue.parse(String(line.dropFirst(prefix.count))).objectValue
    }
}

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
