import AppKit
import Foundation

// MARK: - 语义化版本比对

/// 极简语义化版本:解析 `v?` 前缀 + `.` 分段整数比较。非法输入安全兜底。
struct SemVer: Comparable, CustomStringConvertible {
    let components: [Int]
    let raw: String

    init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        let stripped = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst())
            : trimmed
        // 去掉预发布/构建后缀(如 1.2.0-beta.1 → 1.2.0),只比数字主体。
        let core = stripped.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? stripped
        let parts = core.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        components = parts.compactMap { $0 }
        raw = trimmed
    }

    var description: String { raw }

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for i in 0..<count {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    static func == (lhs: SemVer, rhs: SemVer) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for i in 0..<count {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return false }
        }
        return true
    }

    /// `candidate` 是否比 `current` 新。任一无法解析时返回 false(不误报升级)。
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let c = SemVer(candidate), let cur = SemVer(current) else { return false }
        return c > cur
    }
}

// MARK: - Release 模型

/// 从 GitHub Releases API 解析出的新版本信息。
struct ReleaseInfo: Equatable {
    let version: String       // tag_name,如 "v1.1.2"
    let name: String          // release 标题
    let notes: String         // release body(更新说明)
    let htmlURL: URL          // release 网页
    let zipURL: URL?          // *.app.zip 资产下载地址(可能缺失)
}

// MARK: - GitHub API DTO

private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: String
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case assets
    }
}

// MARK: - 更新检查服务

/// 半自动在线更新:检查 GitHub 最新 Release → 比对版本 → 下载 `.app.zip` 并解压到 Downloads →
/// Finder 选中,引导用户拖入应用程序并执行 xattr 解隔离。**不**自动替换重启(未签名下会被 Gatekeeper 拦)。
@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate(current: String)
        case available(ReleaseInfo)
        case downloading(progress: Double)
        case downloaded(appURL: URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// 解隔离命令(限定到本 App,不误伤其他应用)。
    static let xattrCommand = "sudo xattr -cr /Applications/PrintArk.app"

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/amm10090/PrintArk/releases/latest")!

    private var downloadDelegate: DownloadDelegate?

    // MARK: 检查

    /// 拉取最新 Release 并与当前版本比对。`silent` 为真时(启动自检)不把"已最新"展示为打扰态。
    func checkForUpdates(silent: Bool = false) {
        state = .checking
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PrintArk", forHTTPHeaderField: "User-Agent")

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    finish(.failed("无法连接更新服务器"), silent: silent)
                    return
                }
                if http.statusCode == 403,
                   http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                    finish(.failed("GitHub API 请求过于频繁,请稍后再试"), silent: silent)
                    return
                }
                if http.statusCode == 404 {
                    finish(.failed("尚未发布任何版本"), silent: silent)
                    return
                }
                guard http.statusCode == 200 else {
                    finish(.failed("更新检查失败(HTTP \(http.statusCode))"), silent: silent)
                    return
                }

                let decoder = JSONDecoder()
                let release = try decoder.decode(GitHubRelease.self, from: data)
                let current = AppInfo.version

                guard SemVer.isNewer(release.tagName, than: current) else {
                    finish(.upToDate(current: current), silent: silent)
                    return
                }

                let zipAsset = release.assets.first { $0.name.hasSuffix(".app.zip") }
                let info = ReleaseInfo(
                    version: release.tagName,
                    name: release.name ?? release.tagName,
                    notes: release.body ?? "",
                    htmlURL: URL(string: release.htmlURL) ?? Self.latestReleaseURL,
                    zipURL: zipAsset.flatMap { URL(string: $0.browserDownloadURL) }
                )
                finish(.available(info), silent: false) // 有新版总是提示,即便 silent 检查
            } catch is DecodingError {
                finish(.failed("解析更新信息失败"), silent: silent)
            } catch {
                finish(.failed("网络错误:\(error.localizedDescription)"), silent: silent)
            }
        }
    }

    /// 静默检查时,把"已最新/失败"回落到 idle(不打扰);有新版仍照常展示。
    private func finish(_ newState: State, silent: Bool) {
        if silent {
            switch newState {
            case .available:
                state = newState
            default:
                state = .idle
            }
        } else {
            state = newState
        }
    }

    // MARK: 下载 + 解压

    /// 下载 `.app.zip` 到 ~/Downloads,用 ditto 解压,Finder 选中解压出的 .app。
    func downloadUpdate(_ info: ReleaseInfo) {
        guard let zipURL = info.zipURL else {
            state = .failed("该版本未附带可下载的 .app 产物,请前往 Release 页手动下载")
            return
        }
        state = .downloading(progress: 0)

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let zipDest = downloads.appendingPathComponent("PrintArk-\(info.version).app.zip")

        let delegate = DownloadDelegate(
            targetURL: zipDest,
            progress: { [weak self] fraction in
                Task { @MainActor in self?.state = .downloading(progress: fraction) }
            },
            completion: { [weak self] result in
                Task { @MainActor in self?.handleDownloadResult(result, zipDest: zipDest, downloads: downloads) }
            }
        )
        downloadDelegate = delegate
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        session.downloadTask(with: zipURL).resume()
    }

    private func handleDownloadResult(_ result: Result<URL, Error>, zipDest: URL, downloads: URL) {
        switch result {
        case .failure(let error):
            state = .failed("下载失败:\(error.localizedDescription)")
        case .success:
            // 解压:ditto -x -k <zip> <downloads>
            do {
                let unzipped = try unzip(zipDest, into: downloads)
                NSWorkspace.shared.activateFileViewerSelecting([unzipped])
                state = .downloaded(appURL: unzipped)
            } catch {
                state = .failed("解压失败:\(error.localizedDescription)")
            }
        }
    }

    /// 用系统 ditto 解压,返回解压出的 PrintArk.app 路径。
    private func unzip(_ zip: URL, into directory: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, directory.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "PrintArk.Update", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? "ditto 解压失败" : msg])
        }
        let appURL = directory.appendingPathComponent("PrintArk.app")
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw NSError(domain: "PrintArk.Update", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "解压完成但未找到 PrintArk.app"])
        }
        return appURL
    }

    /// 打开 Release 网页(兜底)。
    func openReleasePage(_ info: ReleaseInfo) {
        NSWorkspace.shared.open(info.htmlURL)
    }

    /// 复制 xattr 解隔离命令到剪贴板。
    func copyXattrCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.xattrCommand, forType: .string)
    }
}

// MARK: - 下载进度代理

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    // 目标路径在 init 时确定且不可变,从构造上消除"didFinish 早于赋值"的竞态。
    private let targetURL: URL
    private let progress: @Sendable (Double) -> Void
    private let completion: @Sendable (Result<URL, Error>) -> Void

    init(targetURL: URL, progress: @escaping @Sendable (Double) -> Void, completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        self.targetURL = targetURL
        self.progress = progress
        self.completion = completion
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let target = targetURL
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: location, to: target)
            completion(.success(target))
        } catch {
            completion(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            completion(.failure(error))
        }
    }
}
