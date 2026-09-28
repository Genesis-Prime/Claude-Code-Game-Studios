#!/bin/bash

# Resolve every executable and data path from this hook's own repository.
_CCGS_HOOK_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"
[ -n "$_CCGS_HOOK_DIR" ] || exit 0
. "$_CCGS_HOOK_DIR/trusted-root.sh" 2>/dev/null || exit 0
ccgs_bootstrap_trusted_root "$_CCGS_HOOK_DIR/../.." || exit 0
. "$_CCGS_HOOK_DIR/path-security.sh" 2>/dev/null || exit 0

# Claude Code SessionStart hook: Load project context at session start
# Outputs context information that Claude sees when a session begins
#
# Input schema (SessionStart): stdin IS supplied -- VERIFIED, not asserted.
# Observed on real harness events as a single line of JSON with session_id,
# transcript_path, cwd, hook_event_name and `source` ("clear", "compact").
# Do NOT read stdin here unboundedly -- the harness may leave it open, and a
# blocking read costs this hook its whole 10s budget on every session start.
#
# THIS HOOK MUST FINISH INSIDE ITS BUDGET. If it is killed partway, the
# session-state block never reaches context and the session starts blind --
# and nothing visible from inside the session says so. The early-exit gating
# and bounded reads below are what keep it inside 2s; treat them as load-
# bearing, not as optimisation.
#
# If that ever recurs, the diagnostic that works is a FIRE/DONE pair appended
# to a gitignored log at the top and bottom of this script -- "did it run at
# all" and "did it get here" are opposite failures with opposite fixes, and
# nothing else distinguishes them. /compact in particular CANNOT be used as
# evidence: PostCompact runs post-compact.sh, which prints the checkpoint
# independently, so seeing the checkpoint proves nothing about this script.

echo "=== Claude Code Game Studios — Session Context ==="

# Current branch
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -n "$BRANCH" ]; then
    echo "Branch: $BRANCH"

    # Recent commits
    echo ""
    echo "Recent commits:"
    git log --oneline -5 2>/dev/null | while read -r line; do
        echo "  $line"
    done
fi

# Resolve review_mode the same way skills do: resolve_setting applies the FULL
# chain (project.local.yaml -> project.yaml -> legacy review-mode.txt -> modes.rigor
# expansion -> default). modes.review_mode is rigor-fronted and locally overridable,
# so only resolve_setting reflects both a rigor-derived value (a project that set
# only `rigor: minimal` shows `solo`) and a local override. get_effective_yaml_key
# returns empty for a rigor-only project, which would leave the banner showing a
# stale `lean`.
REVIEW_MODE=""
if [ -f "project.yaml" ] && [ -f "$_CCGS_HOOK_DIR/yaml-helper.sh" ]; then
    source "$_CCGS_HOOK_DIR/yaml-helper.sh"
    REVIEW_MODE=$(resolve_setting modes.review_mode 2>/dev/null | cut -f1)
fi
if [ -z "$REVIEW_MODE" ] && [ -f "production/review-mode.txt" ]; then
    REVIEW_MODE=$(head -1 production/review-mode.txt 2>/dev/null | tr -d '[:space:]')
fi
if [ -z "$REVIEW_MODE" ]; then
    REVIEW_MODE="lean"
fi
echo ""
echo "Review mode: $REVIEW_MODE"

# Schema validation — surface invalid enum values in
# project.yaml and project.local.yaml so typos like `automation: chaotic`
# surface at session start rather than failing inside a skill.
if [ -f "$_CCGS_HOOK_DIR/yaml-helper.sh" ]; then
    if ! type validate_yaml_enum >/dev/null 2>&1; then
        source "$_CCGS_HOOK_DIR/yaml-helper.sh"
    fi
    # Hard-error guard: project.local.yaml requires a project.yaml base
    if ! BASE_ERR=$(validate_local_yaml_base 2>&1); then
        echo ""
        echo "[!] $BASE_ERR"
    fi
    if [ -f "project.yaml" ]; then
        SCHEMA_ERRORS=$(validate_yaml_enum project.yaml 2>&1)
        if [ -n "$SCHEMA_ERRORS" ]; then
            echo ""
            echo "[!] project.yaml schema errors:"
            echo "$SCHEMA_ERRORS" | sed 's/^/    /'
        fi
    fi
    if [ -f "project.local.yaml" ]; then
        SCHEMA_ERRORS=$(validate_yaml_enum project.local.yaml 2>&1)
        if [ -n "$SCHEMA_ERRORS" ]; then
            echo ""
            echo "[!] project.local.yaml schema errors:"
            echo "$SCHEMA_ERRORS" | sed 's/^/    /'
        fi
    fi
fi

# --- Stage source agreement ---
# `project.stage` in project.yaml is authoritative; production/stage.txt is a
# legacy mirror kept for unmigrated hooks. Twelve consumers read the mirror --
# including detect-gaps.sh and yaml-helper.sh -- so when the two disagree, part
# of the system acts on one stage and part on the other, silently.
#
# Warn, never reconcile. Only /gate-check on a PASS may change a stage, so a
# hook that "helpfully" rewrote the mirror would be advancing a phase gate
# nobody passed. Helpers emit observations, never verdicts (CLAUDE.md).
STAGE_YAML=""
STAGE_TXT=""
if [ -f "project.yaml" ] && command -v get_yaml_key >/dev/null 2>&1; then
    STAGE_YAML=$(get_yaml_key project.yaml project.stage 2>/dev/null)
