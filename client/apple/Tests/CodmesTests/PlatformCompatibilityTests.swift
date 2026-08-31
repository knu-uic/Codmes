import XCTest
@testable import Codmes

final class PlatformCompatibilityTests: XCTestCase {
    func testMatchesOnlyDeclaredPlatform() {
        XCTAssertTrue(CodmesPlatform.isSupported(by: [], formFactors: [], current: "macos", currentFormFactor: "desktop"))
        XCTAssertTrue(CodmesPlatform.isSupported(by: ["macos"], formFactors: ["desktop"], current: "macos", currentFormFactor: "desktop"))
        XCTAssertTrue(CodmesPlatform.isSupported(by: ["iOS"], formFactors: ["phone"], current: "ios", currentFormFactor: "phone"))
        XCTAssertTrue(CodmesPlatform.isSupported(by: ["ipados"], formFactors: [], current: "ios", currentFormFactor: "tablet"))
        XCTAssertFalse(CodmesPlatform.isSupported(by: ["ios"], formFactors: ["phone"], current: "ios", currentFormFactor: "tablet"))
        XCTAssertFalse(CodmesPlatform.isSupported(by: ["macos"], formFactors: ["desktop"], current: "ios", currentFormFactor: "phone"))
    }
}
