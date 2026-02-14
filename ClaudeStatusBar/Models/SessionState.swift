import Foundation
import SwiftUI
import AppKit

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

    /// RGB components for this status. Single source of truth for both SwiftUI and AppKit.
    private var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .running:   return (0.35, 0.38, 0.45)
        case .idle:      return (0.55, 0.55, 0.55)
        case .completed: return (0.78, 0.38, 0.32)
        case .pending:   return (0.85, 0.55, 0.08)
        }
    }

    /// SwiftUI color for this status, matching the menu bar icon palette.
    var color: Color {
        let c = rgb
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    /// AppKit color for this status, used for menu bar icon rendering.
    var nsColor: NSColor {
        let c = rgb
        return NSColor(red: c.r, green: c.g, blue: c.b, alpha: 1.0)
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
