import Foundation

/// Represents a hook event received from the Claude Code hook system.
/// The hook script receives this as JSON on stdin and writes the derived
/// status to the shared state file.
struct HookEvent: Codable {
    let sessionId: String
    let hookEventName: String
    let cwd: String?
    let toolName: String?
    let isInterrupt: Bool?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case hookEventName = "hook_event_name"
        case cwd
        case toolName = "tool_name"
        case isInterrupt = "is_interrupt"
    }

    /// Derives the session status from this hook event based on the status mapping table.
    ///
    /// | Hook Event         | Condition                        | Status    |
    /// |--------------------|----------------------------------|-----------|
    /// | SessionStart       | --                               | idle      |
    /// | UserPromptSubmit   | --                               | running   |
    /// | PreToolUse         | tool_name == AskUserQuestion     | pending   |
    /// | PreToolUse         | tool_name != AskUserQuestion     | running   |
    /// | PermissionRequest  | --                               | pending   |
    /// | PostToolUse        | --                               | running   |
    /// | PostToolUseFailure | is_interrupt == true             | idle      |
    /// | PostToolUseFailure | is_interrupt != true             | running   |
    /// | Stop               | --                               | completed |
    /// | SessionEnd         | --                               | (remove)  |
    var derivedStatus: SessionStatus? {
        switch hookEventName {
        case "SessionStart":
            return .idle
        case "UserPromptSubmit":
            return .running
        case "PreToolUse":
            if toolName == "AskUserQuestion" {
                return .pending
            }
            return .running
        case "PermissionRequest":
            return .pending
        case "PostToolUse":
            return .running
        case "PostToolUseFailure":
            return isInterrupt == true ? .idle : .running
        case "Stop":
            return .completed
        case "SessionEnd":
            return nil // Signal to remove the session
        default:
            return nil
        }
    }

    /// Whether this event signals the end of a session.
    var isSessionEnd: Bool {
        hookEventName == "SessionEnd"
    }
}
