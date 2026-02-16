#!/bin/bash
# claude-status-bar.sh — Claude Code hook script for the Claude Status Bar app.
#
# This script is called by Claude Code hooks (configured in settings.json).
# It receives hook event JSON on stdin, derives the session status, and
# atomically updates ~/.claude/claude-status-bar.json using directory-based
# locking (mkdir is atomic on all filesystems) to prevent concurrent write
# corruption.
#
# Status derivation:
#   SessionStart       -> idle
#   UserPromptSubmit   -> running
#   PreToolUse         -> pending (if AskUserQuestion) / running (otherwise)
#   PermissionRequest  -> pending
#   PostToolUse        -> running
#   PostToolUseFailure -> idle (if is_interrupt) / running (otherwise)
#   Stop               -> completed
#   SessionEnd         -> (remove session)

set -euo pipefail

# Verify python3 is available (ships with macOS since Catalina)
if [ ! -x /usr/bin/python3 ]; then
    exit 0
fi

STATE_FILE="$HOME/.claude/claude-status-bar.json"
LOCK_DIR="$STATE_FILE.lock"

# Read the entire hook event JSON from stdin
INPUT=$(cat)

# Parse all fields in a single python3 invocation (available on all macOS systems).
# Pass JSON via stdin to avoid ARG_MAX limits on large payloads.
PARSED=$(/usr/bin/python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
print(data.get('session_id', ''))
print(data.get('hook_event_name', ''))
print(data.get('cwd', ''))
print(data.get('tool_name', ''))
print('true' if data.get('is_interrupt') else 'false')
" <<< "$INPUT" 2>/dev/null) || exit 0

SESSION_ID=$(echo "$PARSED" | sed -n '1p')
HOOK_EVENT=$(echo "$PARSED" | sed -n '2p')
CWD=$(echo "$PARSED" | sed -n '3p')
TOOL_NAME=$(echo "$PARSED" | sed -n '4p')
IS_INTERRUPT=$(echo "$PARSED" | sed -n '5p')

# Exit if we don't have a valid session ID or working directory
[ -z "$SESSION_ID" ] && exit 0
[ -z "$HOOK_EVENT" ] && exit 0
[ -z "$CWD" ] && exit 0

# Ensure the state file directory exists
mkdir -p "$(dirname "$STATE_FILE")"

# Derive status from the hook event
derive_status() {
    case "$HOOK_EVENT" in
        SessionStart)
            echo "idle"
            ;;
        UserPromptSubmit)
            echo "running"
            ;;
        PreToolUse)
            if [ "$TOOL_NAME" = "AskUserQuestion" ]; then
                echo "pending"
            else
                echo "running"
            fi
            ;;
        PermissionRequest)
            echo "pending"
            ;;
        PostToolUse)
            echo "running"
            ;;
        PostToolUseFailure)
            if [ "$IS_INTERRUPT" = "true" ]; then
                echo "idle"
            else
                echo "running"
            fi
            ;;
        Stop)
            echo "completed"
            ;;
        SessionEnd)
            echo "__remove__"
            ;;
        *)
            echo ""
            ;;
    esac
}

STATUS=$(derive_status)
[ -z "$STATUS" ] && exit 0

PROJECT_NAME="${CWD:+$(basename "$CWD")}"
PROJECT_NAME="${PROJECT_NAME:-Unknown Project}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Acquire lock using mkdir (atomic on all filesystems).
# Retry with exponential backoff up to ~1 second total.
acquire_lock() {
    local max_attempts=10
    local attempt=0
    local delay_ms=10
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$max_attempts" ]; then
            # Check if the lock holder is still alive
            local lock_pid
            lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
            if [ -z "$lock_pid" ]; then
                # PID file missing — lock was just acquired by another process; give up
                return 1
            fi
            if kill -0 "$lock_pid" 2>/dev/null; then
                # Lock holder is still running — give up
                return 1
            fi
            # Stale lock (holder is dead) — remove and retry once
            rm -rf "$LOCK_DIR"
            if mkdir "$LOCK_DIR" 2>/dev/null; then
                echo $$ > "$LOCK_DIR/pid"
                return 0
            fi
            return 1
        fi
        # Sleep using awk for fractional seconds (avoids bc dependency)
        sleep "$(awk "BEGIN{printf \"%.3f\", $delay_ms/1000}")"
        delay_ms=$((delay_ms * 2))
    done
    echo $$ > "$LOCK_DIR/pid"
}

release_lock() {
    rm -rf "$LOCK_DIR"
}

acquire_lock || exit 0

# Set trap AFTER successful lock acquisition to avoid releasing another process's lock.
# Also clean up any orphaned temp file.
cleanup() {
    rm -f "$STATE_FILE.tmp"
    release_lock
}
trap cleanup EXIT

# Read the current state file, or start with an empty state
if [ -f "$STATE_FILE" ]; then
    CURRENT=$(cat "$STATE_FILE")
else
    CURRENT='{"sessions":{}}'
fi

# Update the state using python3 for reliable JSON manipulation.
# Pass current state via stdin to avoid ARG_MAX limits on large state files.
/usr/bin/python3 -c "
import sys, json

try:
    data = json.loads(sys.stdin.read())
except (json.JSONDecodeError, ValueError):
    data = {'sessions': {}}

session_id = sys.argv[1]
status = sys.argv[2]
cwd = sys.argv[3]
project_name = sys.argv[4]
hook_event = sys.argv[5]
timestamp = sys.argv[6]

if 'sessions' not in data:
    data['sessions'] = {}

if status == '__remove__':
    data['sessions'].pop(session_id, None)
else:
    existing = data['sessions'].get(session_id)
    if existing:
        # Preserve the original project_dir from when the session started
        existing['status'] = status
        existing['last_event'] = hook_event
        existing['last_updated'] = timestamp
    else:
        data['sessions'][session_id] = {
            'id': session_id,
            'status': status,
            'project_dir': cwd,
            'project_name': project_name,
            'last_event': hook_event,
            'last_updated': timestamp
        }

json.dump(data, sys.stdout, indent=2)
" "$SESSION_ID" "$STATUS" "$CWD" "$PROJECT_NAME" "$HOOK_EVENT" "$TIMESTAMP" <<< "$CURRENT" > "$STATE_FILE.tmp"

# Atomic rename
mv "$STATE_FILE.tmp" "$STATE_FILE"
