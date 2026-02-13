import Foundation
import Combine
import os

/// Watches the state file at ~/.claude/claude-status-bar.json for changes
/// using a DispatchSource file descriptor monitor. Publishes the parsed
/// StateFile whenever the file is modified.
@MainActor
final class StateFileWatcher: ObservableObject {
    @Published private(set) var stateFile: StateFile = StateFile()

    nonisolated private static let logger = Logger(subsystem: "com.samsonong.ClaudeStatusBar", category: "StateFileWatcher")
    private let stateFilePath: String
    private var fileDescriptor: Int32 = -1
    private var dispatchSource: DispatchSourceFileSystemObject?
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.samsonong.ClaudeStatusBar.StateFileWatcher", qos: .userInitiated)

    /// Generation counter incremented on every main-actor mutation (removeSession/clearAllSessions).
    /// Used to detect stale async dispatches from background reads.
    /// No lock needed — @MainActor guarantees serial access.
    private var stateGeneration: UInt64 = 0

    /// Counter tracking how many local writes are currently in-flight on the background queue.
    /// When > 0, DispatchSource-triggered reads are suppressed to prevent our own disk writes
    /// from overwriting in-memory state with stale data.
    private var localWriteInFlight: Int = 0

    init() {
        let homeDir = fileManager.homeDirectoryForCurrentUser.path
        stateFilePath = "\(homeDir)/.claude/claude-status-bar.json"
    }

    /// Note: `deinit` is nonisolated in Swift, but `dispatchSource` and `fileDescriptor`
    /// are main-actor-isolated. In practice this object lives for the app's lifetime and
    /// `stop()` is called before termination. `DispatchSource.cancel()` is thread-safe,
    /// so we just cancel the source here as a safety net.
    deinit {
        dispatchSource?.cancel()
    }

    /// Starts monitoring the state file for changes.
    func startWatching() {
        // Guard against double-start: if already watching, stop first
        if dispatchSource != nil {
            stopWatching()
        }

        // Ensure the directory exists
        let directoryPath = (stateFilePath as NSString).deletingLastPathComponent
        if !fileManager.fileExists(atPath: directoryPath) {
            try? fileManager.createDirectory(atPath: directoryPath, withIntermediateDirectories: true)
        }

        // Create the file if it doesn't exist
        if !fileManager.fileExists(atPath: stateFilePath) {
            let emptyState = StateFile()
            localWriteInFlight += 1
            queue.async { [weak self] in
                self?.writeStateFile(emptyState)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.localWriteInFlight -= 1
                }
            }
        }

        // Do initial read
        triggerRead()

