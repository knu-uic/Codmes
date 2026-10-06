import Foundation
import Security
import CryptoKit
import CommonCrypto
import Combine

enum KeychainStore {
    private static let service = "Codmes"
    private static let serverAuthTokenAccount = "workspace.serverAuthToken"
    private static let serverAccountTokenAccount = "workspace.serverAccountToken"

    static func readAppLock() -> String? { read(account: "device.appLock") }
    static func writeAppLock(_ value: String) -> Bool { write(value, account: "device.appLock") }
    static func deleteAppLock() -> Bool { delete(account: "device.appLock") }

    static func deviceID(for serverURL: URL) -> String? {
        let account = scopedAccount("workspace.googleDeviceID", serverURL: serverURL)
        if let saved = read(account: account), !saved.isEmpty { return saved }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let value = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return write(value, account: account) ? value : nil
    }

    static func readGooglePendingRequest(for serverURL: URL) -> GooglePendingRequest? {
        guard let json = read(account: scopedAccount("workspace.googlePendingRequest", serverURL: serverURL)),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GooglePendingRequest.self, from: data)
    }

    @discardableResult
    static func writeGooglePendingRequest(_ request: GooglePendingRequest, for serverURL: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(request),
              let json = String(data: data, encoding: .utf8) else { return false }
        return write(json, account: scopedAccount("workspace.googlePendingRequest", serverURL: serverURL))
    }

    @discardableResult
    static func deleteGooglePendingRequest(for serverURL: URL) -> Bool {
        delete(account: scopedAccount("workspace.googlePendingRequest", serverURL: serverURL))
    }

    private static func scopedAccount(_ prefix: String, serverURL: URL) -> String {
        let digest = SHA256.hash(data: Data(serverURL.absoluteString.utf8))
        let suffix = digest.map { String(format: "%02x", $0) }.joined()
        return "\(prefix).\(suffix)"
    }

    static func readServerAccountToken() -> String? {
        read(account: serverAccountTokenAccount)
    }

    @discardableResult
    static func writeServerAccountToken(_ token: String) -> Bool {
        write(token, account: serverAccountTokenAccount)
    }

    @discardableResult
    static func deleteServerAccountToken() -> Bool {
        delete(account: serverAccountTokenAccount)
    }

    static func readServerAuthToken() -> String? {
        read(account: serverAuthTokenAccount)
    }

    @discardableResult
    static func writeServerAuthToken(_ token: String) -> Bool {
        let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            return delete(account: serverAuthTokenAccount)
        }
        return write(cleaned, account: serverAuthTokenAccount)
    }

    @discardableResult
    static func deleteServerAuthToken() -> Bool {
        delete(account: serverAuthTokenAccount)
    }

    private static func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        var query = baseQuery(account: account)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return true
        }
        if status != errSecItemNotFound {
            return false
        }
        query[kSecValueData as String] = data
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func delete(account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

struct GooglePendingRequest: Codable {
    let requestId: String
    let requestToken: String
    var user: GoogleAccountIdentity? = nil
}

// This is a local UI lock, not a server credential or file-encryption key.
enum AppLockPIN {
    static func isValid(_ pin: String) -> Bool {
        pin.count == 4 && pin.utf8.allSatisfy { (48...57).contains($0) }
    }

    static func encode(_ pin: String) -> String? {
        guard isValid(pin) else { return nil }
        var salt = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess,
              let hash = derive(pin, salt: salt) else { return nil }
        return "pbkdf2-sha256$\(Data(salt).base64EncodedString())$\(Data(hash).base64EncodedString())"
    }

    static func verify(_ pin: String, encoded: String) -> Bool {
        guard isValid(pin) else { return false }
        let parts = encoded.split(separator: "$", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "pbkdf2-sha256",
              let salt = Data(base64Encoded: String(parts[1])), salt.count == 16,
              let expected = Data(base64Encoded: String(parts[2])), expected.count == 32,
              let actual = derive(pin, salt: Array(salt)) else { return false }
        return zip(actual, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func derive(_ pin: String, salt: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: 32)
        let result = pin.withCString { password in
            salt.withUnsafeBufferPointer { saltBuffer in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, pin.utf8.count,
                    saltBuffer.baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    100_000, &output, output.count)
            }
        }
        return result == kCCSuccess ? output : nil
    }
}

@MainActor
final class AppLockStore: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var isLocked: Bool
    @Published var message = ""
    private var failedAttempts = 0
    private var blockedUntil = Date.distantPast
    private let readPIN: () -> String?
    private let writePIN: (String) -> Bool
    private let deletePIN: () -> Bool
    private let rememberEnabled: (Bool) -> Void
    private let now: () -> Date

    convenience init() {
        self.init(read: KeychainStore.readAppLock, write: KeychainStore.writeAppLock,
            delete: KeychainStore.deleteAppLock,
            configured: UserDefaults.standard.bool(forKey: "device.appLock.enabled"),
            remember: { UserDefaults.standard.set($0, forKey: "device.appLock.enabled") })
    }

    init(read: @escaping () -> String?, write: @escaping (String) -> Bool,
         delete: @escaping () -> Bool, configured: Bool = false,
         remember: @escaping (Bool) -> Void = { _ in }, now: @escaping () -> Date = Date.init) {
        readPIN = read; writePIN = write; deletePIN = delete
        rememberEnabled = remember; self.now = now
        let hasLock = configured || read() != nil
        enabled = hasLock
        isLocked = hasLock
    }

    func lock() { if enabled { isLocked = true; message = "" } }

    func unlock(_ pin: String) -> Bool {
        guard authorize(pin) else { return false }
        isLocked = false
        return true
    }

    func setPIN(current: String, new: String, confirmation: String) -> Bool {
        guard !enabled || authorize(current) else { return false }
        guard AppLockPIN.isValid(new), new == confirmation else {
            message = "새 PIN은 숫자 4자리이며 확인 입력과 같아야 합니다."
            return false
        }
        guard let encoded = AppLockPIN.encode(new), writePIN(encoded) else {
            message = "앱 잠금을 보안 저장소에 저장하지 못했습니다."
            return false
        }
        rememberEnabled(true)
        enabled = true
        message = "이 기기의 앱 잠금 PIN을 설정했습니다."
        return true
    }

    func disable(current: String) -> Bool {
        guard enabled, authorize(current) else { return false }
        guard deletePIN() else { message = "앱 잠금을 해제하지 못했습니다."; return false }
        rememberEnabled(false)
        enabled = false
        isLocked = false
        message = "앱 잠금을 해제했습니다."
        return true
    }

    private func authorize(_ pin: String) -> Bool {
        guard now() >= blockedUntil else { message = "입력 횟수를 초과했습니다. 1분 후 다시 시도하세요."; return false }
        guard let encoded = readPIN(), AppLockPIN.verify(pin, encoded: encoded) else {
            failedAttempts += 1
            if failedAttempts >= 5 { blockedUntil = now().addingTimeInterval(60); failedAttempts = 0 }
            message = "PIN이 맞지 않습니다."
            return false
        }
        failedAttempts = 0
        message = ""
        return true
    }
}
