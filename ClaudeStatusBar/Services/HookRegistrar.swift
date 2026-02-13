import Foundation

/// Manages registration and removal of Claude Code hooks in settings.json files.
/// Hooks are entries in the `hooks` object of either `~/.claude/settings.json` (global)
/// or `<project>/.claude/settings.local.json` (project-level).
///
/// The registrar merges hook entries without overwriting existing hooks for
/// the same event names — it appends to the existing arrays.
final class HookRegistrar {
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

    /// Path to the bundled hook script, or the installed path.
    private var hookScriptPath: String {
        let homeDir = fileManager.homeDirectoryForCurrentUser.path
        return "\(homeDir)/.claude/hooks/claude-status-bar.sh"
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
        if fileManager.fileExists(atPath: "\(projectDir)/.claude") {
            settingsPath = projectSettingsPath
        } else {
            settingsPath = globalSettingsPath
        }

        return withSettingsLock(for: settingsPath) {
            mergeHooks(intoSettingsAt: settingsPath)
        }
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

        // Copy from app bundle
        if let bundledScript = Bundle.main.url(forResource: "claude-status-bar", withExtension: "sh") {
            try? fileManager.removeItem(atPath: targetPath)
            try? fileManager.copyItem(at: bundledScript, to: URL(fileURLWithPath: targetPath))
            // Make executable
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetPath)
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
    private func withSettingsLock<T>(for path: String, body: () -> T) -> T {
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
            // Force-remove potentially stale lock and retry once
            try? fileManager.removeItem(atPath: lockDir)
            _ = mkdir(lockDir, 0o755)
        }

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
            var eventHooks = hooks[eventName] as? [[String: Any]] ?? []

            // Check if our hook is already registered
            let alreadyRegistered = eventHooks.contains { entry in
                guard let command = entry["command"] as? String else { return false }
                return command.contains(Self.hookMarker)
            }

            if !alreadyRegistered {
                let hookEntry: [String: Any] = [
                    "type": "command",
                    "command": hookCommand
                ]
                eventHooks.append(hookEntry)
            }

            hooks[eventName] = eventHooks
        }

        settings["hooks"] = hooks

        // Write back atomically
        return writeSettings(settings, toPath: path)
    }

    /// Removes hook entries from the given settings.json file.
    private func removeHooks(fromSettingsAt path: String) {
        guard let data = fileManager.contents(atPath: path),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        guard var hooks = settings["hooks"] as? [String: Any] else { return }

        for eventName in Self.monitoredEvents {
            guard var eventHooks = hooks[eventName] as? [[String: Any]] else { continue }

            eventHooks.removeAll { entry in
                guard let command = entry["command"] as? String else { return false }
                return command.contains(Self.hookMarker)
            }

            if eventHooks.isEmpty {
                hooks.removeValue(forKey: eventName)
            } else {
                hooks[eventName] = eventHooks
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
    private func checkHooksExist(inSettingsAt path: String) -> Bool {
        guard let data = fileManager.contents(atPath: path),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else {
            return false
        }

        // Check if at least one of our events has our hook
        for eventName in Self.monitoredEvents {
            guard let eventHooks = hooks[eventName] as? [[String: Any]] else { continue }
            let hasOurHook = eventHooks.contains { entry in
                guard let command = entry["command"] as? String else { return false }
                return command.contains(Self.hookMarker)
            }
            if hasOurHook { return true }
        }

        return false
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
        echo "claude-status-bar: bundled hook script not found" >&2
        exit 0
        """

        fileManager.createFile(atPath: path, contents: script.data(using: .utf8))
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }
}
