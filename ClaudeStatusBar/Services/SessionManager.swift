import Foundation
import Combine
import UserNotifications

/// Orchestrates Claude Code session tracking. Coordinates between the
/// StateFileWatcher, ProcessDetector, and HookRegistrar to manage up to
/// 5 concurrent sessions.
@MainActor
final class SessionManager: ObservableObject {
    /// Currently tracked sessions, ordered by last_updated (most recent first).
    @Published private(set) var sessions: [Session] = []

    /// Maximum number of tracked sessions.
    static let maxSessions = 5

    /// All detected Claude Code processes (for UI display).
    @Published private(set) var detectedProcesses: [DetectedProcess] = []

    /// Newly detected Claude Code processes that aren't yet tracked (for notification logic).
    @Published private(set) var newProcesses: [DetectedProcess] = []

    /// User-defined custom labels for specific project directories.
    @Published private(set) var customLabels: [String: String] = [:]

    private let stateFileWatcher: StateFileWatcher
    private let processDetector: ProcessDetector
    private let hookRegistrar: HookRegistrar
    private let hookQueue = DispatchQueue(label: "com.samsonong.ClaudeStatusBar.HookRegistrar", qos: .userInitiated)

    private var cancellables = Set<AnyCancellable>()
    private var staleCheckTimer: Timer?
    /// Project directories for which a notification is already pending (user hasn't responded yet).
    private var notifiedProjectDirs: Set<String> = []

    init() {
        self.stateFileWatcher = StateFileWatcher()
        self.processDetector = ProcessDetector()
        self.hookRegistrar = HookRegistrar()
        self.customLabels = UserDefaults.standard.dictionary(forKey: "projectLabels") as? [String: String] ?? [:]

        setupBindings()
        requestNotificationPermission()
    }

    /// Starts all monitoring services.
    func start() {
        // Always install/update the hook script from the app bundle
        hookRegistrar.installHookScript()

        stateFileWatcher.startWatching()
        processDetector.startPolling()
        startStaleChecking()
    }

    /// Stops all monitoring services.
    func stop() {
        stateFileWatcher.stopWatching()
        processDetector.stopPolling()
        staleCheckTimer?.invalidate()
        staleCheckTimer = nil
    }

    /// Registers hooks for a project and starts tracking it.
    /// State changes (acknowledge, markRegistered) are deferred until registration
    /// succeeds, so a failed attempt allows the process to be re-detected and
    /// the user re-prompted on the next poll cycle.
    func registerAndTrack(process: DetectedProcess) {
        let registrar = hookRegistrar
        let projectDir = process.projectDir
        let detector = processDetector
        hookQueue.async { [weak self] in
            let success = registrar.registerHooks(forProject: projectDir)
            DispatchQueue.main.async {
                if success {
                    detector.acknowledge(pid: process.pid)
                    detector.markRegistered(projectDir: projectDir)
                }
                // Remove from notifiedProjectDirs regardless — on success,
                // hooks auto-handle future detections; on failure, the user
                // can be re-prompted.
                self?.notifiedProjectDirs.remove(projectDir)
            }
        }
    }

    /// Dismisses a detected process without registering hooks.
    /// Keeps the project dir in notifiedProjectDirs to prevent re-prompting
    /// while the same process is still running. The entry is cleaned up
    /// naturally when the process exits and knownPIDs is pruned.
    func dismissProcess(_ process: DetectedProcess) {
        processDetector.acknowledge(pid: process.pid)
    }

    /// Clears all sessions from the state file.
    func clearAllSessions() {
        stateFileWatcher.clearAllSessions()
    }

    /// Untracks a session, removing it from the state file and optionally
    /// cleaning up hooks.
    func untrackSession(id: String) {
        if let session = sessions.first(where: { $0.id == id }) {
            let registrar = hookRegistrar
            let projectDir = session.projectDir
            hookQueue.async {
                registrar.removeHooks(forProject: projectDir)
            }
            processDetector.unregisterProjectDir(projectDir)
            notifiedProjectDirs.remove(projectDir)
        }
        stateFileWatcher.removeSession(id: id)
    }

