import XCTest
@testable import Tabooprint

final class TabooprintTests: XCTestCase {
    func testRuntimeModeMapsToShellArguments() {
        XCTAssertTrue(RuntimeMode.defaultPreview.shellArguments.isEmpty)
        XCTAssertEqual(RuntimeMode.respectPreviewFlag.shellArguments, ["--force-preview", "false"])
        XCTAssertEqual(RuntimeMode.failureDocumentNotFound.shellArguments, ["--fail", "document-not-found"])
        XCTAssertEqual(RuntimeMode.failureDecrypt.shellArguments, ["--fail", "decrypt"])
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

    func testPrintSettingsDefaultToDryRun() {
        let settings = PrintSettings(printerName: "TAOBAO", media: "100x180mm", dryRun: true)

        XCTAssertEqual(settings.shellArguments, [
            "--printer-name", "TAOBAO",
            "--print-dry-run", "true",
            "--print-media", "100x180mm",
        ])
    }

    func testRealPrintMustBeExplicit() {
        let settings = PrintSettings(printerName: "TAOBAO", media: "", dryRun: false)

        XCTAssertEqual(settings.shellArguments, [
            "--printer-name", "TAOBAO",
            "--print-dry-run", "false",
        ])
    }

    func testWaybillRendererScriptIsBundled() {
        let renderer = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/render_waybill_pdf.py")

        XCTAssertTrue(FileManager.default.fileExists(atPath: renderer.path))
    }

    func testWaybillRendererUsesRealTemplatePipeline() throws {
        let renderer = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/render_waybill_pdf.py")
        let source = try String(contentsOf: renderer, encoding: .utf8)

        XCTAssertTrue(source.contains("PAGE_W_MM = 74"))
        XCTAssertTrue(source.contains("PAGE_H_MM = 126"))
        XCTAssertTrue(source.contains("waybill_print_secret_version_1"))
        XCTAssertTrue(source.contains("draw_cainiao_300336"))
    }

    func testMockServiceIncludesPhysicalPrintDedupe() throws {
        let service = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/mock_cainiao_server.js")
        let source = try String(contentsOf: service, encoding: .utf8)

        XCTAssertTrue(source.contains("print-dedupe"))
        XCTAssertTrue(source.contains("dedupe-window-ms"))
        XCTAssertTrue(source.contains("duplicate-suppressed"))
    }
}
