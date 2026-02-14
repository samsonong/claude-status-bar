import XCTest
@testable import Claude_Status_Bar

final class HookEventTests: XCTestCase {

    // MARK: - Hook Event → Status Mapping

    func testSessionStartDerivedStatus() {
        let event = HookEvent(sessionId: "s1", hookEventName: "SessionStart", cwd: "/tmp", toolName: nil, isInterrupt: nil)
        XCTAssertEqual(event.derivedStatus, .idle)
    }

    func testUserPromptSubmitDerivedStatus() {
        let event = HookEvent(sessionId: "s1", hookEventName: "UserPromptSubmit", cwd: "/tmp", toolName: nil, isInterrupt: nil)
        XCTAssertEqual(event.derivedStatus, .running)
    }

    func testPreToolUseAskUserQuestionDerivedStatus() {
        let event = HookEvent(sessionId: "s1", hookEventName: "PreToolUse", cwd: "/tmp", toolName: "AskUserQuestion", isInterrupt: nil)
        XCTAssertEqual(event.derivedStatus, .pending)
    }

    func testPreToolUseOtherToolDerivedStatus() {
        let event = HookEvent(sessionId: "s1", hookEventName: "PreToolUse", cwd: "/tmp", toolName: "ReadFile", isInterrupt: nil)
        XCTAssertEqual(event.derivedStatus, .running)
    }

    func testPermissionRequestDerivedStatus() {
        let event = HookEvent(sessionId: "s1", hookEventName: "PermissionRequest", cwd: "/tmp", toolName: "Bash", isInterrupt: nil)
        XCTAssertEqual(event.derivedStatus, .pending)
    }

    func testPostToolUseDerivedStatus() {
        let event = HookEvent(sessionId: "s1", hookEventName: "PostToolUse", cwd: "/tmp", toolName: "AskUserQuestion", isInterrupt: nil)
        XCTAssertEqual(event.derivedStatus, .running)
    }

    func testPostToolUseFailureInterruptDerivedStatus() {
        let event = HookEvent(sessionId: "s1", hookEventName: "PostToolUseFailure", cwd: "/tmp", toolName: "Bash", isInterrupt: true)
        XCTAssertEqual(event.derivedStatus, .idle)
    }

    func testPostToolUseFailureErrorDerivedStatus() {
        let event = HookEvent(sessionId: "s1", hookEventName: "PostToolUseFailure", cwd: "/tmp", toolName: "Bash", isInterrupt: false)
        XCTAssertEqual(event.derivedStatus, .running)
    }

    func testPostToolUseFailureNoInterruptFieldDerivedStatus() {
        let event = HookEvent(sessionId: "s1", hookEventName: "PostToolUseFailure", cwd: "/tmp", toolName: "Bash", isInterrupt: nil)
        XCTAssertEqual(event.derivedStatus, .running)
    }

    func testStopDerivedStatus() {
        let event = HookEvent(sessionId: "s1", hookEventName: "Stop", cwd: "/tmp", toolName: nil, isInterrupt: nil)
        XCTAssertEqual(event.derivedStatus, .completed)
    }

    func testSessionEndDerivedStatus() {
        let event = HookEvent(sessionId: "s1", hookEventName: "SessionEnd", cwd: "/tmp", toolName: nil, isInterrupt: nil)
        XCTAssertNil(event.derivedStatus)
    }

    func testUnknownEventDerivedStatus() {
        let event = HookEvent(sessionId: "s1", hookEventName: "UnknownEvent", cwd: "/tmp", toolName: nil, isInterrupt: nil)
        XCTAssertNil(event.derivedStatus)
    }

    func testIsSessionEnd() {
        let endEvent = HookEvent(sessionId: "s1", hookEventName: "SessionEnd", cwd: nil, toolName: nil, isInterrupt: nil)
        XCTAssertTrue(endEvent.isSessionEnd)

        let otherEvent = HookEvent(sessionId: "s1", hookEventName: "Stop", cwd: nil, toolName: nil, isInterrupt: nil)
        XCTAssertFalse(otherEvent.isSessionEnd)
    }
}
