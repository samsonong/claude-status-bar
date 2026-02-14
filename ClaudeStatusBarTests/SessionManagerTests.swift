import XCTest
@testable import Claude_Status_Bar

@MainActor
final class SessionManagerTests: XCTestCase {

    // MARK: - displayName

    func testDisplayName_normalPath() {
        XCTAssertEqual(SessionManager.displayName(for: "/Users/test/my-project"), "my-project")
    }

    func testDisplayName_rootPath() {
        XCTAssertEqual(SessionManager.displayName(for: "/"), "Unknown")
    }

    func testDisplayName_emptyPath() {
        XCTAssertEqual(SessionManager.displayName(for: ""), "Unknown")
    }

    func testDisplayName_unknownString() {
        XCTAssertEqual(SessionManager.displayName(for: "Unknown"), "Unknown")
    }

    func testDisplayName_nestedPath() {
        XCTAssertEqual(SessionManager.displayName(for: "/home/user/workspace/deep/project"), "project")
    }

    // MARK: - sfSymbolName

    func testSfSymbolName_letter() {
        XCTAssertEqual(SessionManager.sfSymbolName(for: "a"), "a.circle.fill")
        XCTAssertEqual(SessionManager.sfSymbolName(for: "z"), "z.circle.fill")
    }

    func testSfSymbolName_uppercaseLetter() {
        XCTAssertEqual(SessionManager.sfSymbolName(for: "A"), "a.circle.fill")
    }

    func testSfSymbolName_digit() {
        XCTAssertEqual(SessionManager.sfSymbolName(for: "3"), "3.circle.fill")
    }

    func testSfSymbolName_invalidChar() {
        XCTAssertEqual(SessionManager.sfSymbolName(for: "!"), "questionmark.circle.fill")
    }

    func testSfSymbolName_emptyString() {
        XCTAssertEqual(SessionManager.sfSymbolName(for: ""), "questionmark.circle.fill")
    }

    // MARK: - computeDistinguishingLabels

    func testComputeLabels_empty() {
        let result = SessionManager.computeDistinguishingLabels(for: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testComputeLabels_singleProject() {
        let result = SessionManager.computeDistinguishingLabels(for: ["/Users/test/alpha"])
        XCTAssertEqual(result["/Users/test/alpha"], "a")
    }

    func testComputeLabels_uniqueFirstChars() {
        let dirs = ["/tmp/alpha", "/tmp/beta", "/tmp/gamma"]
        let result = SessionManager.computeDistinguishingLabels(for: dirs)
        XCTAssertEqual(result["/tmp/alpha"], "a")
        XCTAssertEqual(result["/tmp/beta"], "b")
        XCTAssertEqual(result["/tmp/gamma"], "g")
    }

    func testComputeLabels_sharedPrefix() {
        // "app-frontend" and "app-backend" share prefix "app-"
        // Distinguishing char after prefix: "f" vs "b"
        let dirs = ["/tmp/app-frontend", "/tmp/app-backend"]
        let result = SessionManager.computeDistinguishingLabels(for: dirs)
        XCTAssertEqual(result["/tmp/app-frontend"], "f")
        XCTAssertEqual(result["/tmp/app-backend"], "b")
    }

    func testComputeLabels_mixedUniqueAndShared() {
        let dirs = ["/tmp/alpha", "/tmp/app-one", "/tmp/app-two"]
        let result = SessionManager.computeDistinguishingLabels(for: dirs)
        // "alpha" starts with 'a', "app-one" and "app-two" also start with 'a'
        // The group of 3 items starting with 'a' has common prefix "a"
        // alpha → 'l' (first alphanumeric after "a"), app-one → 'p' (first after "a"), app-two → 'p'
        // 'p' collides → numbered as "1" and "2"
        XCTAssertEqual(result["/tmp/alpha"], "l")
        // app-one and app-two both get "p" initially, resolved by numbering
        let appOneLabel = result["/tmp/app-one"]!
        let appTwoLabel = result["/tmp/app-two"]!
        XCTAssertNotEqual(appOneLabel, appTwoLabel)
    }

    func testComputeLabels_identicalNames() {
        // Two different paths with the same project name
        let dirs = ["/home/user1/project", "/home/user2/project"]
        let result = SessionManager.computeDistinguishingLabels(for: dirs)
        // Both have name "project", same first char, common prefix is "project"
        // Name equals prefix → use last alphanumeric char: 't'
        // Collision → numbered
        let l1 = result["/home/user1/project"]!
        let l2 = result["/home/user2/project"]!
        XCTAssertNotEqual(l1, l2)
    }

    func testComputeLabels_rootAndUnknown() {
        // Root and empty paths produce "Unknown" display name
        let dirs = ["/", "/tmp/real-project"]
        let result = SessionManager.computeDistinguishingLabels(for: dirs)
        XCTAssertEqual(result["/tmp/real-project"], "r")
        // "/" → displayName "unknown" → first char 'u'
        XCTAssertEqual(result["/"], "u")
    }
}
