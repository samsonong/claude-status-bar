import Foundation
import Combine
import os

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

    /// Newly detected Claude Code processes that aren't yet tracked.
    @Published private(set) var newProcesses: [DetectedProcess] = []

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
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
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

    /// Updates known PIDs from currently tracked sessions.
    func updateFromTrackedSessions(_ sessions: [String: Session]) {
        for session in sessions.values {
            registeredProjectDirs.insert(session.projectDir)
        }
    }

    // MARK: - Private

    /// Filters and publishes poll results. Must run on main actor.
    private func applyPollResults(_ processes: [DetectedProcess]) {
        var result: [DetectedProcess] = []
        for process in processes {
            if !knownPIDs.contains(process.pid) && !registeredProjectDirs.contains(process.projectDir) {
                result.append(process)
                // Don't add to knownPIDs yet — wait for user acknowledgment
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

    nonisolated private static func findClaudeProcesses(cwdCache: [Int32: String]) -> [DetectedProcess] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-eo", "pid,command"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            logger.warning("Failed to run ps: \(error.localizedDescription)")
            return []
        }

        // Read pipe data BEFORE waitUntilExit to avoid deadlock when output
        // exceeds the pipe buffer size.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var results: [DetectedProcess] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let components = trimmed.split(separator: " ", maxSplits: 1)
            guard components.count == 2,
                  let pid = Int32(components[0]) else { continue }

            // Match lines containing the Claude CLI binary specifically.
            // Claude Code runs as a Node.js process; the command typically looks like:
            //   /path/to/node /path/to/claude --args
            //   claude --args
            // We use a regex to match the binary name "claude" as a whole word (not as a
            // substring of "claude-desktop", "ClaudeStatusBar", etc.).
            let command = String(components[1])
            guard command.range(of: #"(?:^|/)claude(?:\s|$)"#, options: .regularExpression) != nil else { continue }
            // Exclude our own app, grep/ps artifacts, and Claude Desktop
            guard !command.contains("ClaudeStatusBar")
                    && !command.contains("Claude Desktop")
                    && !command.contains("grep")
                    && !command.contains("/bin/ps") else { continue }

            // Use cached working directory if available, otherwise call lsof
            let projectDir = cwdCache[pid] ?? getWorkingDirectory(pid: pid) ?? "Unknown"
            results.append(DetectedProcess(pid: pid, projectDir: projectDir))
        }

        return results
    }

    /// Resolves the working directory for a PID using `lsof`.
    nonisolated private static func resolveWorkingDirectory(pid: Int32) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-p", "\(pid)", "-Fn", "-d", "cwd"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            return nil
        }

        // Read pipe data BEFORE waitUntilExit to avoid deadlock when output
        // exceeds the pipe buffer size.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        // lsof output format: lines starting with 'n' contain the path
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("n") && !line.hasPrefix("n->") {
                return String(line.dropFirst())
            }
        }

        return nil
    }

    /// Returns the parent PID for a given process, or `nil` on failure.
    nonisolated private static func getParentPID(pid: Int32) -> Int32? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "ppid=", "-p", "\(pid)"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        return Int32(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Gets the working directory for a PID, falling back to the parent process's
    /// cwd when the result is "/" (common for Node.js Claude Code processes).
    nonisolated private static func getWorkingDirectory(pid: Int32) -> String? {
        guard let dir = resolveWorkingDirectory(pid: pid) else { return nil }

        if dir == "/", let ppid = getParentPID(pid: pid), ppid > 1 {
            return resolveWorkingDirectory(pid: ppid) ?? dir
        }

        return dir
    }
}
