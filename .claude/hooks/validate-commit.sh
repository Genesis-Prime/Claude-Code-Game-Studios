#!/usr/bin/env bash

_CCGS_HOOK_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"
[ -n "$_CCGS_HOOK_DIR" ] || exit 2
. "$_CCGS_HOOK_DIR/trusted-root.sh" 2>/dev/null || exit 2
ccgs_bootstrap_trusted_root "$_CCGS_HOOK_DIR/../.." || exit 2

# PreToolUse hook for Git commits. The command classifier parses the event once,
# recognizes wrappers and Git global options, and blocks ambiguous commit forms.
INPUT=$(cat)
_VC_PY=""
for _candidate in python python3 py; do
    if command -v "$_candidate" >/dev/null 2>&1 \
        && "$_candidate" -I -c 'import sys; raise SystemExit(0 if sys.version_info[0] >= 3 else 1)' >/dev/null 2>&1; then
        _VC_PY="$_candidate"
        break
    fi
done
if [ -z "$_VC_PY" ]; then
    echo "BLOCKED: Python 3 isolated mode is required for commit validation" >&2
    exit 2
fi

printf '%s' "$INPUT" | "$_VC_PY" -I "$_CCGS_HOOK_DIR/git-command-security.py" commit "$CCGS_ROOT"
_CLASS_RC=$?
case "$_CLASS_RC" in
    0) ;;
    1) exit 0 ;;
    *) echo "BLOCKED: possible Git commit could not be validated safely" >&2; exit 2 ;;
esac

. "$_CCGS_HOOK_DIR/yaml-helper.sh" 2>/dev/null || {
    echo "BLOCKED: trusted configuration helper is unavailable" >&2
    exit 2
}
WORKFLOW=$(resolve_setting modes.workflow 2>/dev/null | cut -f1)
[ -n "$WORKFLOW" ] || WORKFLOW="standard"
_CR=$(resolve_code_root 2>/dev/null)
CODE_ROOT=$(printf '%s' "$_CR" | cut -f1)

"$_VC_PY" -I "$_CCGS_HOOK_DIR/validate-staged.py" "$CCGS_ROOT" "$WORKFLOW" "$CODE_ROOT"
exit $?
