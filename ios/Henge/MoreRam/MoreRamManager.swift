import CryptoKit
import Foundation
import Security
import StosSign_API
import StosSign_Auth
import StosSign_Common
import SwiftUI
import UIKit

enum MoreRamError: LocalizedError {
    case invalidServerURL
    case missingCredentials
    case missingProvisioningURLs
    case invalidServerResponse(String)
    case missingADIData
    case provisioningFailed(String)
    case notSignedIn
    case noTeamsFound
    case invalidSideStoreFile(String)
    case randomGenerationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "Anisette 伺服器網址無效。"
        case .missingCredentials:
            return "請輸入 Apple ID 與密碼。"
        case .missingProvisioningURLs:
            return "無法從 Apple 取得 Anisette 佈署網址，請稍後再試。"
        case .invalidServerResponse(let detail):
            return "伺服器回傳格式異常：\(detail)"
        case .missingADIData:
            return "Anisette headers 缺少必要欄位。"
        case .provisioningFailed(let reason):
            return "Anisette 裝置註冊失敗：\(reason)"
        case .notSignedIn:
            return "請先登入 Apple ID 並選擇開發者團隊。"
        case .noTeamsFound:
            return "此 Apple ID 名下找不到可用的開發者團隊。"
        case .invalidSideStoreFile(let detail):
            return "SideStore 帳號檔格式不符：\(detail)"
        case .randomGenerationFailed(let status):
            return "無法產生安全裝置識別碼（OSStatus \(status)）。"
        }
    }
}

final class MoreRamKeychain {
    static let shared = MoreRamKeychain()

    private let service = "com.henge.ipac.moreram"

    private init() {}

    var appleIDEmail: String? {
        get { string(for: "appleIDEmailAddress") }
        set { set(newValue, for: "appleIDEmailAddress") }
    }

    var appleIDPassword: String? {
        get { string(for: "appleIDPassword") }
        set { set(newValue, for: "appleIDPassword") }
    }

    var identifier: String? {
        get { string(for: "identifier") }
        set { set(newValue, for: "identifier") }
    }

    var adiPb: String? {
        get { string(for: "adiPb") }
        set { set(newValue, for: "adiPb") }
    }

    func clearCredentials() {
        appleIDEmail = nil
        appleIDPassword = nil
    }

    func clearAnisette() {
        identifier = nil
        adiPb = nil
    }

