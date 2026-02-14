import XCTest
@testable import Claude_Status_Bar

final class HookRegistrarTests: XCTestCase {

    private var tempDir: String!
    private var registrar: HookRegistrar!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "HookRegistrarTests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        registrar = HookRegistrar()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    // MARK: - Hook Registration

    func testRegisterHooks_createsSettingsFile() {
        // Create .claude directory so project-level settings are used
        let claudeDir = tempDir + "/.claude"
        try! FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: claudeDir + "/settings.local.json", contents: "{}".data(using: .utf8))

        let result = registrar.registerHooks(forProject: tempDir)
        XCTAssertTrue(result)

        // Verify settings file was updated
        let data = FileManager.default.contents(atPath: claudeDir + "/settings.local.json")!
        let settings = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = settings["hooks"] as! [String: Any]

        // All monitored events should be present
        for event in HookRegistrar.monitoredEvents {
            XCTAssertNotNil(hooks[event], "Missing hook for event: \(event)")
        }
    }

    func testHasHooksRegistered_trueAfterRegistration() {
        let claudeDir = tempDir + "/.claude"
        try! FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: claudeDir + "/settings.local.json", contents: "{}".data(using: .utf8))

        _ = registrar.registerHooks(forProject: tempDir)
        XCTAssertTrue(registrar.hasHooksRegistered(forProject: tempDir))
    }

    func testHasHooksRegistered_falseWithoutRegistration() {
        XCTAssertFalse(registrar.hasHooksRegistered(forProject: tempDir))
    }

    func testRemoveHooks_cleansUp() {
        let claudeDir = tempDir + "/.claude"
        try! FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: claudeDir + "/settings.local.json", contents: "{}".data(using: .utf8))

        _ = registrar.registerHooks(forProject: tempDir)
        XCTAssertTrue(registrar.hasHooksRegistered(forProject: tempDir))

        registrar.removeHooks(forProject: tempDir)
        XCTAssertFalse(registrar.hasHooksRegistered(forProject: tempDir))
    }

    func testRegisterHooks_preservesExistingSettings() {
        let claudeDir = tempDir + "/.claude"
        try! FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)

        // Pre-populate with an existing setting
        let existing = """
        {"customSetting": true}
        """.data(using: .utf8)!
        FileManager.default.createFile(atPath: claudeDir + "/settings.local.json", contents: existing)

        _ = registrar.registerHooks(forProject: tempDir)

        let data = FileManager.default.contents(atPath: claudeDir + "/settings.local.json")!
        let settings = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(settings["customSetting"] as? Bool, true)
        XCTAssertNotNil(settings["hooks"])
    }

    func testRegisterHooks_preservesExistingHooksForOtherEvents() {
        let claudeDir = tempDir + "/.claude"
        try! FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)

        // Pre-populate with a hook for a different event
        let existing = """
        {"hooks": {"CustomEvent": [{"hooks": [{"type": "command", "command": "echo custom"}]}]}}
        """.data(using: .utf8)!
        FileManager.default.createFile(atPath: claudeDir + "/settings.local.json", contents: existing)

        _ = registrar.registerHooks(forProject: tempDir)

        let data = FileManager.default.contents(atPath: claudeDir + "/settings.local.json")!
        let settings = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = settings["hooks"] as! [String: Any]
        XCTAssertNotNil(hooks["CustomEvent"], "Existing hook for CustomEvent should be preserved")
    }

    func testRegisterHooks_idempotent() {
        let claudeDir = tempDir + "/.claude"
        try! FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: claudeDir + "/settings.local.json", contents: "{}".data(using: .utf8))

        _ = registrar.registerHooks(forProject: tempDir)
        _ = registrar.registerHooks(forProject: tempDir)

        let data = FileManager.default.contents(atPath: claudeDir + "/settings.local.json")!
        let settings = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = settings["hooks"] as! [String: Any]

        // Each event should have exactly 1 matcher group (not duplicated)
        for event in HookRegistrar.monitoredEvents {
            let groups = hooks[event] as! [[String: Any]]
            XCTAssertEqual(groups.count, 1, "Event \(event) should have exactly 1 matcher group after double registration")
        }
    }

    // MARK: - Hook Script

    func testInstallHookScript_createsFile() {
        registrar.installHookScript()

        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let scriptPath = "\(homeDir)/.claude/hooks/claude-status-bar.sh"
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptPath))

        // Verify it's executable
        let attrs = try! FileManager.default.attributesOfItem(atPath: scriptPath)
        let permissions = attrs[.posixPermissions] as! Int
        XCTAssertTrue(permissions & 0o111 != 0, "Script should be executable")
    }
}
