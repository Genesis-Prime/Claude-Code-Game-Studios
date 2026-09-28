#!/usr/bin/env bash

# Resolve every executable and data path from this hook's own repository.
_CCGS_HOOK_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"
[ -n "$_CCGS_HOOK_DIR" ] || exit 0
. "$_CCGS_HOOK_DIR/trusted-root.sh" 2>/dev/null || exit 0
ccgs_bootstrap_trusted_root "$_CCGS_HOOK_DIR/../.." || exit 0
. "$_CCGS_HOOK_DIR/path-security.sh" 2>/dev/null || exit 0

# post-compact.sh — fires after conversation compaction
# Reminds Claude to restore session state from the file-backed checkpoint.

# features.session_state: off => this hook is a no-op. Default `on`; see
# session_state_enabled() in yaml-helper.sh.
if [ -f "$_CCGS_HOOK_DIR/yaml-helper.sh" ]; then
    . "$_CCGS_HOOK_DIR/yaml-helper.sh"
    session_state_enabled || exit 0
fi

ACTIVE="production/session-state/active.md"

echo "=== Context Restored After Compaction ==="

if command -v ccgs_session_state_path_present >/dev/null 2>&1 \
    && ccgs_session_state_path_present "$CCGS_ROOT"; then
  if ccgs_emit_checkpoint "$CCGS_ROOT"; then
    echo "Validated bounded checkpoint from $ACTIVE."
  else
    echo "Session state exists but failed security validation; automatic recovery skipped."
  fi
else
  echo "No session state file found at $ACTIVE"
  echo "If you were mid-task, check production/session-logs/ for the last session audit."
fi

echo "========================================="
