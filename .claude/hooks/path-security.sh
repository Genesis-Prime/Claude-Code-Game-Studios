#!/usr/bin/env bash

# Shared safe filesystem operations for automatic hooks. On platforms with
# handle-relative traversal, Python holds validated descriptors while reading
# or writing, rejects links, and keeps every relative path beneath the
# script-anchored project root. Other platforms fail closed.

_ccgs_state_python=""
_ccgs_path_security_dir="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"
_ccgs_path_security_root="$(CDPATH= cd -- "$_ccgs_path_security_dir/../.." 2>/dev/null && pwd -P)"

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
    local root="${1:-${CCGS_ROOT:-$_ccgs_path_security_root}}"
    [ -n "$root" ] || return 1
    local state_file="$root/production/session-state/active.md"
    [ -e "$state_file" ] || [ -L "$state_file" ]
}

ccgs_read_session_state() {
    local root="${1:-${CCGS_ROOT:-$_ccgs_path_security_root}}"
    [ -n "$root" ] || return 1
    local helper="$_ccgs_path_security_dir/read-session-state.py"

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

ccgs_secure_file() {
    local operation="$1"
    local relative="$2"
    local root="${3:-${CCGS_ROOT:-$_ccgs_path_security_root}}"
    [ -n "$root" ] || return 1
    local helper="$_ccgs_path_security_dir/secure-file.py"

    if ! ccgs_resolve_state_python; then
        echo "secure-file: Python 3 with isolated mode is required" >&2
        return 1
    fi
    if [ ! -f "$helper" ] || [ -L "$helper" ]; then
        echo "secure-file: trusted helper is unavailable" >&2
        return 1
    fi
    "$_ccgs_state_python" -I "$helper" "$operation" "$root" "$relative"
}

ccgs_safe_append() { ccgs_secure_file append "$1" "${2:-${CCGS_ROOT:-$_ccgs_path_security_root}}"; }
ccgs_safe_replace() { ccgs_secure_file replace "$1" "${2:-${CCGS_ROOT:-$_ccgs_path_security_root}}"; }
ccgs_safe_read() { ccgs_secure_file read "$1" "${2:-${CCGS_ROOT:-$_ccgs_path_security_root}}"; }
ccgs_safe_mkdir() { ccgs_secure_file mkdir "$1" "${2:-${CCGS_ROOT:-$_ccgs_path_security_root}}"; }