fi
if [ -f "production/stage.txt" ]; then
    STAGE_TXT=$(head -1 production/stage.txt 2>/dev/null | tr -d '\r' | sed 's/[[:space:]]*$//')
fi
if [ -n "$STAGE_YAML" ] && [ -n "$STAGE_TXT" ] && [ "$STAGE_YAML" != "$STAGE_TXT" ]; then
    echo ""
    echo "[!] Stage sources disagree:"
    echo "      project.yaml  project.stage : $STAGE_YAML   (authoritative)"
    echo "      production/stage.txt        : $STAGE_TXT   (legacy mirror)"
    echo "    Twelve consumers read the mirror, so part of the system is acting on"
    echo "    each value. Only /gate-check on a PASS should change a stage — do not"
    echo "    hand-edit either file to silence this."
fi

# Current sprint (find most recent sprint file)
LATEST_SPRINT=$(ls -t production/sprints/sprint-*.md 2>/dev/null | head -1)
if [ -n "$LATEST_SPRINT" ]; then
    echo ""
    echo "Active sprint: $(basename "$LATEST_SPRINT" .md)"
fi

# Current milestone
LATEST_MILESTONE=$(ls -t production/milestones/*.md 2>/dev/null | head -1)
if [ -n "$LATEST_MILESTONE" ]; then
    echo "Active milestone: $(basename "$LATEST_MILESTONE" .md)"
fi

# Open bug count
BUG_COUNT=0
for dir in tests/playtest production; do
    if [ -d "$dir" ]; then
        count=$(find "$dir" -name "BUG-*.md" 2>/dev/null | wc -l)
        BUG_COUNT=$((BUG_COUNT + count))
    fi
done
if [ "$BUG_COUNT" -gt 0 ]; then
    echo "Open bugs: $BUG_COUNT"
fi

# Code health quick check.
#
# Reads the ENGINE-SPECIFIC code root, not a literal `src/`. Hardcoding `src/`
# made this line Godot-only: on a Unity or Unreal project the directory test
# failed, the banner printed no code-health line at all, and a clean project and
# an unreadable one looked identical. See resolve_code_root in yaml-helper.sh.
#
# Sourcing here is defensive: the two source sites above are both conditional,
# so by this point the function may or may not exist.
if [ -f "$_CCGS_HOOK_DIR/yaml-helper.sh" ] && ! command -v resolve_code_root >/dev/null 2>&1; then
    . "$_CCGS_HOOK_DIR/yaml-helper.sh" 2>/dev/null
fi
if command -v resolve_code_root >/dev/null 2>&1; then
    CODE_ROOT=$(resolve_code_root 2>/dev/null | cut -f1)
else
    CODE_ROOT=""
fi
if [ -n "$CODE_ROOT" ] && [ -d "$CODE_ROOT" ]; then
    TODO_COUNT=$(grep -r "TODO" "$CODE_ROOT/" 2>/dev/null | wc -l)
    FIXME_COUNT=$(grep -r "FIXME" "$CODE_ROOT/" 2>/dev/null | wc -l)
    if [ "$TODO_COUNT" -gt 0 ] || [ "$FIXME_COUNT" -gt 0 ]; then
        echo ""
        echo "Code health: ${TODO_COUNT} TODOs, ${FIXME_COUNT} FIXMEs in ${CODE_ROOT}/"
    fi
fi

# --- Active session state recovery ---
# Only THIS block is gated by features.session_state, not the whole hook: the
# sprint/milestone/git context above is not part of the session-state pipeline
# and a user who turns that pipeline off still wants it. Gating the whole hook
# (as the original spec's "exit early at the top" wording implies) would take
# the branch and stage context away with it.
#
# Fail OPEN: this hook only sources yaml-helper.sh conditionally, so
# session_state_enabled may be undefined. An undefined function is falsey, which
# would silently suppress the recovery checkpoint -- the one piece of output
# whose absence the user cannot notice. Show the state unless we positively
# determined the flag is off.
STATE_FILE="production/session-state/active.md"
if [ -f "$_CCGS_HOOK_DIR/yaml-helper.sh" ] && ! command -v session_state_enabled >/dev/null 2>&1; then
    . "$_CCGS_HOOK_DIR/yaml-helper.sh"
fi
if command -v ccgs_session_state_path_present >/dev/null 2>&1 \
    && ccgs_session_state_path_present "$CCGS_ROOT" \
    && { ! command -v session_state_enabled >/dev/null 2>&1 || session_state_enabled; }; then
    if STATE_CONTENT=$(ccgs_read_session_state "$CCGS_ROOT"); then
        echo ""
        echo "=== ACTIVE SESSION STATE DETECTED ==="
        echo "A validated checkpoint snapshot was loaded from: $STATE_FILE"
        echo ""
    # The CHECKPOINT region -- the same region pre-compact.sh injects.
    #
    # Previewing `tail -20` here while pre-compact takes `head -100` would put two
    # consumers on opposite ends of one file, so which slice you got would
    # depend on which hook happened to fire. Neither was wrong, because
    # nothing defined where the recoverable state lived. The schema in
    # .claude/docs/templates/session-state.md defines it; both read it now.
        CHECKPOINT=$(printf '%s\n' "$STATE_CONTENT" \
                     | sed -n '/<!-- CHECKPOINT -->/,/<!-- \/CHECKPOINT -->/p' \
                     | grep -v '<!-- /\?CHECKPOINT -->')
        TOTAL_LINES=$(printf '%s' "$STATE_CONTENT" | awk 'END { print NR }')
    # A sed range whose END address never matches runs to EOF. So a file with an
    # opening marker and NO closing one produced a non-empty capture of the whole
    # remaining file and took the healthy branch below -- silently previewing
    # narrative under a "Checkpoint:" heading, with no warning and no template
    # named. Emptiness cannot distinguish "no block" from
    # "unterminated block"; only the markers can, so test them directly.
    # rotate-session-state.sh already checks the CLOSING marker and refuses.
    # Two consumers of one region must agree on what malformed means.
    # `<!-- CHECKPOINT -->` cannot match `<!-- /CHECKPOINT -->` -- the slash sits
    # where the space would be -- so these two counts are independent.
        CP_OPEN=$(printf '%s\n' "$STATE_CONTENT" | grep -c '<!-- CHECKPOINT -->' | tr -d ' ')
        CP_CLOSE=$(printf '%s\n' "$STATE_CONTENT" | grep -c '<!-- /CHECKPOINT -->' | tr -d ' ')
        if [ "${CP_OPEN:-0}" -gt 0 ] && [ "${CP_CLOSE:-0}" -eq 0 ]; then
            echo "  [!] CHECKPOINT block is not terminated — no <!-- /CHECKPOINT --> marker."
            echo "      Not previewing it: without the closing marker the checkpoint"
            echo "      cannot be told from the narrative, and everything to the end"
            echo "      of the file would be shown as if it were recoverable state."
            echo "      Re-create from .claude/docs/templates/session-state.md."
            echo "  ... ($TOTAL_LINES lines in the validated snapshot)"
        elif [ -n "$CHECKPOINT" ]; then
            echo "Checkpoint:"
            printf '%s\n' "$CHECKPOINT"
            echo "  ... ($TOTAL_LINES lines in the validated snapshot)"
        else
            echo "Quick summary (first 20 lines — no CHECKPOINT block in this file):"
            printf '%s\n' "$STATE_CONTENT" | head -20
            echo "  ... ($TOTAL_LINES lines in the validated snapshot)"
            echo "  NOTE: re-create from .claude/docs/templates/session-state.md so"
            echo "        recovery reads a bounded checkpoint instead of a slice."
        fi
    # Rotation is an OBSERVATION, never an action: helpers in .claude/scripts/
    # emit observations, never verdicts (CLAUDE.md). The user decides.
        if [ "${TOTAL_LINES:-0}" -gt 200 ] 2>/dev/null; then
            echo "  Note: $TOTAL_LINES lines. Narrative can be rotated into"
            echo "        production/session-logs/ — bash .claude/scripts/rotate-session-state.sh"
        fi
        echo "=== END SESSION STATE PREVIEW ==="
    else
        echo ""
        echo "[!] Session state exists but failed security validation; automatic recovery skipped."
    fi
fi

# --- engine reference vs configured engine -----------------------------------
# /setup-engine is the only thing that rewrites CLAUDE.md's ENGINE-REFERENCE-IMPORT
# line. Edit engine.name in project.yaml by hand and the import keeps loading the
# previous engine's reference as project instructions -- every session, silently.
# An OBSERVATION, never an action (CLAUDE.md): it reports, the user decides.
if [ -f project.yaml ] && [ -f CLAUDE.md ]; then
    ERI=$(grep -m1 -E '^@docs/engine-reference/[a-z]+/VERSION\.md' CLAUDE.md 2>/dev/null \
          | sed -n 's|^@docs/engine-reference/\([a-z]*\)/VERSION\.md.*|\1|p')
    CFG=$(sed -n 's/^[[:space:]]*name:[[:space:]]*"\{0,1\}\([A-Za-z]*\)"\{0,1\}[[:space:]]*$/\1/p' \
          project.yaml 2>/dev/null | head -1 | tr '[:upper:]' '[:lower:]')
    if [ -n "$ERI" ] && [ -n "$CFG" ] && [ "$ERI" != "$CFG" ]; then
        echo ""
        echo "!! ENGINE REFERENCE MISMATCH"
        echo "   project.yaml engine.name : $CFG"
        echo "   CLAUDE.md imports        : docs/engine-reference/$ERI/VERSION.md"
        echo "   Every session is loading the $ERI reference on a $CFG project."
        echo "   Fix: re-run /setup-engine, or edit the ENGINE-REFERENCE-IMPORT line."
    fi
fi

echo "==================================="
exit 0
