#!/usr/bin/env bash

# Resolve every executable and data path from this hook's own repository.
_CCGS_HOOK_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"
[ -n "$_CCGS_HOOK_DIR" ] || exit 0
. "$_CCGS_HOOK_DIR/trusted-root.sh" 2>/dev/null || exit 0
ccgs_bootstrap_trusted_root "$_CCGS_HOOK_DIR/../.." || exit 0
. "$_CCGS_HOOK_DIR/path-security.sh" 2>/dev/null || exit 0

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
# smart quotes as string delimiters, so ASCII apostrophe escaping is not a
# sufficient cross-language boundary. Pass the text as environment data.
MESSAGE_DISPLAY=$(printf '%s' "$MESSAGE" | ccgs_sanitize_text 200)

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
