#!/usr/bin/env bash

_CCGS_HOOK_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"
[ -n "$_CCGS_HOOK_DIR" ] || exit 2
. "$_CCGS_HOOK_DIR/trusted-root.sh" 2>/dev/null || exit 2
ccgs_bootstrap_trusted_root "$_CCGS_HOOK_DIR/../.." || exit 2

for _candidate in python python3 py; do
    if command -v "$_candidate" >/dev/null 2>&1 \
        && "$_candidate" -I -c 'import sys; raise SystemExit(0 if sys.version_info[0] >= 3 else 1)' >/dev/null 2>&1; then
        "$_candidate" -I "$_CCGS_HOOK_DIR/validate-agent-request.py"
        exit $?
    fi
done

echo "BLOCKED: Python 3 isolated mode is required for agent validation" >&2
exit 2
