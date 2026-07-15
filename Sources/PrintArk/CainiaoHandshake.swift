import CryptoKit
import Darwin
import Foundation

struct CainiaoHandshakeCredentials: Equatable, Sendable {
    static let appKeyEnvironmentName = "PRINTARK_CAINIAO_APP_KEY"
    static let appSecretEnvironmentName = "PRINTARK_CAINIAO_APP_SECRET"

    let appKey: String
    let appSecret: String

    init?(appKey: String, appSecret: String) {
        let normalizedKey = appKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSecret = appSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty, !normalizedSecret.isEmpty else { return nil }
        self.appKey = normalizedKey
        self.appSecret = normalizedSecret
    }

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        privateFileURL: URL? = defaultPrivateFileURL
    ) -> CainiaoHandshakeCredentials? {
        if let credentials = CainiaoHandshakeCredentials(
            appKey: environment[appKeyEnvironmentName] ?? "",
            appSecret: environment[appSecretEnvironmentName] ?? ""
        ) {
            return credentials
        }

        if let resourceURL = bundle.url(forResource: "CainiaoHandshake", withExtension: "plist"),
           let credentials = loadPlist(at: resourceURL) {
            return credentials
        }

        if let privateFileURL, let credentials = loadPlist(at: privateFileURL) {
            return credentials
        }
        return nil
    }

    static var defaultPrivateFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/PrintArk/build-secrets", isDirectory: true)
            .appendingPathComponent("CainiaoHandshake.plist")
    }

    private static func loadPlist(at url: URL) -> CainiaoHandshakeCredentials? {
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return CainiaoHandshakeCredentials(
            appKey: dictionary["appKey"] as? String ?? "",
            appSecret: dictionary["appSecret"] as? String ?? ""
        )
    }
}

struct CainiaoMachineIdentity: Equatable, Sendable {
    let guid: String
    let macAddress: String

    var protocolValue: String { "\(guid)|\(macAddress)" }
}

protocol CainiaoMachineIdentityProviding: Sendable {
    func resolve() -> CainiaoMachineIdentity
}

final class DefaultCainiaoMachineIdentityProvider: CainiaoMachineIdentityProviding, @unchecked Sendable {
    static let guidDefaultsKey = "printark.cainiaoMachineGUID"

    private let defaults: UserDefaults
    private let macAddressProvider: @Sendable () -> String?

    init(
        defaults: UserDefaults = .standard,
        macAddressProvider: @escaping @Sendable () -> String? = discoverPrimaryMACAddress
    ) {
        self.defaults = defaults
        self.macAddressProvider = macAddressProvider
    }

    func resolve() -> CainiaoMachineIdentity {
        let guid: String
        if let stored = defaults.string(forKey: Self.guidDefaultsKey), !stored.isEmpty {
            guid = stored
        } else {
            guid = UUID().uuidString.lowercased()
            defaults.set(guid, forKey: Self.guidDefaultsKey)
        }
        return CainiaoMachineIdentity(
            guid: guid,
            macAddress: macAddressProvider() ?? Self.fallbackMACAddress(seed: guid)
        )
    }

    static func fallbackMACAddress(seed: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(6))
        bytes[0] = (bytes[0] | 0x02) & 0xFE
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

struct CainiaoHandshakeEnvironment: Equatable, Sendable {
    var system = "Mac OS X"
    var architecture: String
    var lanIP: String

    static func current() -> CainiaoHandshakeEnvironment {
        CainiaoHandshakeEnvironment(
            architecture: currentArchitecture(),
            lanIP: discoverPrimaryIPv4Address() ?? "127.0.0.1"
        )
    }
}

struct CainiaoHandshakeRequestBuilder: Sendable {
    static let endpoint = URL(string: "https://cloudprint.cainiao.com/cloudprint/clientApi/invoke.json")!
    static let method = "cainiao.waybillprint.clientupdate.getconfig"
    static let clientVersion = "1.5.3"

    let credentials: CainiaoHandshakeCredentials
    let identity: CainiaoMachineIdentity
    let environment: CainiaoHandshakeEnvironment
    let date: Date

