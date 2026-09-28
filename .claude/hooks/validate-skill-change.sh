#!/bin/bash

# Resolve every executable and data path from this hook's own repository.
_CCGS_HOOK_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"
[ -n "$_CCGS_HOOK_DIR" ] || exit 2
. "$_CCGS_HOOK_DIR/trusted-root.sh" 2>/dev/null || exit 2
ccgs_bootstrap_trusted_root "$_CCGS_HOOK_DIR/../.." || exit 2

# Claude Code PostToolUse hook: Advises running skill-test after skill file changes
# Fires when any file inside .claude/skills/ is written or edited.
#
# Exit behavior:
#   exit 0 = advisory only (non-blocking)
#
# Input schema (PostToolUse for Write|Edit):
# { "tool_name": "Write", "tool_input": { "file_path": "...", "content": "..." } }

INPUT=$(cat)

# Parse file path -- use jq if available, fall back to grep
if command -v jq >/dev/null 2>&1; then
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
else
    FILE_PATH=$(echo "$INPUT" | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/"file_path"[[:space:]]*:[[:space:]]*"//;s/"$//')
fi

# Normalize path separators (Windows backslash to forward slash).
#
# TWO rules, and the order matters. The hook input is JSON, so a Windows path
# arrives escaped: "C:\\Users\\x". jq unescapes it to a single backslash, but
# the grep fallback CANNOT -- it hands back the raw two-character `\\`. A
# single `s|\\|/|g` then turns each of those into its own slash, producing
# `.claude//skills//help//SKILL.md`, which no path test below matches. The hook
# went silent on every Windows edit whenever jq was absent -- and jq is absent
# on a stock Windows Git Bash, which is this project's primary platform.
#
# Rule 1 collapses the escaped pair to one slash; rule 2 handles an already
# unescaped separator (the jq path, or a POSIX caller). Running both is safe
# for either input because rule 1 finds nothing to do on unescaped text.
FILE_PATH=$(printf '%s' "$FILE_PATH" | sed 's|\\\\|/|g; s|\\|/|g')

# Only act on files inside .claude/skills/
if ! echo "$FILE_PATH" | grep -qE '(^|/)\.claude/skills/'; then
    exit 0
fi

# Extract skill name from path (.claude/skills/[skill-name]/SKILL.md)
SKILL_NAME=$(echo "$FILE_PATH" | grep -oE '\.claude/skills/[^/]+' | sed 's|\.claude/skills/||')

if [ -z "$SKILL_NAME" ]; then
    exit 0
fi

echo "=== Skill Modified: $SKILL_NAME ===" >&2
echo "Run /skill-test static $SKILL_NAME to validate structural compliance." >&2
REL_PATH=".claude/skills/${FILE_PATH#*.claude/skills/}"
case "$REL_PATH" in
  *'/../'*|../*|*/..) ;;
  *)
    if git -C "$CCGS_ROOT" diff -- "$REL_PATH" 2>/dev/null \
        | grep -qE '^[+-]allowed-tools:' \
      || { [ -f "$CCGS_ROOT/$REL_PATH" ] \
           && ! git -C "$CCGS_ROOT" ls-files --error-unmatch -- "$REL_PATH" >/dev/null 2>&1 \
           && sed -n '1,/^---$/p' "$CCGS_ROOT/$REL_PATH" | grep -q '^allowed-tools:'; }; then
      echo "!!! SECURITY REVIEW REQUIRED: allowed-tools changed. Do not widen tool grants without explicit user approval. !!!" >&2
    fi
    ;;
esac
echo "====================================" >&2

exit 0
