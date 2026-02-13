import SwiftUI
import ServiceManagement

/// The dropdown menu content shown when the user clicks the status dots.
/// Displays each tracked session with its project name, status, and an
/// option to untrack it. Also includes a Launch at Login toggle and Quit button.
struct SessionMenuView: View {
    @ObservedObject var sessionManager: SessionManager
    @State private var launchAtLogin: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if sessionManager.sessions.isEmpty {
                Text("No active sessions")
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ForEach(sessionManager.sessions.prefix(SessionManager.maxSessions)) { session in
                    sessionRow(session)
                    Divider()
                }
            }

            // New process notifications
            if !sessionManager.processDetector.newProcesses.isEmpty {
                Divider()
                ForEach(sessionManager.processDetector.newProcesses, id: \.pid) { process in
                    newProcessRow(process)
                }
            }

            Divider()

            // Launch at Login toggle
            Toggle("Launch at Login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .onChange(of: launchAtLogin) { newValue in
                    setLaunchAtLogin(newValue)
                }

            Divider()

            // Quit button
            Button("Quit Claude Status Bar") {
                sessionManager.stop()
                sessionManager.stateFileWatcher.clearAllSessions()
                NSApplication.shared.terminate(nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 260)
        .onAppear {
            launchAtLogin = isLaunchAtLoginEnabled()
        }
    }

    // MARK: - Session Row

    @ViewBuilder
    private func sessionRow(_ session: Session) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(dotColor(for: session))
                        .frame(width: 8, height: 8)

                    Text(session.projectName)
                        .font(.system(size: 13, weight: .medium))

                    if session.isStale {
                        Text("stale")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(3)
                    }
                }

                Text(session.status.label)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Text(session.projectDir)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button("Untrack") {
                sessionManager.untrackSession(id: session.id)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .foregroundColor(.red)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - New Process Row

    @ViewBuilder
    private func newProcessRow(_ process: DetectedProcess) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("New: \((process.projectDir as NSString).lastPathComponent)")
                    .font(.system(size: 13, weight: .medium))
                Text(process.projectDir)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button("Track") {
                sessionManager.registerAndTrack(process: process)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button("Dismiss") {
                sessionManager.dismissProcess(process)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

    private func dotColor(for session: Session) -> Color {
        let baseColor: Color
        switch session.status {
        case .idle: baseColor = .green
        case .pending: baseColor = .yellow
        case .running: baseColor = .blue
        }
        return session.isStale ? baseColor.opacity(0.4) : baseColor
    }

    private func isLaunchAtLoginEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert the toggle on failure
            launchAtLogin = !enabled
        }
    }
}
