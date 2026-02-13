import Foundation
import Combine

/// Watches the state file at ~/.claude/claude-status-bar.json for changes
/// using a DispatchSource file descriptor monitor. Publishes the parsed
/// StateFile whenever the file is modified.
final class StateFileWatcher: ObservableObject {
    @Published private(set) var stateFile: StateFile = StateFile()

    private let stateFilePath: String
    private var fileDescriptor: Int32 = -1
    private var dispatchSource: DispatchSourceFileSystemObject?
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.samsonong.ClaudeStatusBar.StateFileWatcher", qos: .userInitiated)

    /// Generation counter incremented on every main-thread mutation (removeSession/clearAllSessions).
    /// Used to detect stale async dispatches from readStateFile().
    /// Protected by generationLock for cross-queue access.
    private var stateGeneration: UInt64 = 0
    private let generationLock = NSLock()

    init() {
        let homeDir = fileManager.homeDirectoryForCurrentUser.path
        stateFilePath = "\(homeDir)/.claude/claude-status-bar.json"
    }

    deinit {
        stopWatching()
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
            writeStateFile(emptyState)
        }

        // Do initial read
        readStateFile()

        // Open the file for monitoring
        openAndMonitor()
    }

    /// Stops monitoring the state file.
    func stopWatching() {
        dispatchSource?.cancel()
        dispatchSource = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    /// Removes a session from the state file and writes it back.
    /// Must be called on the main thread.
    func removeSession(id: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        generationLock.lock()
        stateGeneration &+= 1
        generationLock.unlock()
        var state = stateFile
        state.sessions.removeValue(forKey: id)
        writeStateFile(state)
        stateFile = state
    }

    /// Clears all sessions from the state file.
    /// Must be called on the main thread.
    func clearAllSessions() {
        dispatchPrecondition(condition: .onQueue(.main))
        generationLock.lock()
        stateGeneration &+= 1
        generationLock.unlock()
        let emptyState = StateFile()
        writeStateFile(emptyState)
        stateFile = emptyState
    }

    // MARK: - Private

    /// Maximum number of retries when the state file does not yet exist.
    private static let maxOpenRetries = 30

    private func openAndMonitor(retryCount: Int = 0) {
        // Close existing if any
        if fileDescriptor >= 0 {
            close(fileDescriptor)
        }

        fileDescriptor = open(stateFilePath, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            // File doesn't exist yet; retry after a delay (up to maxOpenRetries)
            guard retryCount < Self.maxOpenRetries else { return }
            queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.openAndMonitor(retryCount: retryCount + 1)
            }
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // File was deleted or renamed (atomic write pattern).
                // Re-open and re-monitor.
                self.dispatchSource?.cancel()
                close(self.fileDescriptor)
                self.fileDescriptor = -1
                // Small delay to allow the new file to appear
                self.queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.readStateFile()
                    self?.openAndMonitor()
                }
            } else {
                self.readStateFile()
            }
        }

        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }

        dispatchSource = source
        source.resume()
    }

    private func readStateFile() {
        // Capture the generation before reading so we can detect stale dispatches.
        // If removeSession/clearAllSessions runs between the file read and the
        // main-queue dispatch, the generation will have changed and we skip the
        // stale update.
        generationLock.lock()
        let capturedGeneration = stateGeneration
        generationLock.unlock()

        guard let data = fileManager.contents(atPath: stateFilePath) else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.generationLock.lock()
                let current = self.stateGeneration
                self.generationLock.unlock()
                guard current == capturedGeneration else { return }
                self.stateFile = StateFile()
            }
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let state = try decoder.decode(StateFile.self, from: data)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.generationLock.lock()
                let current = self.stateGeneration
                self.generationLock.unlock()
                guard current == capturedGeneration else { return }
                self.stateFile = state
            }
        } catch {
            // JSON corrupted — recreate with empty state
            let emptyState = StateFile()
            writeStateFile(emptyState)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.generationLock.lock()
                let current = self.stateGeneration
                self.generationLock.unlock()
                guard current == capturedGeneration else { return }
                self.stateFile = emptyState
            }
        }
    }

    private func writeStateFile(_ state: StateFile) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(state) else { return }

        // Acquire the same mkdir-based lock used by the shell script
        let lockDir = stateFilePath + ".lock"
        guard acquireLock(at: lockDir) else { return }
        defer { releaseLock(at: lockDir) }

        // Atomic write: write to temp file then rename
        let tempPath = stateFilePath + ".tmp"
        fileManager.createFile(atPath: tempPath, contents: data)
        do {
            if fileManager.fileExists(atPath: stateFilePath) {
                _ = try fileManager.replaceItemAt(URL(fileURLWithPath: stateFilePath), withItemAt: URL(fileURLWithPath: tempPath))
            } else {
                try fileManager.moveItem(atPath: tempPath, toPath: stateFilePath)
            }
        } catch {
            // Fallback: remove existing and move temp into place
            try? fileManager.removeItem(atPath: stateFilePath)
            try? fileManager.moveItem(atPath: tempPath, toPath: stateFilePath)
        }
    }

    /// Acquires a directory-based lock consistent with the shell script's locking scheme.
    /// Writes a PID file inside the lock directory so other processes can check liveness.
    private func acquireLock(at lockDir: String) -> Bool {
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
            try? fileManager.removeItem(atPath: lockDir)
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
    private func releaseLock(at lockDir: String) {
        try? fileManager.removeItem(atPath: lockDir)
    }
}
