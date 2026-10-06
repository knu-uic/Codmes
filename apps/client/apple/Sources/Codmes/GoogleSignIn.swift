import AuthenticationServices
import CryptoKit
import Foundation
import Security
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum GoogleSignInError: Error, LocalizedError {
    case unavailable
    case invalidCallback
    case stateMismatch
    case missingCode
    case missingIDToken
    case nonceMismatch
    case tokenExchangeFailed(String)
    case unconfiguredURLScheme(String)
    case publisherMismatch

    var errorDescription: String? {
        switch self {
        case .unavailable: "Google 로그인을 시작할 수 없습니다. 앱 창을 다시 열어 주세요."
        case .invalidCallback: "Google 로그인 응답의 주소가 올바르지 않습니다."
        case .stateMismatch: "Google 로그인 상태를 확인할 수 없습니다. 다시 시도해 주세요."
        case .missingCode: "Google에서 인증 코드를 받지 못했습니다."
        case .missingIDToken: "Google에서 계정 확인 토큰을 받지 못했습니다."
        case .nonceMismatch: "Google 로그인 응답을 확인할 수 없습니다. 다시 시도해 주세요."
        case let .tokenExchangeFailed(message): "Google 로그인에 실패했습니다. \(message)"
        case let .unconfiguredURLScheme(scheme): "이 앱에 Google 로그인 URL 스킴(\(scheme))이 등록되지 않았습니다. OAuth 클라이언트 ID에 맞춰 앱을 다시 빌드하세요."
        case .publisherMismatch: "앱과 서버의 Codmes 배포자 로그인 설정이 다릅니다. 같은 배포자의 최신 앱과 Server Manager를 사용해 주세요. 서버 운영자가 Google 프로젝트를 만들 필요는 없습니다."
        }
    }
}

struct GoogleOAuthAttempt {
    let clientID: String
    let redirectURI: String
    let codeVerifier: String
    let state: String
    let nonce: String

    init(clientID: String, redirectURI: String) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        codeVerifier = Self.randomBase64URL()
        state = Self.randomBase64URL()
        nonce = Self.randomBase64URL()
    }

    static func expectedRedirectURI(for clientID: String) -> String? {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix) else { return nil }
        let identifier = String(clientID.dropLast(suffix.count))
        guard !identifier.isEmpty else { return nil }
        return "com.googleusercontent.apps.\(identifier):/oauth2redirect"
    }

    static func publisherClientID(bundle: Bundle = .main) -> String? {
        let value = (bundle.object(forInfoDictionaryKey: "CodmesGoogleClientID") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return expectedRedirectURI(for: value) == nil ? nil : value
    }

    static func validatePublisher(clientID: String, serverClientID: String?) throws {
        guard expectedRedirectURI(for: clientID) != nil, clientID == serverClientID else {
            throw GoogleSignInError.publisherMismatch
        }
    }

    static func registeredRedirectURI(for clientID: String, bundle: Bundle = .main) throws -> String {
        guard let redirectURI = expectedRedirectURI(for: clientID),
              let scheme = URL(string: redirectURI)?.scheme else {
            throw GoogleSignInError.invalidCallback
        }
        let urlTypes = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let registered = urlTypes
            .compactMap { $0["CFBundleURLSchemes"] as? [String] }
            .flatMap { $0 }
            .contains { $0.caseInsensitiveCompare(scheme) == .orderedSame }
        guard registered else { throw GoogleSignInError.unconfiguredURLScheme(scheme) }
        return redirectURI
    }

    var authorizationURL: URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(codeVerifier.utf8))))
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "prompt", value: "select_account")
        ]
        return components.url!
    }

    func authorizationCode(from callbackURL: URL) throws -> String {
        guard let expected = URLComponents(string: redirectURI),
              callbackURL.scheme?.lowercased() == expected.scheme?.lowercased(),
              callbackURL.path == expected.path,
              let received = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw GoogleSignInError.invalidCallback
        }
        let responseItems = received.queryItems
            ?? received.fragment.flatMap { URLComponents(string: "?" + $0)?.queryItems }
            ?? []
        let values = Dictionary(responseItems.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        guard values["state"] == state else { throw GoogleSignInError.stateMismatch }
        if let error = values["error"] { throw GoogleSignInError.tokenExchangeFailed(error) }
        guard let code = values["code"], !code.isEmpty else { throw GoogleSignInError.missingCode }
        return code
    }

    func verifyNonce(in idToken: String) throws {
        let pieces = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              let payload = Self.decodeBase64URL(String(pieces[1])),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              claims["aud"] as? String == clientID,
              claims["nonce"] as? String == nonce else {
            throw GoogleSignInError.nonceMismatch
        }
    }

    private static func randomBase64URL() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Secure random source unavailable")
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ text: String) -> Data? {
        let base64 = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4))
    }
}

