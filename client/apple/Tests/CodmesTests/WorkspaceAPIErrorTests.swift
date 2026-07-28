import XCTest
@testable import Codmes

final class WorkspaceAPIErrorTests: XCTestCase {
    func testWorkspaceUnauthorizedKeepsServerTokenGuidance() {
        let error = WorkspaceAPIError.badStatus(
            401,
            #"{"ok":false,"error":"Unauthorized."}"#
        )

        XCTAssertEqual(
            error.errorDescription,
            "Workspace server rejected the request. Check the server token in Settings."
        )
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
}
