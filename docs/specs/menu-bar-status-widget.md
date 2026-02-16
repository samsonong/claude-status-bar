# Feature Specification: Claude Code Menu Bar Status Widget

---
## HUMAN SUMMARY
---

### What & Why
A native macOS menu bar app that displays up to 5 colored dots representing the real-time status of Claude Code sessions across terminals (including VSCode integrated terminals). Each dot shows one of three states — idle (green), pending response (yellow), or running (blue) — so developers can monitor multiple Claude Code sessions at a glance without switching between terminals.

### Change Overview
| Area | Current State | After Implementation |
|------|---------------|---------------------|
| macOS Menu Bar | No Claude Code visibility | Up to 5 colored status dots in the menu bar |
| Claude Code Hooks | No status tracking | Global hooks write session state to a shared JSON file |
| Session Detection | Manual terminal switching | Auto-detection of new Claude Code processes with opt-in hook registration |

### Linked Features & Blast Radius

**Complexity Signal**: 2 systems affected → Medium complexity

| Feature | Link Type | Impact | Test Requirement |
|---------|-----------|--------|------------------|
| Claude Code hooks (`~/.claude/settings.json`) | Config/Event | Hooks are added to global settings to emit status events | Verify existing hooks are preserved when merging |
| Terminal processes | Process monitoring | App polls for `claude` processes to detect new sessions | Verify detection works for both standalone Terminal and VSCode integrated terminal |

### Key Decisions Made
- **Technology**: Swift/SwiftUI — native macOS, lightweight, proper system tray integration
- **Detection mechanism**: Hook-based JSON file + process polling for auto-detection of new instances
- **Status mapping**: idle=Stop event (green), pending=AskUserQuestion tool use (yellow), running=UserPromptSubmit/tool execution (blue)
- **Multi-session display**: Up to 5 colored dots shown directly in the menu bar (not aggregated into one icon)
- **Session lifecycle**: Dots removed immediately when session ends
- **Hook registration**: Auto-detect new Claude Code instances via process polling; user opts in via notification to register hooks for that project
- **Settings**: Minimal — launch at login toggle and manage tracked terminals in dropdown

### Out of Scope
- Windows/Linux support
- Custom color themes or symbol customization
- Sound/desktop notifications for status changes
- Session history or logging
- Remote/SSH Claude Code session tracking

---
## IMPLEMENTATION DETAILS
---

### Success Metrics
- App launches in menu bar within 2 seconds
- Status updates reflect within 1 second of hook event
- Process detection finds new Claude Code instances within 5 seconds
- Memory footprint stays under 50MB

### User Stories
- As a developer running multiple Claude Code sessions, I want to see their statuses in my menu bar so that I know which sessions need my attention without switching terminals
- As a developer starting a new Claude Code session, I want the app to detect it and offer to register hooks so that I don't have to manually configure anything
- As a developer, I want sessions to disappear from the menu bar when I close them so that I only see active sessions

### Acceptance Criteria
1. GIVEN the app is running WHEN it launches THEN a menu bar item appears with no dots (no active sessions)
2. GIVEN a Claude Code session starts WHEN the app detects it via process polling THEN a macOS notification prompts the user to register hooks for that session's project
3. GIVEN the user accepts hook registration THEN the app merges hook entries into `~/.claude/settings.json` (or the project-level `.claude/settings.local.json`) preserving existing hooks
4. GIVEN hooks are registered and Claude Code is idle (after `Stop` event) THEN the corresponding dot shows as green
5. GIVEN hooks are registered and Claude Code calls `AskUserQuestion` tool (`PreToolUse` event with tool_name matching) THEN the corresponding dot shows as yellow
6. GIVEN hooks are registered and the user submits a prompt (`UserPromptSubmit` event) THEN the corresponding dot shows as blue
7. GIVEN hooks are registered and Claude Code executes tools (between `PreToolUse` and `PostToolUse` for non-AskUserQuestion tools) THEN the corresponding dot stays blue
8. GIVEN a Claude Code session ends (`SessionEnd` event) THEN the corresponding dot is removed immediately from the menu bar
9. GIVEN 5 sessions are already tracked WHEN a 6th session is detected THEN the app does not prompt for registration (silently ignores)
10. GIVEN the user clicks the menu bar dots WHEN the dropdown opens THEN each tracked session shows: project name/directory, current status label, and an option to untrack
11. GIVEN the user toggles "Launch at Login" in the dropdown THEN the app registers/unregisters itself as a login item
12. GIVEN the user clicks "Untrack" on a session THEN the dot is removed and hooks are cleaned up from the project's settings

