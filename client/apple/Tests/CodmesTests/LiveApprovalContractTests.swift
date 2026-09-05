import XCTest
@testable import Codmes

final class LiveApprovalContractTests: XCTestCase {
    func testApprovalRequestCarriesInboxApprovalId() throws {
        let envelope = try JSONDecoder().decode(
            LiveEnvelope.self,
            from: Data(#"{"kind":"runtime.event","type":"approval.request","approvalId":"approval-1"}"#.utf8)
        )

        XCTAssertEqual(envelope.approvalId, "approval-1")
    }

    func testApprovalResponseUsesApprovalId() throws {
        let data = try JSONEncoder().encode(
            ApprovalRespondParams(approvalId: "approval-1", approved: true)
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["approvalId"] as? String, "approval-1")
        XCTAssertEqual(json["approved"] as? Bool, true)
        XCTAssertNil(json["sessionId"])
    }

    func testPromptCarriesPluginSurfaceRoute() throws {
        let data = try JSONEncoder().encode(
            PromptSubmitParams(
                sessionId: "session-1",
                message: "내 누적성적을 알려줘",
                contextRequest: nil,
                surface: "knu",
                route: "lms"
            )
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["surface"] as? String, "knu")
        XCTAssertEqual(json["route"] as? String, "lms")
    }

    func testPromptResultCarriesPostProcessedReply() throws {
        let envelope = try JSONDecoder().decode(
            LiveEnvelope.self,
            from: Data(#"{"kind":"result","id":"prompt-1","result":{"ok":true,"reply":"![그림](http://127.0.0.1:8000/api/notice-assets/118/content)"}}"#.utf8)
        )

        XCTAssertEqual(
            envelope.result?.reply,
            "![그림](http://127.0.0.1:8000/api/notice-assets/118/content)"
        )
    }
}
