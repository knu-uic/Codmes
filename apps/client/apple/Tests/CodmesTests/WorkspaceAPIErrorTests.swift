import XCTest
@testable import Codmes

final class WorkspaceAPIErrorTests: XCTestCase {
    func testConnectionAndAppLockSettingsRemainAvailableWithoutServer() {
        XCTAssertFalse(SettingsSection.connection.requiresServerConnection)
        XCTAssertFalse(SettingsSection.profile.requiresServerConnection)
        for section in SettingsSection.allCases where section != .connection && section != .profile {
            XCTAssertTrue(section.requiresServerConnection, "\(section) is managed by the server")
        }
    }

    @MainActor
    func testClientLaunchWithoutAccountDoesNotAttemptDefaultServerConnection() async {
        let store = WorkspaceStore()
        store.serverURLText = "http://127.0.0.1:1/no-saved-login-test"
        store.serverAccountToken = ""
        store.serverAuthToken = ""
        await store.restoreServerConnectionIfAvailable()
        XCTAssertFalse(store.isWorkspaceConnected)
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.connectionStep, "Idle")
        XCTAssertNil(store.workspace)
    }

    @MainActor
    func testDisconnectedChatDoesNotCreateServerSessionOrConsumeMessage() async {
        let store = WorkspaceStore()
        store.serverURLText = "http://127.0.0.1:1/no-saved-login-test"
        store.serverAccountToken = ""
        store.serverAuthToken = ""
        let initialLines = store.chatLines
        await store.sendChatMessage("Offline draft")
        XCTAssertEqual(store.chatLines, initialLines)
        XCTAssertNil(store.liveSessionId)
        XCTAssertFalse(store.isLoading)
        XCTAssertTrue(store.statusMessage.contains("Connection"))
    }

    func testWorkspaceUnauthorizedExplainsGoogleSignInInsteadOfLegacyServerToken() {
        let error = WorkspaceAPIError.badStatus(
            401,
            #"{"ok":false,"error":"Unauthorized."}"#
        )

        XCTAssertEqual(
            error.errorDescription,
            "서버 로그인 세션이 없거나 만료되었습니다. Codmes ID·비밀번호 또는 연결된 Google 계정으로 다시 로그인하세요."
        )
    }

    func testHealthReportsWhenSignInIsRequiredBeforeLoadingWorkspace() throws {
        let health = try JSONDecoder().decode(HealthResponse.self, from: Data(#"{"ok":true,"service":"codmes","authRequired":true}"#.utf8))
        XCTAssertEqual(health.authRequired, true)
    }

    func testHealthWithoutAuthFieldStillDecodes() throws {
        let health = try JSONDecoder().decode(HealthResponse.self, from: Data(#"{"ok":true,"service":"codmes"}"#.utf8))
        XCTAssertNil(health.authRequired)
    }

    func testPluginLoginUnauthorizedShowsUpstreamMessage() {
        let error = WorkspaceAPIError.badStatus(
            401,
            #"{"ok":false,"error":"아이디 또는 비밀번호가 올바르지 않습니다."}"#
        )

        XCTAssertEqual(
            error.errorDescription,
            "아이디 또는 비밀번호가 올바르지 않습니다."
        )
    }

    func testCodmesAccountDecodesWithoutGoogleConnection() throws {
        let response = try JSONDecoder().decode(CodmesAccountResponse.self, from: Data(#"{"user":{"id":"account-id","username":"mycodmes","displayName":"My Codmes","email":"","credentialsConfigured":true,"googleLinked":false}}"#.utf8))
        XCTAssertEqual(response.user.username, "mycodmes")
        XCTAssertEqual(response.user.credentialsConfigured, true)
        XCTAssertEqual(response.user.googleLinked, false)
    }

    func testExistingGooglePendingIdentityRemainsDecodable() throws {
        let identity = try JSONDecoder().decode(GoogleAccountIdentity.self, from: Data(#"{"id":"existing-account","displayName":"Existing user","email":"example@example.com"}"#.utf8))
        XCTAssertNil(identity.credentialsConfigured)
        XCTAssertNil(identity.username)
    }

    func testGoogleSignupRequestsCodmesCredentialsWithoutIssuingSession() throws {
        let response = try JSONDecoder().decode(GoogleClientLoginResponse.self, from: Data(#"{"status":"account_setup_required","user":{"id":"","email":"example@example.com","displayName":"Example","credentialsConfigured":false,"googleLinked":true}}"#.utf8))
        XCTAssertEqual(response.status, "account_setup_required")
        XCTAssertNil(response.token)
        XCTAssertEqual(response.user?.credentialsConfigured, false)
    }
}
