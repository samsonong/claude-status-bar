import SwiftUI
import ServiceManagement

/// The dropdown menu content shown when the user clicks the status bar icon.
/// Displays each tracked session with its project name, status, label picker,
/// and untrack option. Also shows detected processes with track/untrack buttons.
struct SessionMenuView: View {
    @ObservedObject var sessionManager: SessionManager
    @State private var launchAtLogin: Bool = false
    @State private var editingLabelDir: String? = nil

    /// All selectable label characters: a-z then 0-9.
    private static let allLabels: [String] = {
        let letters = (UnicodeScalar("a").value...UnicodeScalar("z").value)
            .map { String(UnicodeScalar($0)!) }
        let digits = (0...9).map { String($0) }
        return letters + digits
    }()

    private static let connectingColor = Color(red: 0.30, green: 0.30, blue: 0.55)

    private let gridColumns = Array(repeating: GridItem(.fixed(28), spacing: 2), count: 6)

    /// Detected processes not already represented by a session, deduped by projectDir.
    private var nonSessionProcesses: [DetectedProcess] {
        let sessionDirs = Set(sessionManager.sessions.map(\.projectDir))
        var seen = Set<String>()
        return sessionManager.detectedProcesses.filter { process in
            guard !sessionDirs.contains(process.projectDir),
                  !seen.contains(process.projectDir) else { return false }
            seen.insert(process.projectDir)
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if sessionManager.sessions.isEmpty && nonSessionProcesses.isEmpty {
                Text("No active sessions")
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ForEach(sessionManager.sessions.prefix(SessionManager.maxSessions)) { session in
                    sessionRow(session)
                    Divider()
                }

                ForEach(nonSessionProcesses, id: \.projectDir) { process in
                    processRow(process)
                    Divider()
                }
            }

            Divider()

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .onChange(of: launchAtLogin) { newValue in
                    setLaunchAtLogin(newValue)
                }

            Divider()

            Button("Quit Claude Status Bar") {
                sessionManager.stop()
                NSApplication.shared.terminate(nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 280)
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
                        .fill(session.dotColor)
                        .frame(width: 8, height: 8)

                    Text(session.projectName)
                        .font(.system(size: 13, weight: .medium))

                    statusPill(session.status.label, color: pillColor(for: session.status))

                    if session.isStale {
                        statusPill("stale", color: .secondary)
                    }
                }

                Text(session.projectDir)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            labelButton(for: session.projectDir)

            Button {
                sessionManager.untrackSession(id: session.id)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 16))
                    .foregroundColor(.red.opacity(0.5))
            }
            .buttonStyle(.borderless)
            .help("Untrack")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Process Row (tracked or untracked)

    @ViewBuilder
    private func processRow(_ process: DetectedProcess) -> some View {
        let tracked = sessionManager.isTracked(projectDir: process.projectDir)

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(tracked ? Self.connectingColor : Color.gray.opacity(0.6))
                        .frame(width: 8, height: 8)

                    Text(SessionManager.displayName(for: process.projectDir))
                        .font(.system(size: 13, weight: .medium))

                    if tracked {
                        statusPill("connecting", color: Self.connectingColor)
                    }
                }

                if isPathMeaningful(process.projectDir) {
                    Text(process.projectDir)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if tracked {
                labelButton(for: process.projectDir)

                Button {
                    sessionManager.untrackProcess(projectDir: process.projectDir)
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 16))
                        .foregroundColor(.red.opacity(0.5))
                }
                .buttonStyle(.borderless)
                .help("Untrack")
            } else {
                Button {
                    sessionManager.registerAndTrack(process: process)
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 16))
                        .foregroundColor(.green.opacity(0.5))
                }
                .buttonStyle(.borderless)
                .help("Track")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Label Picker

    @ViewBuilder
    private func labelButton(for projectDir: String) -> some View {
        let currentLabel = sessionManager.label(for: projectDir)

        Button {
            editingLabelDir = projectDir
        } label: {
            Image(systemName: SessionManager.sfSymbolName(for: currentLabel))
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Change label")
        .popover(isPresented: Binding(
            get: { editingLabelDir == projectDir },
            set: { if !$0 { editingLabelDir = nil } }
        )) {
            labelGrid(for: projectDir, currentLabel: currentLabel)
        }
    }

    @ViewBuilder
    private func labelGrid(for projectDir: String, currentLabel: String) -> some View {
        let disabledLabels = sessionManager.customLabelsUsedByActiveProjects(excluding: projectDir)

        VStack(spacing: 8) {
            Text("Choose label")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            LazyVGrid(columns: gridColumns, spacing: 2) {
                ForEach(Self.allLabels, id: \.self) { char in
                    let isCurrent = char == currentLabel
                    let isDisabled = disabledLabels.contains(char)

                    Button {
                        sessionManager.setCustomLabel(char, forProject: projectDir)
                        editingLabelDir = nil
                    } label: {
                        Image(systemName: "\(char).circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(
                                isCurrent ? .accentColor
                                : isDisabled ? .secondary.opacity(0.15)
                                : .secondary.opacity(0.5)
                            )
                    }
                    .buttonStyle(.borderless)
                    .disabled(isDisabled)
                }
            }

            if sessionManager.customLabels[projectDir] != nil {
                Button("Reset to auto") {
                    sessionManager.setCustomLabel(nil, forProject: projectDir)
                    editingLabelDir = nil
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }
        }
        .padding(10)
    }

    // MARK: - Status Pill

    @ViewBuilder
    private func statusPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .cornerRadius(3)
    }

    private func pillColor(for status: SessionStatus) -> Color {
        status.color
    }

    // MARK: - Helpers

    private func isPathMeaningful(_ path: String) -> Bool {
        path != "/" && !path.isEmpty && path != "Unknown"
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
            launchAtLogin = !enabled
        }
    }
}
