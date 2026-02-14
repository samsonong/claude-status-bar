import Foundation
import SwiftUI

/// Represents the current status of a Claude Code session.
enum SessionStatus: String, Codable, Sendable {
    case idle
    case running
    case pending
    case completed

    /// Human-readable label shown in the dropdown menu.
    var label: String {
        switch self {
        case .idle: return "Idle"
        case .completed: return "Completed"
        case .pending: return "Waiting for input"
        case .running: return "Running"
        }
    }

    /// SwiftUI color for this status, matching the menu bar icon palette.
    var color: Color {
        switch self {
        case .running:   return Color(red: 0.35, green: 0.38, blue: 0.45)
        case .idle:      return Color(red: 0.55, green: 0.55, blue: 0.55)
        case .completed: return Color(red: 0.78, green: 0.38, blue: 0.32)
        case .pending:   return Color(red: 0.85, green: 0.55, blue: 0.08)
        }
    }
}

/// A single tracked Claude Code session.
struct Session: Codable, Identifiable, Sendable {
    let id: String
    var status: SessionStatus
    var projectDir: String
    var projectName: String
    var lastEvent: String
    var lastUpdated: Date

    /// Whether the session is stale (no events for more than 5 minutes).
    var isStale: Bool {
        Date().timeIntervalSince(lastUpdated) > 300
    }

    /// The dot color for this session, dimmed if stale.
    var dotColor: Color {
        isStale ? status.color.opacity(0.55) : status.color
    }

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case projectDir = "project_dir"
        case projectName = "project_name"
        case lastEvent = "last_event"
        case lastUpdated = "last_updated"
    }
}

/// The root structure of the state file at ~/.claude/claude-status-bar.json.
struct StateFile: Codable, Sendable {
    var sessions: [String: Session]

    init(sessions: [String: Session] = [:]) {
        self.sessions = sessions
    }
}