    private func data(for key: String) -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func string(for key: String) -> String? {
        guard let data = data(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func set(_ string: String?, for key: String) {
        set(string?.data(using: .utf8), for: key)
    }

    private func set(_ data: Data?, for key: String) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard let data else { return }
        var attrs = baseQuery(for: key)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}

final class MoreRamAnisette {
    static let defaultServerURL = "https://ani.sidestore.io"

    private static let clientInfo = "<iMac18,3> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
    private static let userAgent = "AuthKit/1 (Macintosh; OS X 27.0) (com.apple.akd/1.0)"

    private let baseURL: URL
    private let logHandler: (String) -> Void

    init(serverURL: URL, logHandler: @escaping (String) -> Void) {
        self.baseURL = Self.normalizeBaseURL(serverURL)
        self.logHandler = logHandler
    }

    static func normalizeBaseURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/v3") {
            path.removeLast(3)
            while path.hasSuffix("/") { path.removeLast() }
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }

    func getAnisetteData() async throws -> AnisetteData {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        let urlSession = URLSession(configuration: config)
        defer { urlSession.finishTasksAndInvalidate() }

        if let identifier = MoreRamKeychain.shared.identifier,
           let adiPb = MoreRamKeychain.shared.adiPb,
           let decoded = Data(base64Encoded: identifier),
           decoded.count == 16,
           !adiPb.isEmpty {
            return try await fetchV3Headers(
                identifier: identifier,
                adiPb: adiPb,
                allowReprovision: true,
                session: urlSession
            )
        }
        return try await provisionAndFetch(session: urlSession)
    }

    private func ensureClientIdentity() throws -> (identifier: String, mdLu: String, deviceId: String) {
        let identifier: String
        if let stored = MoreRamKeychain.shared.identifier,
           let decoded = Data(base64Encoded: stored),
           decoded.count == 16 {
            identifier = stored
        } else {
            var bytes = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard status == errSecSuccess else {
                throw MoreRamError.randomGenerationFailed(status)
            }
            identifier = Data(bytes).base64EncodedString()
            MoreRamKeychain.shared.identifier = identifier
        }

        guard let decoded = Data(base64Encoded: identifier), decoded.count == 16 else {
            throw MoreRamError.missingADIData
        }
        let b = [UInt8](decoded)
        let uuid = UUID(uuid: (
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
            b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
        ))
        let mdLu = SHA256.hash(data: decoded).map { String(format: "%02hhX", $0) }.joined()
        return (identifier, mdLu, uuid.uuidString.uppercased())
    }

    private func provisionAndFetch(session: URLSession) async throws -> AnisetteData {
        let identity = try ensureClientIdentity()
        logHandler("正在向 Apple 查詢 Anisette 佈署網址…")

        var lookupRequest = buildAppleRequest(
            url: URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!,
            mdLu: identity.mdLu,
            deviceId: identity.deviceId
        )
        lookupRequest.httpMethod = "GET"

        let (lookupData, _) = try await session.data(for: lookupRequest)
        guard let plist = try? PropertyListSerialization.propertyList(from: lookupData, format: nil) as? [String: [String: Any]],
              let startStr = plist["urls"]?["midStartProvisioning"] as? String,
              let startURL = URL(string: startStr),
              let endStr = plist["urls"]?["midFinishProvisioning"] as? String,
              let endURL = URL(string: endStr) else {
            throw MoreRamError.missingProvisioningURLs
        }

        logHandler("正在透過 Anisette v3 WebSocket 註冊裝置…")
        let endpoint = webSocketURL(from: baseURL.appendingPathComponent("v3").appendingPathComponent("provisioning_session"))
        var wsRequest = URLRequest(url: endpoint)
        wsRequest.timeoutInterval = 12
        let socket = session.webSocketTask(with: wsRequest)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        for _ in 0..<20 {
            let message = try await socket.receive()
            guard case .string(let text) = message else {
                throw MoreRamError.provisioningFailed("伺服器回傳了非文字 WebSocket 訊框。")
            }
            guard let raw = text.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let result = json["result"] as? String else {
                throw MoreRamError.provisioningFailed("無法解析伺服器 JSON。")
            }

            switch result {
            case "GiveIdentifier":
                try await sendJSON(["identifier": identity.identifier], on: socket)
            case "GiveStartProvisioningData":
                let spim = try await fetchStartProvisioning(url: startURL, identity: identity, session: session)
                try await sendJSON(["spim": spim], on: socket)
            case "GiveEndProvisioningData":
                guard let cpim = json["cpim"] as? String else {
                    throw MoreRamError.provisioningFailed("伺服器未提供 cpim 參數。")
                }
                let endData = try await fetchEndProvisioning(url: endURL, cpim: cpim, identity: identity, session: session)
                try await sendJSON(endData, on: socket)
            case "ProvisioningSuccess":
                guard let adiPb = json["adi_pb"] as? String, !adiPb.isEmpty else {
                    throw MoreRamError.provisioningFailed("伺服器未回傳 adi_pb 資料。")
                }
                MoreRamKeychain.shared.adiPb = adiPb
                logHandler("Anisette 裝置註冊完成。")
                return try await fetchV3Headers(
                    identifier: identity.identifier,
                    adiPb: adiPb,
                    allowReprovision: false,
                    session: session
                )
            default:
                if result.contains("Error") || result.contains("Invalid") || result == "ClosingPerRequest" || result == "Timeout" || result == "TextOnly" {
                    let detail = Self.stringField("message", in: json).map { " (\($0))" } ?? ""
                    throw MoreRamError.provisioningFailed("\(result)\(detail)")
                }
            }
        }
        throw MoreRamError.provisioningFailed("Anisette 佈署程序逾時。")
    }

    private func fetchStartProvisioning(url: URL, identity: (identifier: String, mdLu: String, deviceId: String), session: URLSession) async throws -> String {
        let body: [String: Any] = ["Header": [String: Any](), "Request": [String: Any]()]
        var request = buildAppleRequest(url: url, mdLu: identity.mdLu, deviceId: identity.deviceId)
        request.httpMethod = "POST"
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        let (data, _) = try await session.data(for: request)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]],
              let spim = plist["Response"]?["spim"] as? String else {
            throw MoreRamError.invalidServerResponse("Apple 未回傳有效的 start provisioning 資料。")
        }
        return spim
    }

    private func fetchEndProvisioning(url: URL, cpim: String, identity: (identifier: String, mdLu: String, deviceId: String), session: URLSession) async throws -> [String: String] {
        let body: [String: Any] = ["Header": [String: Any](), "Request": ["cpim": cpim]]
        var request = buildAppleRequest(url: url, mdLu: identity.mdLu, deviceId: identity.deviceId)
        request.httpMethod = "POST"
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        let (data, _) = try await session.data(for: request)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]],
              let ptm = plist["Response"]?["ptm"] as? String,
              let tk = plist["Response"]?["tk"] as? String else {
            throw MoreRamError.invalidServerResponse("Apple 未回傳有效的 end provisioning 資料。")
        }
        return ["ptm": ptm, "tk": tk]
    }

    private func fetchV3Headers(identifier: String, adiPb: String, allowReprovision: Bool, session: URLSession) async throws -> AnisetteData {
        let identity = try ensureClientIdentity()
        logHandler("正在向 \(baseURL.host ?? baseURL.absoluteString) 取得 Anisette v3 Headers…")

        var request = URLRequest(url: baseURL.appendingPathComponent("v3").appendingPathComponent("get_headers"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "identifier": identifier,
            "adi_pb": adiPb
        ])

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MoreRamError.invalidServerResponse("Anisette 回傳非 JSON 格式（HTTP \(statusCode)）。")
        }

        if Self.stringField("result", in: json) == "GetHeadersError" {
            let message = Self.stringField("message", in: json) ?? "未知錯誤"
            if allowReprovision && message.contains("-45061") {
                logHandler("Anisette 憑證需重新佈署（-45061），自動重新註冊中…")
                MoreRamKeychain.shared.adiPb = nil
                return try await provisionAndFetch(session: session)
            }
            throw MoreRamError.invalidServerResponse(message)
        }

        guard let machineID = Self.stringField("X-Apple-I-MD-M", in: json),
              let oneTimePassword = Self.stringField("X-Apple-I-MD", in: json),
              let rinfoStr = Self.stringField("X-Apple-I-MD-RINFO", in: json),
              let routingInfo = UInt64(rinfoStr) else {
            throw MoreRamError.missingADIData
        }

        return AnisetteData(
            machineID: machineID,
            oneTimePassword: oneTimePassword,
            localUserID: identity.mdLu,
            routingInfo: routingInfo,
            deviceUniqueIdentifier: identity.deviceId,
            deviceSerialNumber: "0",
            deviceDescription: Self.clientInfo,
            date: Date(),
            locale: Locale.current,
            timeZone: TimeZone.current
        )
    }

    private static func stringField(_ key: String, in dict: [String: Any]) -> String? {
        guard let value = dict[key] else { return nil }
        if let str = value as? String { return str }
        if let num = value as? NSNumber { return num.stringValue }
        return nil
    }

    private func sendJSON(_ dictionary: [String: String], on socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await socket.send(.string(text))
    }

    private func webSocketURL(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        if components.scheme == "https" {
            components.scheme = "wss"
        } else if components.scheme == "http" {
            components.scheme = "ws"
        }
        return components.url ?? url
    }

    private func buildAppleRequest(url: URL, mdLu: String, deviceId: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(Self.clientInfo, forHTTPHeaderField: "X-Mme-Client-Info")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(mdLu, forHTTPHeaderField: "X-Apple-I-MD-LU")
        request.setValue(deviceId, forHTTPHeaderField: "X-Mme-Device-Id")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        request.setValue(formatter.string(from: Date()), forHTTPHeaderField: "X-Apple-I-Client-Time")
        request.setValue(Locale.current.identifier, forHTTPHeaderField: "X-Apple-Locale")
        request.setValue(TimeZone.current.abbreviation() ?? "GMT", forHTTPHeaderField: "X-Apple-I-TimeZone")
        return request
    }
}

