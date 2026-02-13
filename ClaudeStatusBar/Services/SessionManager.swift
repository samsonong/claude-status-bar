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

    /// Newly detected Claude Code processes that aren't yet tracked.
    @Published private(set) var newProcesses: [DetectedProcess] = []

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

        setupBindings()
        requestNotificationPermission()
    }

    /// Starts all monitoring services.
    func start() {
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
    /// If hook registration fails, reverts the registration state so the user
    /// can retry when the process is next detected.
    func registerAndTrack(process: DetectedProcess) {
        let registrar = hookRegistrar
        let projectDir = process.projectDir
        let detector = processDetector
        hookQueue.async { [weak self] in
            let success = registrar.registerHooks(forProject: projectDir)
            if !success {
                DispatchQueue.main.async {
                    detector.unregisterProjectDir(projectDir)
                    self?.notifiedProjectDirs.remove(projectDir)
                }
            }
        }
        processDetector.acknowledge(pid: process.pid)
        processDetector.markRegistered(projectDir: process.projectDir)
        notifiedProjectDirs.remove(process.projectDir)
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
        }
        stateFileWatcher.removeSession(id: id)
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

        // Forward newly detected processes and handle them
        processDetector.$newProcesses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] processes in
                guard let self else { return }
                self.newProcesses = processes
                let candidates = processes.filter { process in
                    self.sessions.count < Self.maxSessions
                        && !self.notifiedProjectDirs.contains(process.projectDir)
                }
                guard !candidates.isEmpty else { return }
                let registrar = self.hookRegistrar
                let detector = self.processDetector
                self.hookQueue.async { [weak self] in
                    for process in candidates {
                        // Don't prompt if hooks are already registered
                        if registrar.hasHooksRegistered(forProject: process.projectDir) {
                            DispatchQueue.main.async {
                                detector.acknowledge(pid: process.pid)
                                detector.markRegistered(projectDir: process.projectDir)
                            }
                            continue
                        }

                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            // Re-check after async hop to avoid races
                            guard self.sessions.count < Self.maxSessions,
                                  !self.notifiedProjectDirs.contains(process.projectDir) else { return }
                            self.notifiedProjectDirs.insert(process.projectDir)
                            self.sendNotification(for: process)
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
                // be in a long tool execution without hook events.
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
