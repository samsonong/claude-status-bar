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
    func removeSession(id: String) {
        var state = stateFile
        state.sessions.removeValue(forKey: id)
        writeStateFile(state)
        DispatchQueue.main.async {
            self.stateFile = state
        }
    }

    /// Clears all sessions from the state file.
    func clearAllSessions() {
        let emptyState = StateFile()
        writeStateFile(emptyState)
        DispatchQueue.main.async {
            self.stateFile = emptyState
        }
    }

    // MARK: - Private

    private func openAndMonitor() {
        // Close existing if any
        if fileDescriptor >= 0 {
            close(fileDescriptor)
        }

        fileDescriptor = open(stateFilePath, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            // File doesn't exist yet; retry after a delay
            queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.openAndMonitor()
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
        guard let data = fileManager.contents(atPath: stateFilePath) else {
            DispatchQueue.main.async {
                self.stateFile = StateFile()
            }
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let state = try decoder.decode(StateFile.self, from: data)
            DispatchQueue.main.async {
                self.stateFile = state
            }
        } catch {
            // JSON corrupted — recreate with empty state
            let emptyState = StateFile()
            writeStateFile(emptyState)
            DispatchQueue.main.async {
                self.stateFile = emptyState
            }
        }
    }

    private func writeStateFile(_ state: StateFile) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(state) else { return }

        // Atomic write: write to temp file then rename
        let tempPath = stateFilePath + ".tmp"
        fileManager.createFile(atPath: tempPath, contents: data)
        try? fileManager.replaceItemAt(URL(fileURLWithPath: stateFilePath), withItemAt: URL(fileURLWithPath: tempPath))
    }
}
