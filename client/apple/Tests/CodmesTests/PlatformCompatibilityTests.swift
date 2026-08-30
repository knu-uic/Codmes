import XCTest
@testable import Codmes

final class PlatformCompatibilityTests: XCTestCase {
    func testMatchesOnlyDeclaredPlatform() {
        XCTAssertTrue(CodmesPlatform.isSupported(by: [], current: "macos"))
        XCTAssertTrue(CodmesPlatform.isSupported(by: ["macos"], current: "macos"))
        XCTAssertTrue(CodmesPlatform.isSupported(by: ["iOS"], current: "ios"))
        XCTAssertFalse(CodmesPlatform.isSupported(by: ["macos"], current: "ios"))
        XCTAssertFalse(CodmesPlatform.isSupported(by: ["ios"], current: "ipados"))
    }
}