struct MoreRamSideStoreAccount: Decodable {
    let email: String
    let password: String
    let adiPB: String
    let localUser: String

    enum CodingKeys: String, CodingKey {
        case email
        case password
        case adiPB
        case adiPb
        case adipb
        case adiSnake = "adi_pb"
        case localUser = "local_user"
        case localuser
        case localUserCamel = "localUser"
        case identifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        adiPB = try container.decodeIfPresent(String.self, forKey: .adiPB)
            ?? container.decodeIfPresent(String.self, forKey: .adiPb)
            ?? container.decodeIfPresent(String.self, forKey: .adipb)
            ?? container.decodeIfPresent(String.self, forKey: .adiSnake)
            ?? ""
        localUser = try container.decodeIfPresent(String.self, forKey: .localUser)
            ?? container.decodeIfPresent(String.self, forKey: .localuser)
            ?? container.decodeIfPresent(String.self, forKey: .localUserCamel)
            ?? container.decodeIfPresent(String.self, forKey: .identifier)
            ?? ""
    }

    static func importAndStore(from data: Data) throws -> MoreRamSideStoreAccount {
        let parsed = try JSONDecoder().decode(MoreRamSideStoreAccount.self, from: data)
        let email = parsed.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = parsed.password.trimmingCharacters(in: .whitespacesAndNewlines)
        let adiPB = parsed.adiPB.trimmingCharacters(in: .whitespacesAndNewlines)
        let localUser = parsed.localUser.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !email.isEmpty else { throw MoreRamError.invalidSideStoreFile("缺少 email 欄位。") }
        guard !password.isEmpty else { throw MoreRamError.invalidSideStoreFile("缺少 password 欄位。") }
        guard !adiPB.isEmpty else { throw MoreRamError.invalidSideStoreFile("缺少 adiPB 欄位。") }
        guard let decoded = Data(base64Encoded: localUser), decoded.count == 16 else {
            throw MoreRamError.invalidSideStoreFile("local_user 必須為 16 bytes Base64 字串。")
        }

        MoreRamKeychain.shared.appleIDEmail = email
        MoreRamKeychain.shared.appleIDPassword = password
        MoreRamKeychain.shared.adiPb = adiPB
        MoreRamKeychain.shared.identifier = localUser
        return parsed
    }
}

