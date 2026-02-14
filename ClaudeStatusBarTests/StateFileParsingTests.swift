import XCTest
@testable import Claude_Status_Bar

final class StateFileParsingTests: XCTestCase {

    // MARK: - State File Parsing

    func testEmptyStateFileDecoding() throws {
        let json = """
        {"sessions":{}}
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stateFile = try decoder.decode(StateFile.self, from: json)
        XCTAssertTrue(stateFile.sessions.isEmpty)
    }

    func testStateFileWithSessionDecoding() throws {
        let json = """
        {
          "sessions": {
            "abc-123": {
              "id": "abc-123",
              "status": "running",
              "project_dir": "/Users/test/project",
              "project_name": "project",
              "last_event": "UserPromptSubmit",
              "last_updated": "2025-01-15T10:30:00Z"
            }
          }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stateFile = try decoder.decode(StateFile.self, from: json)

        XCTAssertEqual(stateFile.sessions.count, 1)
        let session = try XCTUnwrap(stateFile.sessions["abc-123"])
        XCTAssertEqual(session.id, "abc-123")
        XCTAssertEqual(session.status, .running)
        XCTAssertEqual(session.projectDir, "/Users/test/project")
        XCTAssertEqual(session.projectName, "project")
        XCTAssertEqual(session.lastEvent, "UserPromptSubmit")
    }

    func testStateFileWithMultipleSessionsDecoding() throws {
        let json = """
        {
          "sessions": {
            "s1": {
              "id": "s1",
              "status": "idle",
              "project_dir": "/tmp/a",
              "project_name": "a",
              "last_event": "Stop",
              "last_updated": "2025-01-15T10:30:00Z"
            },
            "s2": {
              "id": "s2",
              "status": "pending",
              "project_dir": "/tmp/b",
              "project_name": "b",
              "last_event": "PreToolUse",
              "last_updated": "2025-01-15T10:31:00Z"
            }
          }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stateFile = try decoder.decode(StateFile.self, from: json)

        XCTAssertEqual(stateFile.sessions.count, 2)
        XCTAssertEqual(stateFile.sessions["s1"]?.status, .idle)
        XCTAssertEqual(stateFile.sessions["s2"]?.status, .pending)
    }

    func testStateFileRoundTrip() throws {
        let session = Session(
            id: "test-id",
            status: .running,
            projectDir: "/tmp/test",
            projectName: "test",
            lastEvent: "SessionStart",
            lastUpdated: Date(timeIntervalSince1970: 1705312200)
        )
        let stateFile = StateFile(sessions: ["test-id": session])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(stateFile)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StateFile.self, from: data)

        XCTAssertEqual(decoded.sessions.count, 1)
        let decodedSession = try XCTUnwrap(decoded.sessions["test-id"])
        XCTAssertEqual(decodedSession.id, session.id)
        XCTAssertEqual(decodedSession.status, session.status)
        XCTAssertEqual(decodedSession.projectDir, session.projectDir)
    }

    // MARK: - Session Staleness

    func testSessionIsNotStaleWhenRecent() {
        let session = Session(
            id: "s1",
            status: .running,
            projectDir: "/tmp",
            projectName: "test",
            lastEvent: "SessionStart",
            lastUpdated: Date()
        )
        XCTAssertFalse(session.isStale)
    }

    func testSessionIsStaleAfterFiveMinutes() {
        let session = Session(
            id: "s1",
            status: .running,
            projectDir: "/tmp",
            projectName: "test",
            lastEvent: "SessionStart",
            lastUpdated: Date().addingTimeInterval(-301)
        )
        XCTAssertTrue(session.isStale)
    }

    func testSessionIsNotStaleJustUnderFiveMinutes() {
        let session = Session(
            id: "s1",
            status: .running,
            projectDir: "/tmp",
            projectName: "test",
            lastEvent: "SessionStart",
            lastUpdated: Date().addingTimeInterval(-299)
        )
        XCTAssertFalse(session.isStale)
    }

    // MARK: - SessionStatus

    func testSessionStatusLabels() {
        XCTAssertEqual(SessionStatus.idle.label, "Idle")
        XCTAssertEqual(SessionStatus.completed.label, "Completed")
        XCTAssertEqual(SessionStatus.pending.label, "Waiting for input")
        XCTAssertEqual(SessionStatus.running.label, "Running")
    }

    func testSessionStatusLabels_matchExpectedValues() {
        // Verify color objects exist (non-nil) for each status
        _ = SessionStatus.idle.color
        _ = SessionStatus.completed.color
        _ = SessionStatus.pending.color
        _ = SessionStatus.running.color
    }

    func testCompletedStatusDecoding() throws {
        let json = """
        {
          "sessions": {
            "s1": {
              "id": "s1",
              "status": "completed",
              "project_dir": "/tmp/proj",
              "project_name": "proj",
              "last_event": "Stop",
              "last_updated": "2025-01-15T10:30:00Z"
            }
          }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stateFile = try decoder.decode(StateFile.self, from: json)

        let session = try XCTUnwrap(stateFile.sessions["s1"])
        XCTAssertEqual(session.status, .completed)
    }
}
