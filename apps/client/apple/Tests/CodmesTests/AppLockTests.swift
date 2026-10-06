import Foundation
import XCTest
@testable import Codmes

final class AppLockTests: XCTestCase {
    @MainActor
    func testLockIsOptionalAndChangesRequireTheExistingPIN() {
        var saved: String?
        let lock = AppLockStore(read: { saved }, write: { saved = $0; return true }, delete: { saved = nil; return true })
        XCTAssertFalse(lock.enabled)
        lock.lock()
        XCTAssertFalse(lock.isLocked)
        XCTAssertFalse(lock.setPIN(current: "", new: "1234", confirmation: "9999"))
        XCTAssertNil(saved)
        XCTAssertTrue(lock.setPIN(current: "", new: "1234", confirmation: "1234"))
        lock.lock()
        XCTAssertTrue(lock.isLocked)
        XCTAssertFalse(lock.unlock("9999"))
        XCTAssertTrue(lock.unlock("1234"))
        XCTAssertFalse(lock.setPIN(current: "9999", new: "0123", confirmation: "0123"))
        XCTAssertFalse(lock.disable(current: "9999"))
        XCTAssertTrue(lock.disable(current: "1234"))
        XCTAssertNil(saved)
        XCTAssertFalse(lock.enabled)
    }

    @MainActor
    func testSavedLockStartsLockedAndRateLimitsAttempts() throws {
        let saved = try XCTUnwrap(AppLockPIN.encode("1234"))
        var time = Date(timeIntervalSince1970: 100)
        let lock = AppLockStore(read: { saved }, write: { _ in false }, delete: { false }, now: { time })
        XCTAssertTrue(lock.isLocked)
        for _ in 0..<5 { XCTAssertFalse(lock.unlock("9999")) }
        XCTAssertFalse(lock.unlock("1234"))
        time.addTimeInterval(61)
        XCTAssertTrue(lock.unlock("1234"))
        XCTAssertFalse(lock.isLocked)
    }

    func testOnlyFourASCIIDigitsAreAccepted() {
        XCTAssertTrue(AppLockPIN.isValid("0123"))
        for invalid in ["", "123", "12345", "１２３４", "1a34", "12 4"] {
            XCTAssertFalse(AppLockPIN.isValid(invalid))
        }
    }

    func testSaltedPINHashRejectsWrongPINAndMalformedValues() throws {
        let first = try XCTUnwrap(AppLockPIN.encode("0123"))
        let second = try XCTUnwrap(AppLockPIN.encode("0123"))
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.contains("0123"))
        XCTAssertTrue(AppLockPIN.verify("0123", encoded: first))
        XCTAssertFalse(AppLockPIN.verify("9999", encoded: first))
        XCTAssertFalse(AppLockPIN.verify("0123", encoded: "invalid"))
    }

    func testGoogleProfileIsAvailableWithoutPINSetup() throws {
        let response = try JSONDecoder().decode(GoogleClientProfileResponse.self, from: Data(#"{"user":{"id":"user","email":"test@example.com","displayName":"Tester"},"setupRequired":false,"profile":{"id":"profile","name":"Tester","locked":false}}"#.utf8))
        XCTAssertEqual(response.user.email, "test@example.com")
        XCTAssertFalse(response.setupRequired)
        XCTAssertFalse(try XCTUnwrap(response.profile).locked)
    }
}