struct MoreRamAppIDItem: Identifiable {
    var appID: AppID
    var didJustUnlock = false

    var id: String { appID.identifier }
    var name: String { appID.name }
    var bundleIdentifier: String { appID.bundleIdentifier }
    var expirationDate: Date? { appID.expirationDate }

    var isCurrentApp: Bool {
        if let current = Bundle.main.bundleIdentifier, !current.isEmpty {
            return bundleIdentifier.caseInsensitiveCompare(current) == .orderedSame
        }
        return false
    }

    var isLikelyHengeOrIPac: Bool {
        let lower = bundleIdentifier.lowercased()
        return isCurrentApp || lower.contains("henge") || lower.contains("ipac")
    }

    var hasIncreasedMemoryLimit: Bool {
        didJustUnlock
            || (isCurrentApp && Entitlements.increasedMemory)
            || Self.featureEnabled("INCREASED_MEMORY_LIMIT", in: appID.features)
    }

    func isEffectivelyEnabled(unlockedBundleIDs: Set<String>) -> Bool {
        hasIncreasedMemoryLimit || unlockedBundleIDs.contains(bundleIdentifier.lowercased())
    }

    private static func featureEnabled(_ key: String, in features: [String: Any]) -> Bool {
        guard let value = features[key] else { return false }
        if let boolVal = value as? Bool { return boolVal }
        if let numVal = value as? NSNumber { return numVal.boolValue }
        if let strVal = value as? String { return strVal.lowercased() == "true" || strVal == "1" }
        return true
    }
}

