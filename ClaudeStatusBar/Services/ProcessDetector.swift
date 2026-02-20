import Foundation
import Combine
import os
import Darwin.C

/// Represents a detected Claude Code process.
struct DetectedProcess: Equatable, Sendable {
    let pid: Int32
    let projectDir: String
}

/// Polls the system for running `claude` processes to detect new Claude Code instances.
/// When a new process is found that isn't already tracked, it publishes a notification
/// so the app can prompt the user to register hooks.
@MainActor
final class ProcessDetector: ObservableObject {
    nonisolated private static let logger = Logger(subsystem: "com.samsonong.ClaudeStatusBar", category: "ProcessDetector")

    /// Newly detected Claude Code processes that aren't yet tracked (for notification logic).
    @Published private(set) var newProcesses: [DetectedProcess] = []

    /// All detected Claude Code processes (unfiltered, for UI display).
    @Published private(set) var allDetectedProcesses: [DetectedProcess] = []

    /// PIDs that have already been seen (prompted or tracked).
    private var knownPIDs: Set<Int32> = []

    /// Project directories that already have hooks registered.
    private var registeredProjectDirs: Set<String> = []

    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 5.0
    private let pollQueue = DispatchQueue(label: "com.samsonong.ClaudeStatusBar.ProcessDetector", qos: .utility)

    /// Cache of PID -> working directory to avoid spawning lsof on every poll.
    /// Cleaned when PIDs disappear from poll results.
    private var cwdCache: [Int32: String] = [:]

    func startPolling() {
        let queue = pollQueue

        // Initial poll — call the static helper directly to avoid crossing
        // @MainActor isolation through `self` on the background queue.
        let cache = cwdCache
        queue.async { [weak self] in
            let processes = ProcessDetector.findClaudeProcesses(cwdCache: cache)
            DispatchQueue.main.async {
                self?.applyPollResults(processes)
            }
        }

        // Schedule recurring polls — capture pollQueue locally to avoid
        // accessing @MainActor-isolated self from the Timer's @Sendable closure.
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            // Capture the cache snapshot on the main thread before dispatching to background
            DispatchQueue.main.async { [weak self] in
                let currentCache = self?.cwdCache ?? [:]
                queue.async {
                    let processes = ProcessDetector.findClaudeProcesses(cwdCache: currentCache)
                    DispatchQueue.main.async {
                        self?.applyPollResults(processes)
                    }
                }
            }
        }
        // Add to .common mode so the timer fires during menu tracking
        RunLoop.current.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Marks a PID as known so it won't be reported again.
    func acknowledge(pid: Int32) {
        knownPIDs.insert(pid)
        newProcesses.removeAll { $0.pid == pid }
    }

    /// Reverts a previous acknowledge so the PID can be re-detected.
    /// Used when hook registration fails and the user should be re-prompted.
    func unacknowledge(pid: Int32) {
        knownPIDs.remove(pid)
    }

    /// Marks a project directory as having hooks registered.
    func markRegistered(projectDir: String) {
        registeredProjectDirs.insert(projectDir)
    }

    /// Removes a project directory from the registered set so it can be re-detected.
    func unregisterProjectDir(_ projectDir: String) {
        registeredProjectDirs.remove(projectDir)
    }

    /// Checks whether a project directory has hooks registered.
    func isRegistered(projectDir: String) -> Bool {
        registeredProjectDirs.contains(projectDir)
    }

    /// Updates known PIDs from currently tracked sessions.
    func updateFromTrackedSessions(_ sessions: [String: Session]) {
        for session in sessions.values {
            registeredProjectDirs.insert(session.projectDir)
        }
    }

    // MARK: - Private

    /// Filters and publishes poll results. Must run on main actor.
    private func applyPollResults(_ processes: [DetectedProcess]) {
        // Publish all detected processes for UI consumption
        allDetectedProcesses = processes

        // Filter for notification candidates (not known, not registered)
        var result: [DetectedProcess] = []
        for process in processes {
            if !knownPIDs.contains(process.pid) && !registeredProjectDirs.contains(process.projectDir) {
                result.append(process)
            }
        }

        // Clean up knownPIDs and cwd cache for processes that no longer exist
        let activePIDs = Set(processes.map(\.pid))
        knownPIDs = knownPIDs.intersection(activePIDs)
        cwdCache = cwdCache.filter { activePIDs.contains($0.key) }

        // Update cache with newly resolved directories
        for process in processes {
            cwdCache[process.pid] = process.projectDir
        }

        newProcesses = result
    }

    /// Uses libproc to enumerate all PIDs and find Claude Code processes by executable path.
    /// No subprocesses are spawned — reads kernel data directly.
    nonisolated private static func findClaudeProcesses(cwdCache: [Int32: String]) -> [DetectedProcess] {
        // Query the number of active PIDs, then allocate 2x to handle churn
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { return [] }
        let bufferSize = Int(estimatedCount) * 2
        var pids = [pid_t](repeating: 0, count: bufferSize)

        let byteCount = proc_listallpids(&pids, Int32(bufferSize * MemoryLayout<pid_t>.size))
        guard byteCount > 0 else { return [] }
        let pidCount = Int(byteCount)

        // Reuse a single path buffer across the loop
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var results: [DetectedProcess] = []

        for i in 0..<pidCount {
            let pid = pids[i]
            guard pid > 0 else { continue }

            let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(MAXPATHLEN))
            guard pathLen > 0 else { continue }

            let path = String(cString: pathBuffer)

            // Match Claude CLI: binary named "claude" or inside the Claude versions directory
            let lastComponent = (path as NSString).lastPathComponent
            guard lastComponent == "claude" || path.contains("/.local/share/claude/versions/") else { continue }

            // Exclude our own app and Claude Desktop
            guard !path.contains("ClaudeStatusBar")
                    && !path.contains("Claude Desktop")
                    && !path.contains("Claude.app") else { continue }

            let projectDir = cwdCache[pid] ?? getWorkingDirectory(pid: pid) ?? "Unknown"
            results.append(DetectedProcess(pid: pid, projectDir: projectDir))
        }

        return results
    }

    /// Uses proc_pidinfo with PROC_PIDVNODEPATHINFO to get the working directory.
    /// No subprocesses are spawned.
    nonisolated private static func getWorkingDirectory(pid: Int32) -> String? {
        var vnodeInfo = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, Int32(size))
        guard result == size else { return nil }

        return withUnsafePointer(to: vnodeInfo.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cStr in
                String(cString: cStr)
            }
        }
    }
}
