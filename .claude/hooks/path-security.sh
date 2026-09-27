#!/bin/bash

# Accept a session checkpoint only when it is a regular file reached without
# following symlinks and its physical parent is the project's state directory.
# Checking every component prevents production/ or session-state/ redirecting
# the read even when active.md itself is not a link.
trusted_session_state_file() {
    local candidate="$1"
    local component current physical_root physical_parent

    case "$candidate" in
        /*|../*|*/../*|*/..|..) return 1 ;;
    esac

    current="${CCGS_ROOT:-$PWD}"
    while IFS= read -r component; do
        [ -n "$component" ] || return 1
        current="$current/$component"
        [ ! -L "$current" ] || return 1
    done < <(printf '%s\n' "$candidate" | tr '/' '\n')

    [ -f "$current" ] || return 1
    physical_root=$(cd "${CCGS_ROOT:-$PWD}" 2>/dev/null && pwd -P) || return 1
    physical_parent=$(cd "$(dirname "$current")" 2>/dev/null && pwd -P) || return 1
    [ "$physical_parent" = "$physical_root/production/session-state" ]
}
