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
}
