import Foundation
@preconcurrency import NIOSSL

struct WSSCertificateMaterial: Sendable, Equatable {
    var certificatePath: String
    var privateKeyPath: String

    static func loadOrCreate() -> WSSCertificateMaterial? {
        try? LocalTLSIdentityManager().loadOrCreate()
    }
}

enum LocalTLSTrustState: Equatable, Sendable {
    case missing
    case untrusted
    case trusted
    case failed

    var displayText: String {
        switch self {
        case .missing: return "本机证书不可用"
        case .untrusted: return "本机证书未信任"
        case .trusted: return "本机证书已信任"
        case .failed: return "本机证书状态异常"
        }
    }
}

struct LocalTLSTrustInstallResult: Equatable, Sendable {
    let succeeded: Bool
    let message: String
}

struct LocalTLSIdentityManager: Sendable {
    static let directoryName = "localhost-tls"

    let directory: URL

    init(directory: URL = LocalTLSIdentityManager.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/PrintArk", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    func loadOrCreate() throws -> WSSCertificateMaterial {
        let material = certificateMaterial
        if filesExist(material), isValid(material) {
            try securePermissions(material)
            return material
        }

        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporaryDirectory = directory.deletingLastPathComponent()
            .appendingPathComponent(".\(Self.directoryName)-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let temporaryMaterial = WSSCertificateMaterial(
            certificatePath: temporaryDirectory.appendingPathComponent("server.crt").path,
            privateKeyPath: temporaryDirectory.appendingPathComponent("server.key").path
        )
        let configURL = temporaryDirectory.appendingPathComponent("openssl.cnf")
        try Data(Self.opensslConfiguration.utf8).write(to: configURL, options: .atomic)

        let generation = try runProcess(
            executable: "/usr/bin/openssl",
            arguments: [
                "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-sha256", "-days", "3650",
                "-keyout", temporaryMaterial.privateKeyPath,
                "-out", temporaryMaterial.certificatePath,
                "-config", configURL.path,
            ]
        )
        guard generation.status == 0, isValid(temporaryMaterial) else {
            throw LocalTLSIdentityError.generationFailed
        }
        try securePermissions(temporaryMaterial)

        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.moveItem(at: temporaryDirectory, to: directory)
        try securePermissions(material)
        guard isValid(material) else { throw LocalTLSIdentityError.validationFailed }
        return material
    }

    func trustState() -> LocalTLSTrustState {
        guard let material = try? loadOrCreate() else { return .missing }
        do {
            let result = try runProcess(
                executable: "/usr/bin/security",
                arguments: ["verify-cert", "-c", material.certificatePath, "-p", "ssl", "-n", "localhost", "-L", "-q"]
            )
            return result.status == 0 ? .trusted : .untrusted
        } catch {
            return .failed
        }
    }

    func installTrust() -> LocalTLSTrustInstallResult {
        guard let material = try? loadOrCreate() else {
            return LocalTLSTrustInstallResult(succeeded: false, message: "无法生成本机证书")
        }
        let keychain = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Keychains/login.keychain-db").path
        do {
            let result = try runProcess(
                executable: "/usr/bin/security",
                arguments: [
                    "add-trusted-cert", "-r", "trustRoot", "-p", "ssl",
                    "-k", keychain, material.certificatePath,
                ]
            )
            guard result.status == 0 else {
                return LocalTLSTrustInstallResult(succeeded: false, message: "证书安装失败（状态 \(result.status)）")
            }
            return trustState() == .trusted
                ? LocalTLSTrustInstallResult(succeeded: true, message: "本机证书已安装并信任")
                : LocalTLSTrustInstallResult(succeeded: false, message: "证书已写入，但系统信任校验未通过")
        } catch {
            return LocalTLSTrustInstallResult(succeeded: false, message: "无法调用系统钥匙串工具")
        }
    }

    private var certificateMaterial: WSSCertificateMaterial {
        WSSCertificateMaterial(
            certificatePath: directory.appendingPathComponent("server.crt").path,
            privateKeyPath: directory.appendingPathComponent("server.key").path
        )
    }

    private func filesExist(_ material: WSSCertificateMaterial) -> Bool {
        FileManager.default.fileExists(atPath: material.certificatePath)
            && FileManager.default.fileExists(atPath: material.privateKeyPath)
    }

    private func isValid(_ material: WSSCertificateMaterial) -> Bool {
        guard filesExist(material),
              (try? NIOSSLCertificate.fromPEMFile(material.certificatePath).isEmpty) == false,
              (try? NIOSSLPrivateKey(file: material.privateKeyPath, format: .pem)) != nil else {
            return false
        }
        return true
    }

    private func securePermissions(_ material: WSSCertificateMaterial) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: material.certificatePath) {
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: material.certificatePath)
        }
        if fileManager.fileExists(atPath: material.privateKeyPath) {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: material.privateKeyPath)
        }
    }

    private static let opensslConfiguration = """
    [req]
    distinguished_name = distinguished_name
    x509_extensions = server_extensions
    prompt = no

    [distinguished_name]
    CN = localhost
    O = PrintArk
    OU = Local Print Service

    [server_extensions]
    basicConstraints = critical,CA:FALSE
    keyUsage = critical,digitalSignature,keyEncipherment
    extendedKeyUsage = serverAuth
    subjectAltName = @subject_alt_names

    [subject_alt_names]
    DNS.1 = localhost
    IP.1 = 127.0.0.1
    """
}

enum LocalTLSIdentityError: Error {
    case generationFailed
    case validationFailed
}

private struct LocalProcessResult {
    let status: Int32
}

private func runProcess(executable: String, arguments: [String]) throws -> LocalProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    return LocalProcessResult(status: process.terminationStatus)
}
