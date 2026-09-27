#!/usr/bin/env bash

# --- work from the project root ----------------------------------------------
# Every path below is repo-relative, so a hook invoked with a working directory
# that is not the repo root would silently read and write the WRONG TREE --
# returning a near-empty result instead of the session-recovery block, and
# creating stray trees such as docs/production/session-logs/ on write.
#
# PRECEDENCE IS LOAD-BEARING. A cwd that IS a project root carries real
# information and must win: a caller sitting inside another project means that
# project, not this one. Resolving to the script's own location first would
# override them. So, in order:
#   1. cwd holds project.yaml   -> cwd   (a project root)
#   2. cwd holds .claude/       -> cwd   (a project root not yet configured)
#   3. CLAUDE_PROJECT_DIR       -> that  (populated in the hook environment)
#   4. this script's location   -> <root>/.claude/hooks/../.. by construction
# Rule 4 always works and needs no environment at all; rules 1-2 stop it from
# overriding a caller that legitimately means somewhere else.
#
# NOT an upward search: that resolves a nested project to its parent's config.
if [ -f "project.yaml" ] || [ -d ".claude" ]; then
  CCGS_ROOT="$PWD"
elif [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "${CLAUDE_PROJECT_DIR}" ]; then
  CCGS_ROOT="$CLAUDE_PROJECT_DIR"
else
  CCGS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
fi
[ -n "$CCGS_ROOT" ] && cd "$CCGS_ROOT" 2>/dev/null || true

# Notification hook — fires when Claude Code sends a notification
# Shows a Windows toast via PowerShell

# Read notification JSON from stdin
INPUT=$(cat)

# Extract message — try jq first, fall back to grep
if command -v jq &>/dev/null; then
  MESSAGE=$(echo "$INPUT" | jq -r '.message // empty' 2>/dev/null)
fi
if [ -z "${MESSAGE:-}" ]; then
  # `[[:space:]]*` around the colon, like every other hook's fallback. This one
  # required `"message":"` with no space, so a pretty-printed or space-separated
  # payload fell through to the generic text below and the real notification was
  # lost. Nothing reported that -- the hook still fired, just saying nothing.
  MESSAGE=$(echo "$INPUT" | grep -oE '"message"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | head -1 | sed 's/"message"[[:space:]]*:[[:space:]]*"//;s/"$//')
fi
if [ -z "$MESSAGE" ]; then
  MESSAGE="Claude Code needs your attention"
fi

# Keep notification text out of PowerShell source. PowerShell accepts Unicode
# smart quotes as string delimiters, so escaping ASCII apostrophes alone is not
# sufficient. An environment variable passes the text as data instead.
MESSAGE_DISPLAY=$(printf '%s' "$MESSAGE" | head -c 200)

# Show Windows balloon tip notification (works on all Windows 10/11 without extra modules)
CCGS_NOTIFICATION_MESSAGE="$MESSAGE_DISPLAY" \
powershell.exe -NonInteractive -WindowStyle Hidden -Command "
  Add-Type -AssemblyName System.Windows.Forms
  \$notify = New-Object System.Windows.Forms.NotifyIcon
  \$notify.Icon = [System.Drawing.SystemIcons]::Information
  \$notify.BalloonTipTitle = 'Claude Code'
  \$notify.BalloonTipText = \$env:CCGS_NOTIFICATION_MESSAGE
  \$notify.Visible = \$true
  \$notify.ShowBalloonTip(5000)
  Start-Sleep -Seconds 6
  \$notify.Dispose()
" 2>/dev/null &

printf 'Notification: %s\n' "$MESSAGE_DISPLAY"