@MainActor
final class MoreRamCoordinator: ObservableObject {
    enum AutoUnlockState: Equatable {
        case idle
        case alreadyActive
        case checking
        case unlockedPendingRefresh(String)
        case needsSetup
        case needsTwoFactor
        case failed(String)
    }

    static let shared = MoreRamCoordinator()

    private static let unlockedBundleIDsKey = "ipac.moreram.unlockedBundleIDs"

    @AppStorage("ipac.anisetteURL") var anisetteServerURL = MoreRamAnisette.defaultServerURL
    @AppStorage("ipac.moreram.autoOnLaunch") var autoEnableOnLaunch = true
    @AppStorage("ipac.moreram.dismissedHomePromptBuild") var dismissedHomePromptBuild = ""

    @Published var showSheet = false
    @Published var autoState: AutoUnlockState = Entitlements.increasedMemory ? .alreadyActive : .idle

    @Published var appleID = MoreRamKeychain.shared.appleIDEmail ?? ""
    @Published var password = MoreRamKeychain.shared.appleIDPassword ?? ""
    @Published var rememberCredentials = true
    @Published var includeExtendedVirtualAddressing = false

    @Published var isAuthenticating = false
    @Published var isLoadingAppIDs = false
    @Published var updatingAppID: String?
    @Published var needsTwoFactor = false
    @Published var twoFactorCode = ""
    @Published var isSubmittingTwoFactor = false

    @Published var teams: [Team] = []
    @Published var selectedTeamID: String = ""
    @Published var appIDs: [MoreRamAppIDItem] = []

    @Published var statusLogs: [String] = []
    @Published var errorMessage: String?
    @Published var successBanner: String?

    @Published private(set) var unlockedBundleIDs: Set<String>