### Edge Cases & Error Handling
| Scenario | Expected Behavior |
|----------|------------------|
| `~/.claude/settings.json` doesn't exist | Create it with just the hook entries |
| `~/.claude/settings.json` already has hooks for the same events | Merge: append the status-monitor hook to the existing hooks array for that event |
| Claude Code process detected but hooks already registered | Don't prompt again; start tracking immediately |
| JSON state file is corrupted or missing | Recreate it; show dots as grey until next event |
| Multiple Claude Code sessions in the same project directory | Track as separate sessions (different session_ids) |
| App crashes and restarts | Re-read the state file and resume tracking; poll for active processes |
| Claude Code session becomes unresponsive (no events for >5 minutes) | Show a dimmed version of last known color; tooltip shows "stale" |
| VSCode terminal running Claude Code | Detected via process tree — `claude` process with ppid tracing to VSCode |

### Data Requirements

**State file** (`~/.claude/claude-status-bar.json`):
```json
{
  "sessions": {
    "<session_id>": {
      "status": "idle|pending|running",
      "project_dir": "/path/to/project",
      "project_name": "project-name",
      "last_event": "Stop",
      "last_updated": "2025-01-15T10:30:00Z"
    }
  }
}
```
- **Source**: Written by hook shell script, read by SwiftUI app via file watcher
- **Format**: JSON, overwritten atomically on each event
- **Persistence**: Ephemeral — cleared on app quit or stale session cleanup

**Hook shell script** (`~/.claude/hooks/claude-status-bar.sh`):
- Receives hook event JSON on stdin
- Reads session_id, hook_event_name, cwd, and tool_name (for PreToolUse) from stdin
- Updates the corresponding session entry in `~/.claude/claude-status-bar.json`
- Uses file locking (`flock`) to prevent concurrent write corruption

**Status derivation logic**:
| Hook Event | Condition | Status |
|------------|-----------|--------|
| `SessionStart` | — | `running` |
| `UserPromptSubmit` | — | `running` |
| `PreToolUse` | tool_name == `AskUserQuestion` | `pending` |
| `PreToolUse` | tool_name != `AskUserQuestion` | `running` |
| `PostToolUse` | tool_name == `AskUserQuestion` | `running` |
| `Stop` | — | `idle` |
| `SessionEnd` | — | (remove session) |

### Security & Permissions
- App needs file read/write access to `~/.claude/` directory
- App needs process listing access (no special entitlement needed on macOS for own-user processes)
- No network access required
- The state file contains only session IDs and project paths — no secrets or conversation content
- Hook script runs with user permissions (same as Claude Code)

### Test Plan
- **Unit**: State file parsing, hook event → status mapping, settings.json merge logic, session cleanup on timeout
- **Integration**: Hook script writes → app reads and updates UI; process detection → notification → hook registration flow
- **Manual QA**:
  - Launch app, open Terminal, start `claude` → dot appears after opt-in
  - Submit prompt → dot turns blue; Claude responds → dot turns green
  - Claude asks question (AskUserQuestion) → dot turns yellow
  - Close terminal → dot disappears
  - Open 5 sessions → 5 dots; open 6th → no prompt
  - Toggle "Launch at Login" → verify login item registration
  - Quit and relaunch app → existing sessions re-detected

### Rollout Plan
1. **Phase 1**: Core app — menu bar dots, state file watching, dropdown with session list
2. **Phase 2**: Hook registration — auto-detect Claude Code processes, prompt for hook setup, merge hooks into settings
3. **Phase 3**: Polish — Launch at Login, untrack sessions, stale session handling

### Rollback Plan
- Trigger: App crashes repeatedly, hooks interfere with Claude Code
- Steps:
  1. Quit the menu bar app
  2. Remove hook entries from `~/.claude/settings.json` (app could provide an "Uninstall Hooks" menu item)
  3. Delete `~/.claude/claude-status-bar.json` state file
  4. Delete `~/.claude/hooks/claude-status-bar.sh` hook script
