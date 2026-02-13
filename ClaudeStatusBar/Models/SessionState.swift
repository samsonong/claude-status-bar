import Foundation
import SwiftUI

/// Represents the current status of a Claude Code session.
enum SessionStatus: String, Codable, Sendable {
    case idle
    case pending
    case running

    /// The color name used to render this status as a dot in the menu bar.
    var colorName: String {
        switch self {
        case .idle: return "green"
        case .pending: return "yellow"
        case .running: return "blue"
        }
    }

    /// Human-readable label shown in the dropdown menu.
    var label: String {
        switch self {
        case .idle: return "Idle"
        case .pending: return "Waiting for input"
        case .running: return "Running"
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
        let baseColor: Color
        switch status {
        case .idle: baseColor = .green
        case .pending: baseColor = .yellow
        case .running: baseColor = .blue
        }
        return isStale ? baseColor.opacity(0.4) : baseColor
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