        // Open the file for monitoring
        openAndMonitor()
    }

    /// Stops monitoring the state file.
    func stopWatching() {
        if let source = dispatchSource {
            source.cancel() // cancel handler closes the fd
            dispatchSource = nil
        } else if fileDescriptor >= 0 {
            // No dispatch source but fd is open (edge case) — close directly
            close(fileDescriptor)
        }
        fileDescriptor = -1
    }

    /// Removes a session from the state file and writes it back.
    func removeSession(id: String) {
        stateGeneration &+= 1
        var state = stateFile
        state.sessions.removeValue(forKey: id)
        stateFile = state
        // Write to disk on background queue to avoid blocking main actor.
        // Suppress DispatchSource-triggered reads until write completes.
        localWriteInFlight += 1
        queue.async { [weak self] in
            self?.writeStateFile(state)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.localWriteInFlight -= 1
            }
        }
    }

    /// Clears all sessions from the state file.
    func clearAllSessions() {
        stateGeneration &+= 1
        let emptyState = StateFile()
        stateFile = emptyState
        // Write to disk on background queue to avoid blocking main actor.
        // Suppress DispatchSource-triggered reads until write completes.
        localWriteInFlight += 1
        queue.async { [weak self] in
            self?.writeStateFile(emptyState)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.localWriteInFlight -= 1
            }
        }
    }

    // MARK: - Private

    /// Maximum number of retries when the state file does not yet exist.
    private static let maxOpenRetries = 30

    /// Dispatches a file read to the background queue, then updates stateFile on main actor.
    /// Skipped when a local write is in-flight to prevent our own disk writes from
    /// overwriting newer in-memory state with stale data.
    private func triggerRead() {
        guard localWriteInFlight == 0 else { return }
        let capturedGeneration = stateGeneration
        let path = stateFilePath
        queue.async { [weak self] in
            let result = StateFileWatcher.readAndParse(at: path)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.stateGeneration == capturedGeneration else { return }
                switch result {
                case .parsed(let state):
                    self.stateFile = state
                case .corrupted:
                    Self.logger.warning("State file corrupted, recreating empty state")
                    self.stateGeneration &+= 1
                    let emptyState = StateFile()
                    self.stateFile = emptyState
                    self.localWriteInFlight += 1
                    self.queue.async { [weak self] in
                        self?.writeStateFile(emptyState)
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.localWriteInFlight -= 1
                        }
                    }
                case .missing:
                    self.stateFile = StateFile()
                }
            }
        }
    }

    private enum ReadResult: Sendable {
        case parsed(StateFile)
        case corrupted
        case missing
    }

    nonisolated private static func readAndParse(at path: String) -> ReadResult {
        guard let data = FileManager.default.contents(atPath: path) else {
            return .missing
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return .parsed(try decoder.decode(StateFile.self, from: data))
        } catch {
            return .corrupted
        }
    }

    private func openAndMonitor(retryCount: Int = 0) {
        // Close existing if any
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }

        let fd = open(stateFilePath, O_EVTONLY)
        guard fd >= 0 else {
            // File doesn't exist yet; retry after a delay (up to maxOpenRetries)
            guard retryCount < Self.maxOpenRetries else { return }
            queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    self?.openAndMonitor(retryCount: retryCount + 1)
                }
            }
            return
        }

        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // File was deleted or renamed (atomic write pattern).
                // Cancel this source (cancel handler closes the fd), then re-open.
                source.cancel()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.dispatchSource = nil
                    self.fileDescriptor = -1
                    // Small delay to allow the new file to appear
                    self.queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        DispatchQueue.main.async { [weak self] in
                            self?.triggerRead()
                            self?.openAndMonitor()
                        }
                    }
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.triggerRead()
                }
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        dispatchSource = source
        source.resume()
    }

    nonisolated private func writeStateFile(_ state: StateFile) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(state) else { return }

        let fm = FileManager.default

        // Acquire the same mkdir-based lock used by the shell script
        let lockDir = stateFilePath + ".lock"
        guard acquireLock(at: lockDir) else {
            Self.logger.warning("Failed to acquire lock for state file write")
            return
        }
        defer { releaseLock(at: lockDir) }

        // Atomic write: write to temp file then rename
        let tempPath = stateFilePath + ".tmp"
        fm.createFile(atPath: tempPath, contents: data)
        do {
            if fm.fileExists(atPath: stateFilePath) {
                _ = try fm.replaceItemAt(URL(fileURLWithPath: stateFilePath), withItemAt: URL(fileURLWithPath: tempPath))
            } else {
                try fm.moveItem(atPath: tempPath, toPath: stateFilePath)
            }
        } catch {
            Self.logger.warning("replaceItemAt failed, using fallback: \(error.localizedDescription)")
            // Write directly as last resort — don't remove existing file first
            // to avoid a window where the state file is missing.
            try? data.write(to: URL(fileURLWithPath: stateFilePath))
            try? fm.removeItem(atPath: tempPath)
        }
    }

    /// Acquires a directory-based lock consistent with the shell script's locking scheme.
    /// Writes a PID file inside the lock directory so other processes can check liveness.
    nonisolated private func acquireLock(at lockDir: String) -> Bool {
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
                    return false
                }
            }
            // Stale lock (holder is dead or no PID file) — remove and retry once
            try? FileManager.default.removeItem(atPath: lockDir)
            acquired = mkdir(lockDir, 0o755) == 0
        }

        if acquired {
            // Write our PID so other processes can check liveness
            let pidFile = (lockDir as NSString).appendingPathComponent("pid")
            try? "\(ProcessInfo.processInfo.processIdentifier)".write(toFile: pidFile, atomically: false, encoding: .utf8)
        }

        return acquired
    }

    /// Releases the directory-based lock by removing the lock directory.
    nonisolated private func releaseLock(at lockDir: String) {
        try? FileManager.default.removeItem(atPath: lockDir)
    }
}