    func makeURLRequest() throws -> URLRequest {
        let timestamp = Self.timestampFormatter.string(from: date)
        let commonParameters = [
            "app_key": credentials.appKey,
            "format": "json",
            "mac": identity.protocolValue,
            "method": Self.method,
            "sign_method": "md5",
            "timestamp": timestamp,
            "v": "2.0",
        ]

        let jsonData: [String: Any] = [
            "architecture": environment.architecture,
            "clientVersion": Self.clientVersion,
            "hashCode": Self.javaStringHashCode(identity.protocolValue),
            "lan_ip": environment.lanIP,
            "mac": identity.protocolValue,
            "macAddr": identity.protocolValue,
            "msgId": "msgId",
            "system": environment.system,
            "timestamp": timestamp,
            "version": Self.clientVersion,
        ]
        let encodedJSON = try JSONSerialization.data(withJSONObject: jsonData, options: [.sortedKeys])
        guard let jsonText = String(data: encodedJSON, encoding: .utf8) else {
            throw CainiaoHandshakeError.invalidRequest
        }

        var form = commonParameters
        form["json_data"] = jsonText
        form["sign"] = signature(for: commonParameters)

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Windows NT 6.1; WOW64; rv:221.0) Gecko/20100101 Firefox/31.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = Self.formEncode(form)
        return request
    }

    func signature(for commonParameters: [String: String]) -> String {
        var text = credentials.appSecret
        for key in commonParameters.keys.sorted() {
            guard let value = commonParameters[key], !key.isEmpty, !value.isEmpty else { continue }
            text += key + value
        }
        text += credentials.appSecret
        return Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    static func javaStringHashCode(_ value: String) -> Int32 {
        value.utf16.reduce(Int32(0)) { partial, codeUnit in
            partial &* 31 &+ Int32(codeUnit)
        }
    }

    static func formEncode(_ parameters: [String: String]) -> Data {
        let text = parameters.keys.sorted().compactMap { key -> String? in
            guard let value = parameters[key] else { return nil }
            return "\(percentEncode(key))=\(percentEncode(value))"
        }.joined(separator: "&")
        return Data(text.utf8)
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)?.replacingOccurrences(of: "%20", with: "+") ?? ""
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

protocol CainiaoHandshakeTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionCainiaoHandshakeTransport: CainiaoHandshakeTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CainiaoHandshakeError.invalidResponse
        }
        return (data, httpResponse)
    }
}

enum CainiaoHandshakeError: Error, Equatable, Sendable {
    case credentialsMissing
    case invalidRequest
    case invalidResponse
    case httpStatus(Int)
    case responseShape

    var category: String {
        switch self {
        case .credentialsMissing: return "credentials-missing"
        case .invalidRequest: return "invalid-request"
        case .invalidResponse: return "invalid-response"
        case .httpStatus: return "http-status"
        case .responseShape: return "response-shape"
        }
    }
}

struct CainiaoHandshakeSuccess: Equatable, Sendable {
    let statusCode: Int
}

struct CainiaoHandshakeClient<Transport: CainiaoHandshakeTransport>: Sendable {
    let credentials: CainiaoHandshakeCredentials
    let identityProvider: any CainiaoMachineIdentityProviding
    let environmentProvider: @Sendable () -> CainiaoHandshakeEnvironment
    let dateProvider: @Sendable () -> Date
    let transport: Transport

    init(
        credentials: CainiaoHandshakeCredentials,
        identityProvider: any CainiaoMachineIdentityProviding = DefaultCainiaoMachineIdentityProvider(),
        environmentProvider: @escaping @Sendable () -> CainiaoHandshakeEnvironment = CainiaoHandshakeEnvironment.current,
        dateProvider: @escaping @Sendable () -> Date = Date.init,
        transport: Transport
    ) {
        self.credentials = credentials
        self.identityProvider = identityProvider
        self.environmentProvider = environmentProvider
        self.dateProvider = dateProvider
        self.transport = transport
    }

    func perform() async throws -> CainiaoHandshakeSuccess {
        let request = try CainiaoHandshakeRequestBuilder(
            credentials: credentials,
            identity: identityProvider.resolve(),
            environment: environmentProvider(),
            date: dateProvider()
        ).makeURLRequest()
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw CainiaoHandshakeError.httpStatus(response.statusCode)
        }
        guard Self.hasExpectedResponseShape(data) else {
            throw CainiaoHandshakeError.responseShape
        }
        return CainiaoHandshakeSuccess(statusCode: response.statusCode)
    }

    static func hasExpectedResponseShape(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["cainiao_waybillprint_clientupdate_getconfig_response"] as? [String: Any],
              let result = response["result"] as? [String: Any],
              result["data"] != nil else {
            return false
        }
        return true
    }
}

enum NativeHandshakeReason: String, Sendable {
    case startup
    case manualRestart = "manual-restart"
    case wake
}

enum NativeHandshakeState: Equatable, Sendable {
    case idle
    case running
    case ready(statusCode: Int)
    case failed(category: String)
    case credentialsMissing

    var displayText: String {
        switch self {
        case .idle: return "等待握手"
        case .running: return "正在登记本机组件"
        case .ready: return "远端握手正常"
        case .failed: return "远端握手失败"
        case .credentialsMissing: return "远端握手凭据缺失"
        }
    }
}