    private var account: Account?
    private var session: AppleAPISession?
    private var verificationHandler: ((String?) -> Void)?
    private var cancellationRequested = false
    private var hitNonInteractiveTwoFactor = false
    private var didRunLaunchAutoCheck = false

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.unlockedBundleIDsKey) ?? []
        self.unlockedBundleIDs = Set(saved.map { $0.lowercased() })
    }

    var isSignedIn: Bool { account != nil && session != nil && !teams.isEmpty }
    var currentBundleID: String { Bundle.main.bundleIdentifier ?? "com.henge.app" }

    var currentBuildTag: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0.4.1"
        let build = info["CFBundleVersion"] as? String ?? "108"
        return "\(version)-\(build)"
    }

    var shouldShowHomeNotice: Bool {
        guard !Entitlements.increasedMemory else { return false }
        switch autoState {
        case .checking, .unlockedPendingRefresh, .needsTwoFactor:
            return true
        case .needsSetup, .failed:
            return dismissedHomePromptBuild != currentBuildTag
        case .idle, .alreadyActive:
            return false
        }
    }

    var hasStoredCredentials: Bool {
        !(MoreRamKeychain.shared.appleIDEmail ?? "").isEmpty &&
        !(MoreRamKeychain.shared.appleIDPassword ?? "").isEmpty
    }

    var hasStoredAnisette: Bool {
        !(MoreRamKeychain.shared.identifier ?? "").isEmpty &&
        !(MoreRamKeychain.shared.adiPb ?? "").isEmpty
    }

    var selectedTeam: Team? {
        teams.first(where: { $0.identifier == selectedTeamID }) ?? teams.first
    }

    var installedSignerApp: (name: String, url: URL)? {
        let candidates = [("SideStore", "sidestore://"), ("AltStore", "altstore://")]
        for (name, scheme) in candidates {
            if let url = URL(string: scheme), UIApplication.shared.canOpenURL(url) {
                return (name, url)
            }
        }
        return nil
    }

    func appendLog(_ message: String) {
        statusLogs.append(message)
        if statusLogs.count > 40 {
            statusLogs.removeFirst(statusLogs.count - 40)
        }
    }

    func dismissHomePromptForThisBuild() {
        dismissedHomePromptBuild = currentBuildTag
    }

    /// Runs automatically once per launch when iPac becomes active.
    func autoUnlockOnLaunchIfNeeded() async {
        if Entitlements.increasedMemory {
            autoState = .alreadyActive
            recordUnlocked(bundleIdentifier: currentBundleID)
            HengeLog.log("moreram", "increased-memory-limit is active at launch")
            return
        }

        if unlockedBundleIDs.contains(currentBundleID.lowercased()) {
            autoState = .unlockedPendingRefresh(currentBundleID)
            HengeLog.log("moreram", "bundle \(currentBundleID) already unlocked on Apple server; waiting for signer Refresh")
            return
        }

        guard !didRunLaunchAutoCheck else { return }
        didRunLaunchAutoCheck = true

        guard autoEnableOnLaunch else {
            autoState = .needsSetup
            return
        }

        guard hasStoredCredentials else {
            autoState = .needsSetup
            return
        }

        appleID = MoreRamKeychain.shared.appleIDEmail ?? appleID
        password = MoreRamKeychain.shared.appleIDPassword ?? password
        HengeLog.log("moreram", "starting silent automatic INCREASED_MEMORY_LIMIT check")
        await performSignInAndAutoUnlock(interactive: false)
    }

    func importSideStoreJSON(url: URL) {
        errorMessage = nil
        successBanner = nil
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let imported = try MoreRamSideStoreAccount.importAndStore(from: data)
            appleID = imported.email
            password = imported.password
            appendLog("已匯入 SideStore 帳號資料（\(imported.email)）。")
            Task { await signIn() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signIn() async {
        await performSignInAndAutoUnlock(interactive: true)
    }

    private func performSignInAndAutoUnlock(interactive: Bool) async {
        guard !isAuthenticating else { return }
        let trimmedID = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, !password.isEmpty else {
            if interactive {
                errorMessage = MoreRamError.missingCredentials.localizedDescription
            } else {
                autoState = .needsSetup
            }
            return
        }
        guard let serverURL = URL(string: anisetteServerURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              serverURL.scheme == "https" || serverURL.scheme == "http" else {
            if interactive {
                errorMessage = MoreRamError.invalidServerURL.localizedDescription
            } else {
                autoState = .failed(MoreRamError.invalidServerURL.localizedDescription)
            }
            return
        }

        errorMessage = nil
        successBanner = nil
        if interactive {
            statusLogs.removeAll()
        }
        isAuthenticating = true
        cancellationRequested = false
        hitNonInteractiveTwoFactor = false
        if !Entitlements.increasedMemory {
            autoState = .checking
        }

        defer {
            isAuthenticating = false
            verificationHandler = nil
            needsTwoFactor = false
            twoFactorCode = ""
            isSubmittingTwoFactor = false
        }

        do {
            let anisette = MoreRamAnisette(serverURL: serverURL) { [weak self] line in
                Task { @MainActor in
                    self?.appendLog(line)
                }
            }
            let anisetteData = try await anisette.getAnisetteData()

            appendLog("正在向 Apple Developer Services 驗證身分…")
            let (authedAccount, authedSession) = try await AppleAPI.shared.authenticate(
                appleID: trimmedID,
                password: password,
                anisetteData: anisetteData
            ) { [weak self] completionHandler in
                await self?.handleVerification(interactive: interactive, handler: completionHandler)
            }

            guard !cancellationRequested else { throw CancellationError() }

            account = authedAccount
            session = authedSession
            if rememberCredentials {
                MoreRamKeychain.shared.appleIDEmail = trimmedID
                MoreRamKeychain.shared.appleIDPassword = password
            } else {
                MoreRamKeychain.shared.clearCredentials()
            }

            appendLog("登入成功，正在讀取開發者團隊…")
            let fetchedTeams = try await AppleAPI.shared.fetchTeamsForAccount(
                account: authedAccount,
                session: authedSession
            )
            guard !fetchedTeams.isEmpty else {
                throw MoreRamError.noTeamsFound
            }

            teams = fetchedTeams
            selectedTeamID = fetchedTeams.first?.identifier ?? ""
            await autoMatchAndUnlockAppIDs(teams: fetchedTeams, session: authedSession)
        } catch is CancellationError {
            appendLog("已取消登入驗證。")
            if !Entitlements.increasedMemory {
                autoState = hasStoredCredentials ? .failed("已取消驗證。") : .needsSetup
            }
        } catch {
            if hitNonInteractiveTwoFactor && !interactive {
                appendLog("背景自動啟用需要雙重認證，請點選輸入驗證碼。")
                autoState = .needsTwoFactor
                return
            }
            if !cancellationRequested {
                let message = error.localizedDescription
                errorMessage = message
                appendLog("失敗：\(message)")
                if !Entitlements.increasedMemory {
                    autoState = .failed(message)
                }
            }
        }
    }

    private func autoMatchAndUnlockAppIDs(teams: [Team], session: AppleAPISession) async {
        var firstTeamItems: [MoreRamAppIDItem] = []
        var matchedTeam: Team?
        var matchedItems: [MoreRamAppIDItem] = []
        var matchedCandidate: MoreRamAppIDItem?

        for (index, team) in teams.enumerated() {
            do {
                let ids = try await AppleAPI.shared.fetchAppIDsForTeam(team: team, session: session)
                let sorted = Self.sortItems(ids.map { MoreRamAppIDItem(appID: $0) })
                if index == 0 {
                    firstTeamItems = sorted
                }
                if let exact = sorted.first(where: \.isCurrentApp) {
                    matchedTeam = team
                    matchedItems = sorted
                    matchedCandidate = exact
                    break
                }
                if matchedCandidate == nil, let likely = sorted.first(where: \.isLikelyHengeOrIPac) {
                    matchedTeam = team
                    matchedItems = sorted
                    matchedCandidate = likely
                }
            } catch {
                appendLog("讀取團隊 \(team.name) App ID 時略過：\(error.localizedDescription)")
            }
        }

        if let matchedTeam {
            selectedTeamID = matchedTeam.identifier
            appIDs = matchedItems
        } else {
            appIDs = firstTeamItems
        }

        guard let target = matchedCandidate else {
            let notice = "找不到對應目前 iPac（\(currentBundleID)）的 App ID，請展開下方進階清單手動選取。"
            errorMessage = notice
            appendLog(notice)
            if !Entitlements.increasedMemory {
                autoState = .failed(notice)
            }
            return
        }

        appendLog("已自動鎖定目標 App ID：\(target.bundleIdentifier)，正在向 Apple 開通大記憶體…")
        await enableIncreasedMemory(for: target)
    }

    func submitTwoFactorCode() {
        guard !isSubmittingTwoFactor, let handler = verificationHandler else { return }
        let code = twoFactorCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            cancelTwoFactor()
            return
        }
        verificationHandler = nil
        isSubmittingTwoFactor = true
        needsTwoFactor = false
        handler(code)
    }

    func handleTwoFactorDismissedIfNeeded() {
        guard !needsTwoFactor, verificationHandler != nil, !isSubmittingTwoFactor else { return }
        cancelTwoFactor()
    }

    func cancelTwoFactor() {
        cancellationRequested = true
        let handler = verificationHandler
        verificationHandler = nil
        needsTwoFactor = false
        twoFactorCode = ""
        isSubmittingTwoFactor = false
        handler?(nil)
    }

    func loadAppIDs() async {
        guard let team = selectedTeam, let session else {
            errorMessage = MoreRamError.notSignedIn.localizedDescription
            return
        }
        isLoadingAppIDs = true
        errorMessage = nil
        defer { isLoadingAppIDs = false }

        do {
            let ids = try await AppleAPI.shared.fetchAppIDsForTeam(team: team, session: session)
            appIDs = Self.sortItems(ids.map { MoreRamAppIDItem(appID: $0) })
            appendLog("已載入 \(appIDs.count) 個 App ID。")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func enableIncreasedMemory(for item: MoreRamAppIDItem) async {
        guard let team = selectedTeam, let session else {
            errorMessage = MoreRamError.notSignedIn.localizedDescription
            return
        }
        updatingAppID = item.id
        errorMessage = nil
        successBanner = nil
        defer { updatingAppID = nil }

        var capabilities = ["INCREASED_MEMORY_LIMIT"]
        let tryExtended = includeExtendedVirtualAddressing || team.type != .free
        if tryExtended {
            capabilities.append("EXTENDED_VIRTUAL_ADDRESSING")
        }

        do {
            let updated: AppID
            var appliedCapabilities = capabilities
            do {
                updated = try await AppleAPI.shared.updateAppID(
                    item.appID,
                    capabilities: capabilities,
                    team: team,
                    session: session
                )
            } catch where tryExtended && !includeExtendedVirtualAddressing {
                appliedCapabilities = ["INCREASED_MEMORY_LIMIT"]
                appendLog("此團隊不支援 Extended Virtual Addressing，自動改以 INCREASED_MEMORY_LIMIT 套用…")
                updated = try await AppleAPI.shared.updateAppID(
                    item.appID,
                    capabilities: appliedCapabilities,
                    team: team,
                    session: session
                )
            }
            if let idx = appIDs.firstIndex(where: { $0.id == item.id }) {
                appIDs[idx] = MoreRamAppIDItem(appID: updated, didJustUnlock: true)
            }
            recordUnlocked(bundleIdentifier: item.bundleIdentifier)
            let extras = appliedCapabilities.contains("EXTENDED_VIRTUAL_ADDRESSING") ? "（含 Extended Virtual Addressing）" : ""
            successBanner = "已自動為 \(item.bundleIdentifier) 向 Apple 開通大記憶體權限\(extras)！只要在簽名工具點一次 Refresh 即可永久生效。"
            if !Entitlements.increasedMemory {
                autoState = .unlockedPendingRefresh(item.bundleIdentifier)
            } else {
                autoState = .alreadyActive
            }
            appendLog("已自動開通：\(item.bundleIdentifier) -> \(appliedCapabilities.joined(separator: ", "))")
        } catch {
            let message = error.localizedDescription
            errorMessage = message
            appendLog("更新 \(item.bundleIdentifier) 失敗：\(message)")
            if !Entitlements.increasedMemory {
                autoState = .failed(message)
            }
        }
    }

    func signOut(clearSavedCredentials: Bool) {
        account = nil
        session = nil
        teams = []
        selectedTeamID = ""
        appIDs = []
        successBanner = nil
        errorMessage = nil
        if clearSavedCredentials {
            appleID = ""
            password = ""
            MoreRamKeychain.shared.clearCredentials()
            unlockedBundleIDs.removeAll()
            UserDefaults.standard.removeObject(forKey: Self.unlockedBundleIDsKey)
            didRunLaunchAutoCheck = false
            autoState = Entitlements.increasedMemory ? .alreadyActive : .needsSetup
        }
    }

    func resetAnisetteCache() {
        MoreRamKeychain.shared.clearAnisette()
        appendLog("已清除本地 Anisette 裝置快取，下次登入將重新註冊。")
    }

    private func recordUnlocked(bundleIdentifier: String) {
        let lower = bundleIdentifier.lowercased()
        if unlockedBundleIDs.insert(lower).inserted {
            UserDefaults.standard.set(Array(unlockedBundleIDs).sorted(), forKey: Self.unlockedBundleIDsKey)
        }
    }

    private static func sortItems(_ items: [MoreRamAppIDItem]) -> [MoreRamAppIDItem] {
        items.sorted { lhs, rhs in
            if lhs.isCurrentApp != rhs.isCurrentApp { return lhs.isCurrentApp }
            if lhs.isLikelyHengeOrIPac != rhs.isLikelyHengeOrIPac { return lhs.isLikelyHengeOrIPac }
            return lhs.bundleIdentifier.localizedCaseInsensitiveCompare(rhs.bundleIdentifier) == .orderedAscending
        }
    }

    private func handleVerification(interactive: Bool, handler: @escaping (String?) -> Void) {
        guard interactive else {
            hitNonInteractiveTwoFactor = true
            handler(nil)
            return
        }
        guard !cancellationRequested else {
            handler(nil)
            return
        }
        verificationHandler = handler
        twoFactorCode = ""
        isSubmittingTwoFactor = false
        needsTwoFactor = true
    }
}
