#!/bin/bash

# Resolve every executable and data path from this hook's own repository.
_CCGS_HOOK_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"
[ -n "$_CCGS_HOOK_DIR" ] || exit 0
. "$_CCGS_HOOK_DIR/trusted-root.sh" 2>/dev/null || exit 0
ccgs_bootstrap_trusted_root "$_CCGS_HOOK_DIR/../.." || exit 0
. "$_CCGS_HOOK_DIR/path-security.sh" 2>/dev/null || exit 0

# Claude Code InstructionsLoaded hook: record WHICH instruction file loaded and
# WHY.
#
# WHAT THIS ANSWERS
# `.claude/rules/*.md` files carry `paths:` frontmatter, and a path-scoped rule
# loads only when Claude READS a file matching the pattern -- not on every tool
# use, and not when it CREATES one. This framework's agents predominantly create
# files: a new GDD, a new source file, a new test. So "does the rule for
# src/gameplay/** ever actually reach the model?" has a real answer, and before
# this hook the only way to get it was to infer it from behaviour afterwards.
#
# That inference was made once here, expensively: a data-file rule specified one
# key casing, agents wrote the other, and nothing surfaced the disagreement.
# Measurement replaces the inference.
#
# MEASURED, same repo, one session:
#   session_start     CLAUDE.md
#   include           its four @-imports, each carrying parent_file_path
#   path_glob_match   .claude/rules/skill-authoring.md, after READING a file
#                     under .claude/agents/** -- one of its declared paths
#   (nothing)         after CREATING a file under prototypes/** -- a declared
#                     path of .claude/rules/prototype-code.md
# Read fires, create does not. Keep this hook wired: the behaviour is upstream
# and can change in either direction, and this is the only thing here that would
# notice.
#
# SCHEMA CONFIRMED, NOT ASSUMED
# The common fields are documented; the event-specific ones are not. `pick()`
# tries the confirmed name first and keeps alternates behind it, so a schema
# change degrades to a fallback rather than to a blank column -- and the RAW
# line carries the answer regardless. That is how `load_reason` was found: the
# first guess (`reason`) missed, and the raw payload named the real field.
#
# NOT GATED ON features.session_state, deliberately. This is a diagnostic wired
# up on purpose; silencing it from an unrelated flag would make it do nothing
# while still looking installed -- the failure shape
# `.claude/rules/skill-authoring.md` exists to prevent.
#
# The exit code is ignored for this event and it cannot block a load. Fail
# silent, stay cheap: it fires once per instruction file per load.

LOG_DIR="production/session-logs"
LOG="$LOG_DIR/instructions-loaded.log"

# stdin may be absent; an unbounded read would then hang until the hook timeout.
[ -t 0 ] && exit 0
if command -v timeout >/dev/null 2>&1; then
    INPUT=$(timeout 2 cat 2>/dev/null)
else
    INPUT=$(cat 2>/dev/null)
fi
[ -n "$INPUT" ] || exit 0

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# `head -1` on every grep: an unanchored match can hit the same key nested
# deeper in the payload, and a multi-line value would break the one-record-per-
# line format this log depends on.
pick() { # <json> <key>...
    _j="$1"; shift
    for _k in "$@"; do
        _v=$(printf '%s' "$_j" \
             | grep -oE "\"$_k\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
             | head -1 \
             | sed "s/\"$_k\"[[:space:]]*:[[:space:]]*\"//;s/\"$//")
        if [ -n "$_v" ]; then printf '%s' "$_v"; return 0; fi
    done
    printf ''
}

FILE_VAL=$(pick "$INPUT" file_path path file source_path instruction_path filePath)
REASON_VAL=$(pick "$INPUT" load_reason reason loadReason matcher trigger source)
PARENT_VAL=$(pick "$INPUT" parent_file_path parentFilePath parent)

# Paths arrive as absolute Windows paths with JSON-escaped separators. Left raw,
# the readable line is the least readable thing in the log. Unescape, normalise
# to forward slashes, strip the repo prefix -- so the column reads
# `.claude/rules/gameplay-code.md`, which is what anyone scanning this is
# looking for. The RAW line below keeps the original bytes untouched.
# TWO forms of the repo root, because the payload and the shell disagree about
# what a path looks like on Windows. Git Bash reports $PWD as `/c/Users/...`
# while the payload carries `C:\Users\...`; stripping only the shell's form
# silently strips nothing and the column stays absolute -- which is why this
# needs checking on real payloads rather than a fixture. `pwd -W` gives the Windows
# form where it exists and is empty elsewhere, so both are tried and neither is
# required.
_PWD_FWD=$(printf '%s' "$PWD" | sed 's|\\|/|g')
_PWD_WIN=$(pwd -W 2>/dev/null | sed 's|\\|/|g')
shorten() {
    [ -n "$1" ] || return 0
    printf '%s' "$1" | sed 's|\\\\|/|g; s|\\|/|g' \
        | sed "s|^${_PWD_FWD}/||" \
        | { if [ -n "$_PWD_WIN" ]; then sed "s|^${_PWD_WIN}/||"; else cat; fi; }
}
FILE_SHORT=$(shorten "$FILE_VAL")
PARENT_SHORT=$(shorten "$PARENT_VAL")

{
    printf '%s | %-16s | %s%s\n' \
        "$TIMESTAMP" "${REASON_VAL:-?}" "${FILE_SHORT:-?}" \
        "${PARENT_SHORT:+  (via $PARENT_SHORT)}"
    # Raw payload on the following line, prefixed so the log stays greppable and
    # so an unrecognised schema is still recoverable from the file itself.
    printf '%s   RAW %s\n' "$TIMESTAMP" "$INPUT"
} | ccgs_safe_append "$LOG" || echo "instruction audit: secure append failed" >&2

exit 0
