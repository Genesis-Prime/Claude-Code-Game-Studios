#!/bin/bash

# Resolve every executable and data path from this hook's own repository.
_CCGS_HOOK_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"
[ -n "$_CCGS_HOOK_DIR" ] || exit 0
. "$_CCGS_HOOK_DIR/trusted-root.sh" 2>/dev/null || exit 0
ccgs_bootstrap_trusted_root "$_CCGS_HOOK_DIR/../.." || exit 0
. "$_CCGS_HOOK_DIR/path-security.sh" 2>/dev/null || exit 0

# Claude Code SubagentStop hook: Log agent completion for audit trail
# Tracks when agents finish and their outcome
#
# Input schema (SubagentStop) — per Claude Code hooks reference:
# { "session_id": "...", "agent_id": "agent-abc123", "agent_type": "Explore",
#   "agent_transcript_path": "...", "last_assistant_message": "...", ... }
#
# The agent name is in `agent_type`, NOT `agent_name`. Reading `.agent_name`
# returns null on every invocation, so the fallback "unknown" is always used
# and the audit trail captures nothing useful.

# features.session_state: off => no audit trail. Default `on`; see
# session_state_enabled() in yaml-helper.sh.
if [ -f "$_CCGS_HOOK_DIR/yaml-helper.sh" ]; then
    . "$_CCGS_HOOK_DIR/yaml-helper.sh"
    session_state_enabled || exit 0
fi

INPUT=$(cat)

# Parse agent name -- use jq if available, fall back to grep
if command -v jq >/dev/null 2>&1; then
    AGENT_NAME=$(echo "$INPUT" | jq -r '.agent_type // "unknown"' 2>/dev/null)
else
    AGENT_NAME=$(echo "$INPUT" | grep -oE '"agent_type"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/"agent_type"[[:space:]]*:[[:space:]]*"//;s/"$//')
fi
# OUTSIDE the branch, like SESSION_ID below. jq's `// "unknown"` substitutes for
# null and false but NOT for an empty string, so the jq path could emit a record
# with no agent name at all while the grep path guarded against it. One guard,
# both paths.
[ -z "$AGENT_NAME" ] && AGENT_NAME="unknown"
AGENT_NAME=$(printf '%s' "$AGENT_NAME" | ccgs_sanitize_text 100)
case "$AGENT_NAME" in ''|*[!A-Za-z0-9._:-]*) AGENT_NAME="unknown" ;; esac

# Parse session id -- keeps the completion record in the same three-field shape
# as log-agent.sh so both sides of a spawn belong to an identifiable session.
if command -v jq >/dev/null 2>&1; then
    SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
else
    SESSION_ID=$(echo "$INPUT" | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/"session_id"[[:space:]]*:[[:space:]]*"//;s/"$//')
fi
[ -z "$SESSION_ID" ] && SESSION_ID="unknown"
SESSION_ID=$(printf '%s' "$SESSION_ID" | ccgs_sanitize_text 100)
case "$SESSION_ID" in ''|*[!A-Za-z0-9._:-]*) SESSION_ID="unknown" ;; esac

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
printf '%s | %s | Agent completed: %s\n' "$TIMESTAMP" "$SESSION_ID" "$AGENT_NAME" \
    | ccgs_safe_append "production/session-logs/agent-audit.log" \
    || echo "agent audit: secure append failed" >&2

exit 0
