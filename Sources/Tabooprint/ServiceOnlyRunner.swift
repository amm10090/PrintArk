import Foundation

enum ServiceOnlyRunner {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments.dropFirst()
        guard arguments.contains("--service-only") else {
            return false
        }

        let runtimeMode = runtimeMode(from: arguments)
        let autoOpenPreview = value(after: "--auto-open-preview", in: arguments) != "false"
        let printSettings = PrintSettings(
            printerName: value(after: "--printer-name", in: arguments) ?? "TAOBAO",
            media: value(after: "--print-media", in: arguments) ?? "100x180mm",
            dryRun: value(after: "--print-dry-run", in: arguments) != "false",
            fitToPage: value(after: "--print-fit-to-page", in: arguments) != "false",
            dedupe: value(after: "--print-dedupe", in: arguments) != "false",
            dedupeWindowMinutes: Int((Double(value(after: "--dedupe-window-ms", in: arguments) ?? "600000") ?? 600000) / 60000),
            hideTaoLogo: value(after: "--hide-tao-logo", in: arguments) == "true",
            hideCourierPackage: value(after: "--hide-courier-package", in: arguments) == "true",
            hideBorder: value(after: "--hide-border", in: arguments) == "true"
        )
        let configuration = PrintServiceConfiguration(
            host: value(after: "--host", in: arguments) ?? "127.0.0.1",
            webSocketPort: Int(value(after: "--ws-port", in: arguments) ?? "13528") ?? 13528,
            httpPort: Int(value(after: "--http-port", in: arguments) ?? "13525") ?? 13525,
            runtimeMode: runtimeMode,
            autoOpenPreview: autoOpenPreview,
            printSettings: printSettings
        )
        let service = NativePrintService()
        service.setLogSink { line in
            print(line)
            fflush(stdout)
        }
        let result = service.start(configuration: configuration)
        print(result.output)
        guard result.exitCode == 0 else {
            exit(result.exitCode)
        }

        signal(SIGINT) { _ in
            exit(0)
        }
        signal(SIGTERM) { _ in
            exit(0)
        }
        RunLoop.current.run()
        return true
    }

    private static func runtimeMode(from arguments: ArraySlice<String>) -> RuntimeMode {
        if value(after: "--fail", in: arguments) == "document-not-found" {
            return .failureDocumentNotFound
        }
        if value(after: "--fail", in: arguments) == "decrypt" {
            return .failureDecrypt
        }
        if value(after: "--force-preview", in: arguments) == "false" {
            return .respectPreviewFlag
        }
        return .defaultPreview
    }

    private static func value(after key: String, in arguments: ArraySlice<String>) -> String? {
        let array = Array(arguments)
        guard let index = array.firstIndex(of: key), index + 1 < array.count else {
            return nil
        }
        return array[index + 1]
    }
}
