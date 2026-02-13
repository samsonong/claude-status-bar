import XCTest
@testable import Claude_Status_Bar

final class HookEventTests: XCTestCase {

    // MARK: - Hook Event → Status Mapping

    func testSessionStartDerivedStatus() {
        let event = HookEvent(sessionId: "s1", hookEventName: "SessionStart", cwd: "/tmp", toolName: nil)
        XCTAssertEqual(event.derivedStatus, .running)
    }

    func testUserPromptSubmitDerivedStatus() {
        let event = HookEvent(sessionId: "s1", hookEventName: "UserPromptSubmit", cwd: "/tmp", toolName: nil)
        XCTAssertEqual(event.derivedStatus, .running)
    }

    func testPreToolUseAskUserQuestionDerivedStatus() {
        let event = HookEvent(sessionId: "s1", hookEventName: "PreToolUse", cwd: "/tmp", toolName: "AskUserQuestion")
        XCTAssertEqual(event.derivedStatus, .pending)
    }

    func testPreToolUseOtherToolDerivedStatus() {
        let event = HookEvent(sessionId: "s1", hookEventName: "PreToolUse", cwd: "/tmp", toolName: "ReadFile")
        XCTAssertEqual(event.derivedStatus, .running)
    }

    func testPostToolUseDerivedStatus() {
        let event = HookEvent(sessionId: "s1", hookEventName: "PostToolUse", cwd: "/tmp", toolName: "AskUserQuestion")
        XCTAssertEqual(event.derivedStatus, .running)
    }

    func testStopDerivedStatus() {
        let event = HookEvent(sessionId: "s1", hookEventName: "Stop", cwd: "/tmp", toolName: nil)
        XCTAssertEqual(event.derivedStatus, .idle)
    }

    func testSessionEndDerivedStatus() {
        let event = HookEvent(sessionId: "s1", hookEventName: "SessionEnd", cwd: "/tmp", toolName: nil)
        XCTAssertNil(event.derivedStatus)
    }

    func testUnknownEventDerivedStatus() {
        let event = HookEvent(sessionId: "s1", hookEventName: "UnknownEvent", cwd: "/tmp", toolName: nil)
        XCTAssertNil(event.derivedStatus)
    }

    func testIsSessionEnd() {
        let endEvent = HookEvent(sessionId: "s1", hookEventName: "SessionEnd", cwd: nil, toolName: nil)
        XCTAssertTrue(endEvent.isSessionEnd)

        let otherEvent = HookEvent(sessionId: "s1", hookEventName: "Stop", cwd: nil, toolName: nil)
        XCTAssertFalse(otherEvent.isSessionEnd)
    }
}
