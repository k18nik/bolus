import Foundation
import Security
import LocalAuthentication
import Network
import Observation

/// Secrets live only in the Keychain (never in UserDefaults, SwiftData or backups).
enum KeychainStore {
    static let service = "app.bolus.diary.secrets"

    static func aiKeyAccount(_ provider: AIProvider) -> String { "ai-key-" + provider.rawValue }
    static let usdaAccount = "usda-api-key"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item.merge(update) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw BolusError.validation("Не удалось сохранить ключ в Keychain (код \(status)).") }
    }

    static func get(_ account: String) -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }

    static func has(_ account: String) -> Bool { get(account) != nil }
}

/// Optional app lock: Face ID / Touch ID with device passcode fallback.
@MainActor
@Observable
final class AppLockController {
    private(set) var isLocked = false
    var message: String?
    private var authenticating = false

    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "код-пароль"
        }
    }

    /// `deviceOwnerAuthentication` = biometrics with passcode fallback.
    static var isAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    func lock(if enabled: Bool) {
        if enabled { isLocked = true }
    }

    func disable() {
        isLocked = false
        message = nil
    }

    func unlock() async {
        guard isLocked, !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        let context = LAContext()
        context.localizedCancelTitle = "Отмена"
        do {
            if try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Откройте дневник Bolus") {
                isLocked = false
                message = nil
            }
        } catch {
            message = "Дневник заблокирован. Повторите попытку."
        }
    }

    /// Confirms the owner before turning the lock on.
    func confirmOwner() async -> Bool {
        let context = LAContext()
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Включить защиту дневника")) ?? false
    }
}

/// Connectivity hint for features that need external APIs (food catalogs, AI).
/// Core features never check it.
@MainActor
@Observable
final class NetworkMonitor {
    private(set) var isOnline = true
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "app.bolus.network-monitor"))
    }
}

/// URLSession transport for external APIs only: ephemeral, no cookies, no cache,
/// redirects refused (a saved key is never forwarded to another host).
enum HTTPClient {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }()

    static let transport: HTTPTransport = { spec in
        var request = URLRequest(url: spec.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: spec.timeout)
        request.httpMethod = spec.method
        request.httpShouldHandleCookies = false
        for (field, value) in spec.headers { request.setValue(value, forHTTPHeaderField: field) }
        request.httpBody = spec.body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return HTTPResponseData(status: http.statusCode, body: data)
    }
}
