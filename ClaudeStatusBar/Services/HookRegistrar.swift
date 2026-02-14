import Foundation
import os

/// Manages registration and removal of Claude Code hooks in settings.json files.
/// Hooks are entries in the `hooks` object of either `~/.claude/settings.json` (global)
/// or `<project>/.claude/settings.local.json` (project-level).
///
/// The registrar merges hook entries without overwriting existing hooks for
/// the same event names — it appends to the existing arrays.
///
/// Safety: `@unchecked Sendable` because this class has no mutable instance state.
/// All stored properties (`fileManager`, `logger`) are `let`-bound and thread-safe.
/// All methods are pure functions over file system I/O with no shared mutable state.
final class HookRegistrar: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.samsonong.ClaudeStatusBar", category: "HookRegistrar")
    private let fileManager = FileManager.default

    /// The hook events that the status bar app needs to monitor.
    static let monitoredEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "Stop",
        "SessionEnd"
    ]

    /// The marker comment used to identify our hook entries.
    static let hookMarker = "claude-status-bar"

    /// Path to the installed hook script.
    private let hookScriptPath: String

    init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        hookScriptPath = "\(homeDir)/.claude/hooks/claude-status-bar.sh"
    }

    // MARK: - Public API

    /// Registers hooks for a project by merging into the global settings.json.
    /// If the project has a `.claude/settings.local.json`, hooks are added there instead.
    ///
    /// - Parameter projectDir: The project directory path.
    /// - Returns: True if hooks were successfully registered.
    @discardableResult
    func registerHooks(forProject projectDir: String) -> Bool {
        // Ensure the hook script is installed
        installHookScript()

        // Determine which settings file to use
        let projectSettingsPath = "\(projectDir)/.claude/settings.local.json"
        let globalSettingsPath = globalSettingsFilePath()

        let settingsPath: String
        if fileManager.fileExists(atPath: projectSettingsPath) {
            settingsPath = projectSettingsPath
        } else {
            settingsPath = globalSettingsPath
        }

        let result = withSettingsLock(for: settingsPath) {
            mergeHooks(intoSettingsAt: settingsPath)
        } ?? false
        if result {
            Self.logger.info("Registered hooks for project: \(projectDir)")
        } else {
            Self.logger.warning("Failed to register hooks for project: \(projectDir)")
        }
        return result
    }

    /// Removes hooks for a project from the appropriate settings file.
    ///
    /// - Parameter projectDir: The project directory path.
    func removeHooks(forProject projectDir: String) {
        let projectSettingsPath = "\(projectDir)/.claude/settings.local.json"
        let globalSettingsPath = globalSettingsFilePath()

        // Try removing from project-level first, then global
        if fileManager.fileExists(atPath: projectSettingsPath) {
            withSettingsLock(for: projectSettingsPath) {
                removeHooks(fromSettingsAt: projectSettingsPath)
            }
        }
        withSettingsLock(for: globalSettingsPath) {
            removeHooks(fromSettingsAt: globalSettingsPath)
        }
    }

    /// Checks whether hooks are already registered for a project.
    ///
    /// - Parameter projectDir: The project directory path.
    /// - Returns: True if hooks are found in either project-level or global settings.
    func hasHooksRegistered(forProject projectDir: String) -> Bool {
        let projectSettingsPath = "\(projectDir)/.claude/settings.local.json"
        let globalSettingsPath = globalSettingsFilePath()

        return checkHooksExist(inSettingsAt: projectSettingsPath)
            || checkHooksExist(inSettingsAt: globalSettingsPath)
    }

    // MARK: - Hook Script Installation

    /// Installs the hook script from the app bundle to ~/.claude/hooks/.
    func installHookScript() {
        let targetPath = hookScriptPath
        let targetDir = (targetPath as NSString).deletingLastPathComponent

        // Create hooks directory if needed
        if !fileManager.fileExists(atPath: targetDir) {
            try? fileManager.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
        }

        // Copy from app bundle using temp-then-rename to avoid removing the existing
        // script before the replacement is confirmed written.
        if let bundledScript = Bundle.main.url(forResource: "claude-status-bar", withExtension: "sh") {
            let tempPath = targetPath + ".tmp"
            try? fileManager.removeItem(atPath: tempPath)
            do {
                try fileManager.copyItem(at: bundledScript, to: URL(fileURLWithPath: tempPath))
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempPath)
                // Atomic replace using replaceItemAt (no window where the script is missing)
                if fileManager.fileExists(atPath: targetPath) {
                    _ = try fileManager.replaceItemAt(URL(fileURLWithPath: targetPath), withItemAt: URL(fileURLWithPath: tempPath))
                } else {
                    try fileManager.moveItem(atPath: tempPath, toPath: targetPath)
                }
            } catch {
                Self.logger.warning("Failed to install hook script: \(error.localizedDescription)")
                try? fileManager.removeItem(atPath: tempPath)
            }
        } else {
            // If bundle resource not found (e.g., during development), create it in place
            if !fileManager.fileExists(atPath: targetPath) {
                createFallbackHookScript(at: targetPath)
            }
        }
    }

    // MARK: - Private

    /// Executes a closure while holding an exclusive lock on the given settings file.
    /// Uses directory-based locking (mkdir is atomic) consistent with the shell script.
    /// Writes a PID file inside the lock directory so other processes can check liveness.
    /// Returns nil if the lock cannot be acquired.
    @discardableResult
    private func withSettingsLock<T>(for path: String, body: () -> T) -> T? {
        let lockDir = path + ".lock"
        var acquired = false
        var attempts = 0
        let maxAttempts = 10

        while !acquired && attempts < maxAttempts {
            acquired = mkdir(lockDir, 0o755) == 0
            if !acquired {
                attempts += 1
                usleep(useconds_t(10_000 * (1 << min(attempts, 5)))) // exponential backoff
            }
        }

        if !acquired {
            // Check if the lock holder is still alive before force-removing
            let pidFile = (lockDir as NSString).appendingPathComponent("pid")
            if let pidStr = try? String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               let lockPID = Int32(pidStr) {
                if kill(lockPID, 0) == 0 {
                    // Lock holder is still running — give up
                    return nil
                }
            }
            // Stale lock (holder is dead or no PID file) — remove and retry once
            try? fileManager.removeItem(atPath: lockDir)
            acquired = mkdir(lockDir, 0o755) == 0
        }

        guard acquired else { return nil }

        // Write our PID so other processes can check liveness
        let pidFile = (lockDir as NSString).appendingPathComponent("pid")
        try? "\(ProcessInfo.processInfo.processIdentifier)".write(toFile: pidFile, atomically: false, encoding: .utf8)

        defer { try? fileManager.removeItem(atPath: lockDir) }
        return body()
    }

    private func globalSettingsFilePath() -> String {
        let homeDir = fileManager.homeDirectoryForCurrentUser.path
        return "\(homeDir)/.claude/settings.json"
    }

    /// Merges hook entries into the given settings.json file, preserving existing hooks.
    private func mergeHooks(intoSettingsAt path: String) -> Bool {
        var settings: [String: Any] = [:]

        // Read existing settings
        if let data = fileManager.contents(atPath: path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        }

        // Get or create hooks object
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        let hookCommand = hookScriptPath

        for eventName in Self.monitoredEvents {
            var matcherGroups = hooks[eventName] as? [[String: Any]] ?? []

            // Check if our hook is already registered (new format: matcher+hooks)
            let alreadyRegistered = matcherGroups.contains { group in
                guard let groupHooks = group["hooks"] as? [[String: Any]] else {
                    // Old format entry — check command directly
                    guard let command = group["command"] as? String else { return false }
                    return command.contains(Self.hookMarker)
                }
                return groupHooks.contains { hook in
                    guard let command = hook["command"] as? String else { return false }
                    return command.contains(Self.hookMarker)
                }
            }

            if !alreadyRegistered {
                let matcherGroup: [String: Any] = [
                    "hooks": [
                        [
                            "type": "command",
                            "command": hookCommand
                        ]
                    ]
                ]
                matcherGroups.append(matcherGroup)
            }

            hooks[eventName] = matcherGroups
        }

        settings["hooks"] = hooks

        // Write back atomically
        return writeSettings(settings, toPath: path)
    }

    /// Removes hook entries from the given settings.json file.
    /// Handles both new format (matcher+hooks) and old format (flat command entries).
    private func removeHooks(fromSettingsAt path: String) {
        guard let data = fileManager.contents(atPath: path),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        guard var hooks = settings["hooks"] as? [String: Any] else { return }

        for eventName in Self.monitoredEvents {
            guard var matcherGroups = hooks[eventName] as? [[String: Any]] else { continue }

            matcherGroups.removeAll { group in
                // New format: check hooks array inside matcher group
                if let groupHooks = group["hooks"] as? [[String: Any]] {
                    return groupHooks.contains { hook in
                        guard let command = hook["command"] as? String else { return false }
                        return command.contains(Self.hookMarker)
                    }
                }
                // Old format: check command directly on the entry
                guard let command = group["command"] as? String else { return false }
                return command.contains(Self.hookMarker)
            }

            if matcherGroups.isEmpty {
                hooks.removeValue(forKey: eventName)
            } else {
                hooks[eventName] = matcherGroups
            }
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }

        writeSettings(settings, toPath: path)
    }

    /// Checks if our hooks exist in the given settings file.
    /// Returns true only if ALL monitored events have our hook registered,
    /// to detect partial registration from interrupted writes or manual edits.
    /// Handles both new format (matcher+hooks) and old format (flat command entries).
    private func checkHooksExist(inSettingsAt path: String) -> Bool {
        guard let data = fileManager.contents(atPath: path),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else {
            return false
        }

        return Self.monitoredEvents.allSatisfy { eventName in
            guard let matcherGroups = hooks[eventName] as? [[String: Any]] else { return false }
            return matcherGroups.contains { group in
                // New format: check hooks array inside matcher group
                if let groupHooks = group["hooks"] as? [[String: Any]] {
                    return groupHooks.contains { hook in
                        guard let command = hook["command"] as? String else { return false }
                        return command.contains(Self.hookMarker)
                    }
                }
                // Old format: check command directly on the entry
                guard let command = group["command"] as? String else { return false }
                return command.contains(Self.hookMarker)
            }
        }
    }

    @discardableResult
    private func writeSettings(_ settings: [String: Any], toPath path: String) -> Bool {
        // Ensure directory exists
        let dir = (path as NSString).deletingLastPathComponent
        if !fileManager.fileExists(atPath: dir) {
            try? fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return false
        }

        // Atomic write
        let tempPath = path + ".tmp"
        fileManager.createFile(atPath: tempPath, contents: data)
        do {
            if fileManager.fileExists(atPath: path) {
                _ = try fileManager.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tempPath))
            } else {
                try fileManager.moveItem(atPath: tempPath, toPath: path)
            }
            return true
        } catch {
            try? fileManager.removeItem(atPath: tempPath)
            return false
        }
    }

    /// Creates a minimal fallback hook script when the bundle resource isn't available.
    /// This should rarely be needed — the bundled script is preferred.
    private func createFallbackHookScript(at path: String) {
        // Read the bundled script content as a template.
        // If that fails, write a minimal placeholder that logs an error.
        let script = """
        #!/bin/bash
        # claude-status-bar hook script (fallback)
        # The bundled version was not found. Please reinstall the app.
        echo "claude-status-bar: bundled hook script not found — please reinstall" >&2
        exit 1
        """

        fileManager.createFile(atPath: path, contents: script.data(using: .utf8))
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }
}
