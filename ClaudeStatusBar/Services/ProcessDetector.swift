import Foundation
import Combine

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
    /// Newly detected Claude Code processes that aren't yet tracked.
    @Published private(set) var newProcesses: [DetectedProcess] = []

    /// PIDs that have already been seen (prompted or tracked).
    private var knownPIDs: Set<Int32> = []

    /// Project directories that already have hooks registered.
    private var registeredProjectDirs: Set<String> = []

    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 5.0
    private let pollQueue = DispatchQueue(label: "com.samsonong.ClaudeStatusBar.ProcessDetector", qos: .utility)

    func startPolling() {
        let queue = pollQueue

        // Initial poll — call the static helper directly to avoid crossing
        // @MainActor isolation through `self` on the background queue.
        queue.async { [weak self] in
            let processes = ProcessDetector.findClaudeProcesses()
            DispatchQueue.main.async {
                self?.applyPollResults(processes)
            }
        }

        // Schedule recurring polls — capture pollQueue locally to avoid
        // accessing @MainActor-isolated self from the Timer's @Sendable closure.
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            queue.async {
                let processes = ProcessDetector.findClaudeProcesses()
                DispatchQueue.main.async {
                    self?.applyPollResults(processes)
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

        // Clean up knownPIDs for processes that no longer exist
        let activePIDs = Set(processes.map(\.pid))
        knownPIDs = knownPIDs.intersection(activePIDs)

        newProcesses = result
    }

    private static func findClaudeProcesses() -> [DetectedProcess] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-eo", "pid,command"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
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

            // Match lines containing "claude" that look like a Claude Code process.
            // Claude Code runs as a Node.js process; the command typically contains
            // the path to the claude CLI binary.
            // We look for processes whose command contains "/claude" (the CLI binary path)
            // but exclude this app's own process and common false positives.
            guard trimmed.contains("/claude") || trimmed.hasSuffix(" claude") else { continue }
            // Exclude our own app
            guard !trimmed.contains("ClaudeStatusBar") else { continue }
            // Exclude grep/ps artifacts
            guard !trimmed.contains("grep") && !trimmed.contains("/bin/ps") else { continue }

            let components = trimmed.split(separator: " ", maxSplits: 1)
            guard components.count == 2,
                  let pid = Int32(components[0]) else { continue }

            // Try to determine the working directory via lsof
            let projectDir = getWorkingDirectory(pid: pid) ?? "Unknown"
            results.append(DetectedProcess(pid: pid, projectDir: projectDir))
        }

        return results
    }

    private static func getWorkingDirectory(pid: Int32) -> String? {
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
}
