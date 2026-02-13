import SwiftUI

/// Renders up to 5 colored dots representing Claude Code session statuses
/// in the menu bar. Each dot is colored based on session status:
/// - Green: idle (after Stop event)
/// - Yellow: pending (waiting for user input)
/// - Blue: running (executing)
/// Stale sessions (>5 min no events) show a dimmed version of their color.
struct StatusDotsView: View {
    let sessions: [Session]

    var body: some View {
        HStack(spacing: 3) {
            if sessions.isEmpty {
                // Show a single grey dot when no sessions are active
                Circle()
                    .fill(Color.gray.opacity(0.5))
                    .frame(width: 8, height: 8)
            } else {
                ForEach(sessions.prefix(SessionManager.maxSessions)) { session in
                    Circle()
                        .fill(session.dotColor)
                        .frame(width: 8, height: 8)
                        .help(tooltipText(for: session))
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
}
