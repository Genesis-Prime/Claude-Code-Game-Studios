#!/usr/bin/env bash

# Anchor framework hooks to the repository that contains the running script.
# Event payloads, the caller's working directory, and CLAUDE_PROJECT_DIR are
# untrusted inputs.  They may confirm the anchor, but they never select it.

ccgs_canonical_directory() {
    [ -n "${1:-}" ] || return 1
    (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

ccgs_bootstrap_trusted_root() {
    local expected supplied
    expected=$(ccgs_canonical_directory "${1:-}") || {
        echo "hook security: trusted project root is unavailable" >&2
        return 1
    }

    if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
        supplied=$(ccgs_canonical_directory "$CLAUDE_PROJECT_DIR") || {
            echo "hook security: CLAUDE_PROJECT_DIR is unavailable" >&2
            return 1
        }
        if [ "$supplied" != "$expected" ]; then
            echo "hook security: CLAUDE_PROJECT_DIR does not match the running hook" >&2
            return 1
        fi
    fi

    CCGS_ROOT="$expected"
    export CCGS_ROOT
    cd -- "$CCGS_ROOT" 2>/dev/null || {
        echo "hook security: cannot enter the trusted project root" >&2
        return 1
    }
}
