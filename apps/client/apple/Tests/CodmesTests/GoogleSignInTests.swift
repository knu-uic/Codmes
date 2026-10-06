import Foundation
import XCTest
@testable import Codmes

final class GoogleSignInTests: XCTestCase {
    @MainActor
    func testApprovalCompletionDoesNotCancelFollowupProfileLoading() async {
        let polling = GoogleApprovalPolling()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            polling.start(requestID: "pending", interval: .milliseconds(1)) {
                polling.finish()
                XCTAssertFalse(Task.isCancelled, "approved task must still be able to fetch profiles")
                await Task.yield()
                XCTAssertFalse(Task.isCancelled)
                continuation.resume()
                return false
            }
        }
        XCTAssertNil(polling.requestID)
    }

    @MainActor
    func testReplacingApprovalRequestStopsOldPollingAndChecksNewRequest() async {
        let polling = GoogleApprovalPolling()
        polling.start(requestID: "old", interval: .seconds(60)) {
            XCTFail("obsolete request must not be checked")
            return false
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            polling.start(requestID: "new", interval: .milliseconds(1)) {
                XCTAssertEqual(polling.requestID, "new")
                polling.finish()
                continuation.resume()
                return false
            }
        }
        XCTAssertNil(polling.requestID)
    }

    @MainActor
    func testAuthenticationCallbackCanArriveOnBackgroundQueue() async throws {
        let expected = URL(string: "com.codmes.app:/oauth2redirect?code=test")!
        let received: URL = try await withCheckedThrowingContinuation { continuation in
            let callback = GoogleAuthenticationCallback(continuation)
            let handler = callback.completionHandler
            DispatchQueue.global().async { handler(expected, nil) }
        }
        XCTAssertEqual(received, expected)
    }

    @MainActor
    func testLateCallbackAfterFailedStartDoesNotResumeTwice() async {
        do {
            let _: URL = try await withCheckedThrowingContinuation { continuation in
                let callback = GoogleAuthenticationCallback(continuation)
                callback.complete(url: nil, error: GoogleSignInError.unavailable)
                callback.completionHandler(URL(string: "com.codmes.app:/oauth2redirect?code=late")!, nil)
            }
            XCTFail("Expected start failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, GoogleSignInError.unavailable.localizedDescription)
        }
    }

    @MainActor
    func testBackgroundCancellationIsReportedWithoutCrashing() async {
        do {
            let _: URL = try await withCheckedThrowingContinuation { continuation in
                let callback = GoogleAuthenticationCallback(continuation)
                DispatchQueue.global().async { callback.completionHandler(nil, GoogleSignInError.unavailable) }
            }
            XCTFail("Expected cancellation/error")
        } catch {
            XCTAssertEqual(error.localizedDescription, GoogleSignInError.unavailable.localizedDescription)
        }
    }

    func testAuthorizationUsesCodePKCEAndOpenIDScope() throws {
        let attempt = GoogleOAuthAttempt(
            clientID: "test.apps.googleusercontent.com",
            redirectURI: "com.codmes.app:/oauth2redirect"
        )
        let query = try XCTUnwrap(URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(attempt.authorizationURL.host, "accounts.google.com")
        XCTAssertEqual(values["response_type"], "code")
        XCTAssertEqual(values["code_challenge_method"], "S256")
        XCTAssertEqual(values["scope"], "openid email profile")
        XCTAssertEqual(values["redirect_uri"], "com.codmes.app:/oauth2redirect")
        XCTAssertEqual(values["code_challenge"]?.count, 43)
        XCTAssertNotEqual(values["code_challenge"], attempt.codeVerifier)
    }

    func testCallbackMustMatchRedirectAndState() throws {
        let attempt = GoogleOAuthAttempt(
            clientID: "test.apps.googleusercontent.com",
            redirectURI: "com.codmes.app:/oauth2redirect"
        )
        let valid = try XCTUnwrap(URL(string: "com.codmes.app:/oauth2redirect?state=\(attempt.state)&code=abc"))
        XCTAssertEqual(try attempt.authorizationCode(from: valid), "abc")
        XCTAssertThrowsError(try attempt.authorizationCode(from: URL(string: "com.codmes.app:/oauth2redirect?state=wrong&code=abc")!))
        XCTAssertThrowsError(try attempt.authorizationCode(from: URL(string: "com.codmes.app:/other?state=\(attempt.state)&code=abc")!))
    }

    func testGoogleConfigSelectsAppleClientID() throws {
        let data = Data(#"{"enabled":true,"clientIds":{"desktop":"desktop-id","macos":"mac-id","ios":"ios-id","android":null,"web":null},"bootstrapRequired":false,"adminLinked":true,"approvalMode":"ask","requiresSecureTransport":true}"#.utf8)
        let config = try JSONDecoder().decode(GoogleAuthConfig.self, from: data)
        #if os(iOS)
        XCTAssertEqual(config.appleClientID, "ios-id")
        #else
        XCTAssertEqual(config.appleClientID, "mac-id")
        #endif
    }

    func testRedirectSchemeUsesReversedGoogleClientID() {
        XCTAssertEqual(
            GoogleOAuthAttempt.expectedRedirectURI(for: "123-abc.apps.googleusercontent.com"),
            "com.googleusercontent.apps.123-abc:/oauth2redirect"
        )
        XCTAssertNil(GoogleOAuthAttempt.expectedRedirectURI(for: "invalid-client-id"))
    }

    func testServerCannotSelectAnotherPublisher() throws {
        try GoogleOAuthAttempt.validatePublisher(clientID: "publisher.apps.googleusercontent.com", serverClientID: "publisher.apps.googleusercontent.com")
        XCTAssertThrowsError(try GoogleOAuthAttempt.validatePublisher(clientID: "publisher.apps.googleusercontent.com", serverClientID: "other.apps.googleusercontent.com"))
        XCTAssertThrowsError(try GoogleOAuthAttempt.validatePublisher(clientID: "", serverClientID: ""))
    }

    func testTokenMatchesPublisherAndLoginAttempt() throws {
        let attempt = GoogleOAuthAttempt(clientID: "publisher.apps.googleusercontent.com", redirectURI: "com.codmes.app:/oauth2redirect")
        func token(audience: String, nonce: String) -> String {
            let payload = GoogleOAuthAttempt.base64URL(Data("{\"aud\":\"\(audience)\",\"nonce\":\"\(nonce)\"}".utf8))
            return "header.\(payload).signature"
        }
        try attempt.verifyNonce(in: token(audience: attempt.clientID, nonce: attempt.nonce))
        XCTAssertThrowsError(try attempt.verifyNonce(in: token(audience: "other", nonce: attempt.nonce)))
        XCTAssertThrowsError(try attempt.verifyNonce(in: token(audience: attempt.clientID, nonce: "other")))
        XCTAssertThrowsError(try attempt.verifyNonce(in: "invalid"))
    }
}