    /// Untracks a detected process that hasn't reported via hooks yet.
    func untrackProcess(projectDir: String) {
        let registrar = hookRegistrar
        hookQueue.async {
            registrar.removeHooks(forProject: projectDir)
        }
        processDetector.unregisterProjectDir(projectDir)
        notifiedProjectDirs.remove(projectDir)
    }

    /// Whether a project directory is tracked (has a session or hooks registered).
    func isTracked(projectDir: String) -> Bool {
        sessions.contains(where: { $0.projectDir == projectDir })
            || processDetector.isRegistered(projectDir: projectDir)
    }

    // MARK: - Labels

    /// Returns the effective label character for a project directory.
    /// Custom label takes priority; otherwise auto-computed from active project names.
    func label(for projectDir: String) -> String {
        if let custom = customLabels[projectDir] {
            return custom
        }
        let allDirs = Array(Set(
            sessions.map(\.projectDir) + detectedProcesses.map(\.projectDir)
        ))
        let auto = Self.computeDistinguishingLabels(for: allDirs)
        return auto[projectDir] ?? String(Self.displayName(for: projectDir).prefix(1)).lowercased()
    }

    /// Sets or clears a custom label for a project directory.
    /// When assigning a label, clears it from any other project (takeover).
    func setCustomLabel(_ label: String?, forProject projectDir: String) {
        if let char = label?.lowercased().first(where: { $0.isLetter || $0.isNumber }) {
            let newLabel = String(char)
            // Clear this label from any other project (takeover)
            for (dir, existing) in customLabels where dir != projectDir && existing == newLabel {
                customLabels.removeValue(forKey: dir)
            }
            customLabels[projectDir] = newLabel
        } else {
            customLabels.removeValue(forKey: projectDir)
        }
        UserDefaults.standard.set(customLabels, forKey: "projectLabels")
    }

    /// Returns the set of custom label characters that are assigned to other
    /// active projects (have a session or detected process). These should be
    /// disabled in the label picker.
    func customLabelsUsedByActiveProjects(excluding projectDir: String) -> Set<String> {
        let activeDirs = Set(sessions.map(\.projectDir) + detectedProcesses.map(\.projectDir))
        var used = Set<String>()
        for (dir, label) in customLabels {
            if dir != projectDir && activeDirs.contains(dir) {
                used.insert(label)
            }
        }
        return used
    }

    /// Maps a label character to its SF Symbol name (e.g. "r" → "r.circle.fill").
    static func sfSymbolName(for label: String) -> String {
        guard let char = label.lowercased().first, char.isLetter || char.isNumber else {
            return "questionmark.circle.fill"
        }
        return "\(char).circle.fill"
    }

    /// Display name from a project directory path (last path component).
    static func displayName(for projectDir: String) -> String {
        if projectDir == "/" || projectDir.isEmpty || projectDir == "Unknown" {
            return "Unknown"
        }
        return (projectDir as NSString).lastPathComponent
    }

    /// Computes a single distinguishing character per project directory.
    ///
    /// Algorithm:
    /// 1. Group display names by first character
    /// 2. Unique first char → use it
    /// 3. Shared first char → find common prefix, use first alphanumeric after it
    /// 4. Name equals the prefix → use its last alphanumeric character
    /// 5. Resolve remaining collisions by numbering
    static func computeDistinguishingLabels(for projectDirs: [String]) -> [String: String] {
        guard !projectDirs.isEmpty else { return [:] }

        let entries: [(dir: String, name: String)] = projectDirs.map { dir in
            (dir, displayName(for: dir).lowercased())
        }

        // Group by first character
        var groups: [Character: [(dir: String, name: String)]] = [:]
        for entry in entries {
            let firstChar = entry.name.first ?? Character("?")
            groups[firstChar, default: []].append(entry)
        }

        var result: [String: String] = [:]

        for (_, group) in groups {
            if group.count == 1 {
                result[group[0].dir] = String(group[0].name.first ?? Character("?"))
            } else {
                // Find longest common prefix within the group
                let names = group.map(\.name)
                let prefix = names.dropFirst().reduce(names[0]) { $0.commonPrefix(with: $1) }

                for entry in group {
                    if entry.name.count <= prefix.count {
                        // Name is the prefix itself — use last alphanumeric char
                        let char = entry.name.last(where: { $0.isLetter || $0.isNumber })
                            ?? entry.name.last ?? Character("?")
                        result[entry.dir] = String(char)
                    } else {
                        // Use first alphanumeric char after the common prefix
                        let idx = entry.name.index(entry.name.startIndex, offsetBy: prefix.count)
                        let suffix = entry.name[idx...]
                        let char = suffix.first(where: { $0.isLetter || $0.isNumber })
                            ?? suffix.first ?? Character("?")
                        result[entry.dir] = String(char)
                    }
                }
            }
        }

        // Resolve collisions by numbering
        var labelToDirs: [String: [String]] = [:]
        for (dir, label) in result {
            labelToDirs[label, default: []].append(dir)
        }
        for (_, dirs) in labelToDirs where dirs.count > 1 {
            for (i, dir) in dirs.sorted().enumerated() {
                result[dir] = "\(i + 1)"
            }
        }

        return result
    }