struct NativeHandshakeEvent: Equatable, Sendable {
    let reason: NativeHandshakeReason
    let state: NativeHandshakeState
    let attempt: Int
}

actor NativeHandshakeCoordinator {
    typealias Operation = @Sendable () async throws -> CainiaoHandshakeSuccess
    typealias Sleep = @Sendable (UInt64) async throws -> Void

    private let operation: Operation?
    private let sleep: Sleep
    private let eventSink: @Sendable (NativeHandshakeEvent) -> Void
    private var runningTask: Task<NativeHandshakeState, Never>?

    init(
        operation: Operation?,
        sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: $0) },
        eventSink: @escaping @Sendable (NativeHandshakeEvent) -> Void = { _ in }
    ) {
        self.operation = operation
        self.sleep = sleep
        self.eventSink = eventSink
    }

    func trigger(reason: NativeHandshakeReason) async -> NativeHandshakeState {
        if let runningTask {
            return await runningTask.value
        }
        guard let operation else {
            let state = NativeHandshakeState.credentialsMissing
            eventSink(NativeHandshakeEvent(reason: reason, state: state, attempt: 0))
            return state
        }

        let sleep = self.sleep
        let eventSink = self.eventSink
        let task = Task<NativeHandshakeState, Never> {
            let delays: [UInt64] = [0, 500_000_000, 1_500_000_000]
            for (index, delay) in delays.enumerated() {
                let attempt = index + 1
                if delay > 0 { try? await sleep(delay) }
                eventSink(NativeHandshakeEvent(reason: reason, state: .running, attempt: attempt))
                do {
                    let success = try await operation()
                    let state = NativeHandshakeState.ready(statusCode: success.statusCode)
                    eventSink(NativeHandshakeEvent(reason: reason, state: state, attempt: attempt))
                    return state
                } catch let error as CainiaoHandshakeError {
                    if attempt == delays.count {
                        let state = NativeHandshakeState.failed(category: error.category)
                        eventSink(NativeHandshakeEvent(reason: reason, state: state, attempt: attempt))
                        return state
                    }
                } catch {
                    if attempt == delays.count {
                        let state = NativeHandshakeState.failed(category: "transport")
                        eventSink(NativeHandshakeEvent(reason: reason, state: state, attempt: attempt))
                        return state
                    }
                }
            }
            return .failed(category: "unknown")
        }
        runningTask = task
        let state = await task.value
        runningTask = nil
        return state
    }
}

private func currentArchitecture() -> String {
    var info = utsname()
    uname(&info)
    let machine = withUnsafePointer(to: &info.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }
    return machine == "arm64" ? "aarch64" : machine
}

private func discoverPrimaryMACAddress() -> String? {
    interfaceValues(family: AF_LINK) { address in
        let link = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_dl.self)
        let length = Int(link.pointee.sdl_alen)
        guard length == 6 else { return nil }
        let bytes = withUnsafePointer(to: link.pointee.sdl_data) { pointer -> [UInt8] in
            let raw = UnsafeRawPointer(pointer).advanced(by: Int(link.pointee.sdl_nlen))
            return Array(UnsafeBufferPointer(start: raw.assumingMemoryBound(to: UInt8.self), count: length))
        }
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }.first?.value
}

private func discoverPrimaryIPv4Address() -> String? {
    interfaceValues(family: AF_INET) { address in
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            address,
            socklen_t(address.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0 else { return nil }
        let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }.first?.value
}

private struct InterfaceValue {
    let name: String
    let value: String
}

private func interfaceValues(
    family: Int32,
    extract: (UnsafePointer<sockaddr>) -> String?
) -> [InterfaceValue] {
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
    defer { freeifaddrs(pointer) }

    var candidates: [InterfaceValue] = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let current = cursor {
        let item = current.pointee
        defer { cursor = item.ifa_next }
        guard let address = item.ifa_addr,
              Int32(address.pointee.sa_family) == family,
              (item.ifa_flags & UInt32(IFF_UP)) != 0,
              (item.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else {
            continue
        }
        let name = String(cString: item.ifa_name)
        guard !name.hasPrefix("awdl"),
              !name.hasPrefix("llw"),
              !name.hasPrefix("utun"),
              let value = extract(UnsafePointer(address)) else { continue }
        candidates.append(InterfaceValue(name: name, value: value))
    }
    return candidates.sorted { lhs, rhs in
        if lhs.name == "en0" { return true }
        if rhs.name == "en0" { return false }
        return lhs.name < rhs.name
    }
}
