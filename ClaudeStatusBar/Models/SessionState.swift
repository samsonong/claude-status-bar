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

    /// AppKit system color for this status. Uses dynamic NSColor that adapts to light/dark mode.
    private var systemColor: NSColor {
        switch self {
        case .pending:   return .systemOrange
        case .completed: return .systemGreen
        case .running:   return .systemBlue
        case .idle:      return .systemGray
        }
    }

    /// SwiftUI color for this status. Wraps the dynamic NSColor so it adapts to light/dark mode.
    var color: Color {
        Color(nsColor: systemColor)
    }

    /// AppKit color for this status, used for menu bar icon rendering.
    /// Uses dynamic NSColor that adapts to light/dark mode.
    var nsColor: NSColor {
        systemColor
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
    /// Completed and pending sessions stay at full opacity — they always need attention.
    var dotColor: Color {
        isStale && status != .pending && status != .completed ? status.color.opacity(0.55) : status.color
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

/// Icon rendering theme for the menu bar.
enum IconTheme: String, CaseIterable {
    case apple
    case bold

    var label: String {
        switch self {
        case .apple: return "Apple"
        case .bold: return "Bold"
        }
    }
}

/// The root structure of the state file at ~/.claude/claude-status-bar.json.
struct StateFile: Codable, Sendable {
    var sessions: [String: Session]

    init(sessions: [String: Session] = [:]) {
        self.sessions = sessions
    }
}