@MainActor
final class GoogleSignInController: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func signIn(clientID: String, redirectURI: String) async throws -> String {
        let attempt = GoogleOAuthAttempt(clientID: clientID, redirectURI: redirectURI)
        defer { session = nil }
        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let callback = GoogleAuthenticationCallback(continuation)
            let session = ASWebAuthenticationSession(
                url: attempt.authorizationURL,
                callbackURLScheme: URL(string: redirectURI)?.scheme,
                completionHandler: callback.completionHandler
            )
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                self.session = nil
                callback.complete(url: nil, error: GoogleSignInError.unavailable)
            }
        }
        let code = try attempt.authorizationCode(from: callbackURL)
        let idToken = try await exchangeCode(code, attempt: attempt)
        try attempt.verifyNonce(in: idToken)
        return idToken
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
        #else
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? UIWindow()
        #endif
    }

    private func exchangeCode(_ code: String, attempt: GoogleOAuthAttempt) async throws -> String {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client_id", value: attempt.clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: attempt.codeVerifier),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "redirect_uri", value: attempt.redirectURI)
        ]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let error = (try? JSONDecoder().decode(GoogleTokenError.self, from: data))?.errorDescription
                ?? "Google token endpoint returned an error."
            throw GoogleSignInError.tokenExchangeFailed(error)
        }
        guard let token = (try? JSONDecoder().decode(GoogleTokenResponse.self, from: data))?.idToken,
              !token.isEmpty else { throw GoogleSignInError.missingIDToken }
        return token
    }
}

// AuthenticationServices can invoke its completion on Safari's background XPC queue.
// Creating the handler outside the @MainActor controller avoids Swift 6's actor
// assertion. The continuation returns signIn to its main-actor context itself.
// A failed start and a late callback must not resume the continuation twice.
final class GoogleAuthenticationCallback: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, any Error>?

    init(_ continuation: CheckedContinuation<URL, any Error>) {
        self.continuation = continuation
    }

    var completionHandler: @Sendable (URL?, (any Error)?) -> Void {
        { [self] url, error in complete(url: url, error: error) }
    }

    func complete(url: URL?, error: (any Error)?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        if let error {
            pending.resume(throwing: error)
        } else if let url {
            pending.resume(returning: url)
        } else {
            pending.resume(throwing: GoogleSignInError.invalidCallback)
        }
    }
}

@MainActor
final class GoogleApprovalPolling {
    private var task: Task<Void, Never>?
    private var generation: UUID?
    private(set) var requestID: String?

    func start(requestID: String, interval: Duration = .seconds(5), check: @escaping @MainActor () async -> Bool) {
        if self.requestID == requestID, task != nil { return }
        cancel()
        let attempt = UUID()
        generation = attempt
        self.requestID = requestID
        task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, self.generation == attempt, !Task.isCancelled else { return }
                let shouldContinue = await check()
                if !shouldContinue || self.generation != attempt { return }
            }
        }
    }

    // Called from the polling task on approval. Do not cancel that same task:
    // it still needs to fetch profiles with URLSession after receiving approval.
    func finish() {
        generation = nil
        requestID = nil
        task = nil
    }

    func cancel() {
        task?.cancel()
        finish()
    }
}

private struct GoogleTokenResponse: Decodable {
    let idToken: String
    enum CodingKeys: String, CodingKey { case idToken = "id_token" }
}

private struct GoogleTokenError: Decodable {
    let errorDescription: String?
    enum CodingKeys: String, CodingKey { case errorDescription = "error_description" }
}
