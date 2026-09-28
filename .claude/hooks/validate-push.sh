#!/usr/bin/env bash

_CCGS_HOOK_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"
[ -n "$_CCGS_HOOK_DIR" ] || exit 2
. "$_CCGS_HOOK_DIR/trusted-root.sh" 2>/dev/null || exit 2
ccgs_bootstrap_trusted_root "$_CCGS_HOOK_DIR/../.." || exit 2

# PreToolUse hook for Git pushes. Branch protection remains authoritative; this
# hook recognizes common wrappers, global options, and full refspecs so its local
# warning cannot be bypassed by spelling the same push differently.
INPUT=$(cat)
_VP_PY=""
for _candidate in python python3 py; do
    if command -v "$_candidate" >/dev/null 2>&1 \
        && "$_candidate" -I -c 'import sys; raise SystemExit(0 if sys.version_info[0] >= 3 else 1)' >/dev/null 2>&1; then
        _VP_PY="$_candidate"
        break
    fi
done
if [ -z "$_VP_PY" ]; then
    echo "BLOCKED: Python 3 isolated mode is required for push validation" >&2
    exit 2
fi

MATCHED_BRANCH=$(printf '%s' "$INPUT" | "$_VP_PY" -I "$_CCGS_HOOK_DIR/git-command-security.py" push "$CCGS_ROOT")
_CLASS_RC=$?
case "$_CLASS_RC" in
    0) ;;
    1) exit 0 ;;
    *) echo "BLOCKED: possible Git push could not be validated safely" >&2; exit 2 ;;
esac

if [ -n "$MATCHED_BRANCH" ]; then
    echo "Push affecting protected target '$MATCHED_BRANCH' detected." >&2
    echo "Reminder: Ensure build passes, unit tests pass, and no S1/S2 bugs exist." >&2
fi

exit 0
