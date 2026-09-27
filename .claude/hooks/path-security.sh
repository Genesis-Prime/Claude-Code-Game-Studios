#!/usr/bin/env bash

# Shared reader for the local session checkpoint. Callers consume the bytes
# emitted by ccgs_read_session_state instead of reopening active.md themselves.
# The Python helper holds one descriptor through validation and reading, which
# keeps a path swap from changing the object after it has been approved.

_ccgs_state_python=""

ccgs_resolve_state_python() {
    if [ -n "$_ccgs_state_python" ]; then
        return 0
    fi

    local candidate
    for candidate in python python3 py; do
        if command -v "$candidate" >/dev/null 2>&1 \
            && "$candidate" -I -c 'import sys; raise SystemExit(0 if sys.version_info[0] >= 3 else 1)' >/dev/null 2>&1; then
            _ccgs_state_python="$candidate"
            return 0
        fi
    done

    return 1
}

ccgs_session_state_path_present() {
    local root="${1:-${CCGS_ROOT:-$PWD}}"
    local state_file="$root/production/session-state/active.md"
    [ -e "$state_file" ] || [ -L "$state_file" ]
}

ccgs_read_session_state() {
    local root="${1:-${CCGS_ROOT:-$PWD}}"
    local helper="${CCGS_ROOT:-$root}/.claude/hooks/read-session-state.py"

    if ! ccgs_resolve_state_python; then
        echo "session-state security: Python 3 with isolated mode is required; checkpoint not loaded" >&2
        return 1
    fi
    if [ ! -f "$helper" ] || [ -L "$helper" ]; then
        echo "session-state security: trusted checkpoint reader is unavailable" >&2
        return 1
    fi

    "$_ccgs_state_python" -I "$helper" "$root"
}
