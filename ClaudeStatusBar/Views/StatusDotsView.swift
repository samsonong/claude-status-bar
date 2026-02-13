import SwiftUI

/// Renders up to 5 colored dots representing Claude Code session statuses
/// in the menu bar. Each dot is colored based on session status:
/// - Green: idle (after Stop event)
/// - Yellow: pending (waiting for user input)
/// - Blue: running (executing)
/// Stale sessions (>5 min no events) show a dimmed version of their color.
struct StatusDotsView: View {
    let sessions: [Session]
    let newProcesses: [DetectedProcess]

    var body: some View {
        HStack(spacing: 3) {
            if sessions.isEmpty && newProcesses.isEmpty {
                // Show a single grey dot when no sessions or detected processes
                Circle()
                    .fill(Color.gray.opacity(0.6))
                    .frame(width: 8, height: 8)
            } else {
                let trackedCount = min(sessions.count, SessionManager.maxSessions)
                let untrackedSlots = SessionManager.maxSessions - trackedCount

                ForEach(sessions.prefix(SessionManager.maxSessions)) { session in
                    Circle()
                        .fill(session.dotColor)
                        .frame(width: 8, height: 8)
                        .help(tooltipText(for: session))
                }

                ForEach(newProcesses.prefix(untrackedSlots), id: \.pid) { process in
                    Circle()
                        .fill(Color.gray.opacity(0.6))
                        .frame(width: 8, height: 8)
                        .help(untrackedTooltip(for: process))
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private func tooltipText(for session: Session) -> String {
        var text = "\(session.projectName) — \(session.status.label)"
        if session.isStale {
            text += " (stale)"
        }
        return text
    }

    private func untrackedTooltip(for process: DetectedProcess) -> String {
        let name = displayName(for: process.projectDir)
        return "\(name) — Untracked"
    }

    private func displayName(for projectDir: String) -> String {
        if projectDir == "/" || projectDir.isEmpty || projectDir == "Unknown" {
            return "Unknown Project"
        }
        return (projectDir as NSString).lastPathComponent
    }
}