    // MARK: - Private

    private func setupBindings() {
        // Update sessions whenever state file changes
        stateFileWatcher.$stateFile
            .receive(on: DispatchQueue.main)
            .sink { [weak self] stateFile in
                guard let self else { return }
                self.sessions = Array(stateFile.sessions.values)
                    .sorted { $0.lastUpdated > $1.lastUpdated }

                // Update process detector with tracked project dirs
                self.processDetector.updateFromTrackedSessions(stateFile.sessions)
            }
            .store(in: &cancellables)

        // Forward all detected processes for UI display
        processDetector.$allDetectedProcesses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] processes in
                self?.detectedProcesses = processes
            }
            .store(in: &cancellables)

        // Forward newly detected processes and handle notifications
        processDetector.$newProcesses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] processes in
                guard let self else { return }
                self.newProcesses = processes
                // Prune notifiedProjectDirs: only keep dirs that still have
                // active processes, so dismissed projects can be re-prompted
                // after their Claude process exits and a new one starts.
                let activeProjectDirs = Set(processes.map(\.projectDir))
                self.notifiedProjectDirs = self.notifiedProjectDirs.intersection(activeProjectDirs)
                let candidates = processes.filter { process in
                    self.sessions.count < Self.maxSessions
                        && !self.notifiedProjectDirs.contains(process.projectDir)
                }
                guard !candidates.isEmpty else { return }
                let registrar = self.hookRegistrar
                let detector = self.processDetector
                self.hookQueue.async { [weak self] in
                    // Batch all disk-I/O checks, then dispatch results to main once
                    let results = candidates.map { process in
                        (process, registrar.hasHooksRegistered(forProject: process.projectDir))
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        for (process, alreadyRegistered) in results {
                            if alreadyRegistered {
                                detector.acknowledge(pid: process.pid)
                                detector.markRegistered(projectDir: process.projectDir)
                            } else {
                                guard self.sessions.count < Self.maxSessions,
                                      !self.notifiedProjectDirs.contains(process.projectDir) else { continue }
                                self.notifiedProjectDirs.insert(process.projectDir)
                                self.sendNotification(for: process)
                            }
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func startStaleChecking() {
        staleCheckTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Remove stale idle sessions from the state file so they don't
                // permanently occupy slots toward the max 5 limit.
                // Only auto-remove idle sessions — running/pending sessions may
                // be in a long tool execution without hook events, and completed
                // sessions are intentionally preserved to surface finished output.
                let staleIDs = self.sessions
                    .filter { $0.isStale && $0.status == .idle }
                    .map(\.id)
                for id in staleIDs {
                    self.stateFileWatcher.removeSession(id: id)
                }
            }
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendNotification(for process: DetectedProcess) {
        let content = UNMutableNotificationContent()
        content.title = "Claude Code Detected"
        let projectName = (process.projectDir as NSString).lastPathComponent
        content.body = "Register hooks for \(projectName) to track session status?"
        content.categoryIdentifier = "HOOK_REGISTRATION"
        content.userInfo = [
            "pid": process.pid,
            "projectDir": process.projectDir
        ]

        let request = UNNotificationRequest(
            identifier: "claude-detect-\(process.pid)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}
