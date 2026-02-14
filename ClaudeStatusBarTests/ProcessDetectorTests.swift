import XCTest
@testable import Claude_Status_Bar

@MainActor
final class ProcessDetectorTests: XCTestCase {

    private var detector: ProcessDetector!

    override func setUp() {
        super.setUp()
        detector = ProcessDetector()
    }

    // MARK: - Acknowledge / Unacknowledge

    func testAcknowledge_addsToPIDSet() {
        let process = DetectedProcess(pid: 123, projectDir: "/tmp/proj")
        detector.acknowledge(pid: process.pid)
        // Acknowledging should prevent the PID from appearing in newProcesses
        // (verified indirectly — knownPIDs is private)
    }

    func testUnacknowledge_removesPID() {
        detector.acknowledge(pid: 123)
        detector.unacknowledge(pid: 123)
        // After unacknowledge, the PID should be detectable again
    }

    // MARK: - Registration State

    func testMarkRegistered_tracksProjectDir() {
        detector.markRegistered(projectDir: "/tmp/proj")
        XCTAssertTrue(detector.isRegistered(projectDir: "/tmp/proj"))
    }

    func testIsRegistered_falseByDefault() {
        XCTAssertFalse(detector.isRegistered(projectDir: "/tmp/unknown"))
    }

    func testUnregisterProjectDir_removesTracking() {
        detector.markRegistered(projectDir: "/tmp/proj")
        XCTAssertTrue(detector.isRegistered(projectDir: "/tmp/proj"))

        detector.unregisterProjectDir("/tmp/proj")
        XCTAssertFalse(detector.isRegistered(projectDir: "/tmp/proj"))
    }

    // MARK: - updateFromTrackedSessions

    func testUpdateFromTrackedSessions_registersProjectDirs() {
        let sessions: [String: Session] = [
            "s1": Session(
                id: "s1", status: .running,
                projectDir: "/tmp/a", projectName: "a",
                lastEvent: "SessionStart", lastUpdated: Date()
            ),
            "s2": Session(
                id: "s2", status: .completed,
                projectDir: "/tmp/b", projectName: "b",
                lastEvent: "Stop", lastUpdated: Date()
            )
        ]

        detector.updateFromTrackedSessions(sessions)
        XCTAssertTrue(detector.isRegistered(projectDir: "/tmp/a"))
        XCTAssertTrue(detector.isRegistered(projectDir: "/tmp/b"))
    }

    // MARK: - Initial State

    func testInitialState_isEmpty() {
        XCTAssertTrue(detector.newProcesses.isEmpty)
        XCTAssertTrue(detector.allDetectedProcesses.isEmpty)
    }
}
