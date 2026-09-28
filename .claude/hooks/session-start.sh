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
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null | ccgs_sanitize_text 120)
if [ -n "$BRANCH" ]; then
    echo "Branch: $BRANCH"

    # Recent commits
    echo ""
    echo "Recent commits:"
    git log --oneline -5 2>/dev/null | while read -r line; do
        line=$(printf '%s' "$line" | ccgs_sanitize_text 240)
        echo "  $line"
    done
fi

# Resolve review_mode the same way skills do: resolve_setting applies the full
# chain (project.local.yaml -> allowed project.yaml value -> modes.rigor
# expansion -> default). The legacy mirror is consulted only when project.yaml
# does not exist. modes.review_mode is rigor-fronted and locally overridable,
# so only resolve_setting reflects both a rigor-derived value (a project that set
# only `rigor: minimal` shows `solo`) and a local override. get_effective_yaml_key
# returns empty for a rigor-only project, which would leave the banner showing a
# stale `lean`.
REVIEW_MODE=""
if [ -f "$_CCGS_HOOK_DIR/yaml-helper.sh" ]; then
    source "$_CCGS_HOOK_DIR/yaml-helper.sh"
fi
if [ -f "$CCGS_ROOT/project.yaml" ] && command -v resolve_setting >/dev/null 2>&1; then
    REVIEW_MODE=$(resolve_setting modes.review_mode 2>/dev/null | cut -f1)
elif [ ! -f "$CCGS_ROOT/project.yaml" ]; then
    if [ -e "production/review-mode.txt" ] || [ -L "production/review-mode.txt" ]; then
        if _REVIEW_RAW=$(ccgs_safe_read "production/review-mode.txt" "$CCGS_ROOT" 2>/dev/null); then
            REVIEW_MODE=$(printf '%s\n' "$_REVIEW_RAW" | sed -n '1p' | tr -d '\r' \
                | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        else
            echo "[!] Ignored linked, redirected, or non-regular production/review-mode.txt."
        fi
    fi
fi
if [ -n "$REVIEW_MODE" ]; then
    if command -v validate_enum_value >/dev/null 2>&1; then
        validate_enum_value modes.review_mode "$REVIEW_MODE" >/dev/null 2>&1 || REVIEW_MODE=""
    else
        case "$REVIEW_MODE" in solo|lean|full) : ;; *) REVIEW_MODE="" ;; esac
    fi
fi
if [ -z "$REVIEW_MODE" ]; then
    REVIEW_MODE="lean"
fi
REVIEW_MODE=$(printf '%s' "$REVIEW_MODE" | ccgs_sanitize_text 40)
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
        BASE_ERR=$(printf '%s' "$BASE_ERR" | ccgs_sanitize_text 500)
        echo ""
        echo "[!] $BASE_ERR"
    fi
    if [ -f "project.yaml" ]; then
        SCHEMA_ERRORS=$(validate_yaml_enum "$CCGS_ROOT/project.yaml" 2>&1)
        if [ -n "$SCHEMA_ERRORS" ]; then
            SCHEMA_ERRORS=$(printf '%s' "$SCHEMA_ERRORS" | ccgs_sanitize_multiline 4000)
            echo ""
            echo "[!] project.yaml schema errors:"
            echo "$SCHEMA_ERRORS" | sed 's/^/    /'
        fi
    fi
    if [ -f "project.local.yaml" ]; then
        SCHEMA_ERRORS=$(validate_yaml_enum "$CCGS_ROOT/project.local.yaml" 2>&1)
        if [ -n "$SCHEMA_ERRORS" ]; then
            SCHEMA_ERRORS=$(printf '%s' "$SCHEMA_ERRORS" | ccgs_sanitize_multiline 4000)
            echo ""
            echo "[!] project.local.yaml schema errors:"
            echo "$SCHEMA_ERRORS" | sed 's/^/    /'
        fi
    fi
    SECURITY_NOTICES=$(config_security_notices 2>/dev/null)
    if [ -n "$SECURITY_NOTICES" ]; then
        echo ""
        printf '%s\n' "$SECURITY_NOTICES" | while IFS= read -r notice; do
            notice=$(printf '%s' "$notice" | ccgs_sanitize_text 300)
            [ -n "$notice" ] && echo "[!] $notice"
        done
    fi
fi

# Recovery notes are emitted before filesystem scans so a slow or hostile code
# tree cannot consume the hook budget before the checkpoint reaches context.
if command -v session_state_enabled >/dev/null 2>&1 && session_state_enabled \
    && ccgs_session_state_path_present "$CCGS_ROOT"; then
    echo ""
    if ccgs_emit_checkpoint "$CCGS_ROOT"; then
        :
    else
        _checkpoint_rc=$?
        [ "$_checkpoint_rc" -eq 2 ] \
            || echo "[!] Session state failed security validation; automatic recovery skipped."
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
if [ -f "$CCGS_ROOT/project.yaml" ] && command -v get_yaml_key >/dev/null 2>&1; then
    STAGE_YAML=$(get_yaml_key "$CCGS_ROOT/project.yaml" project.stage 2>/dev/null)
fi
if [ -e "production/stage.txt" ] || [ -L "production/stage.txt" ]; then
    if _STAGE_RAW=$(ccgs_safe_read "production/stage.txt" "$CCGS_ROOT" 2>/dev/null); then
        STAGE_TXT=$(printf '%s\n' "$_STAGE_RAW" | sed -n '1p' | tr -d '\r' \
            | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    else
        echo "[!] Ignored linked, redirected, or non-regular production/stage.txt."
    fi
fi
if [ -n "$STAGE_TXT" ] && ! validate_enum_value project.stage "$STAGE_TXT" 2>/dev/null; then
    echo "[!] Ignored invalid or unsafe production/stage.txt value."
    STAGE_TXT=""
fi
STAGE_YAML=$(printf '%s' "$STAGE_YAML" | ccgs_sanitize_text 40)
STAGE_TXT=$(printf '%s' "$STAGE_TXT" | ccgs_sanitize_text 40)
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
    SPRINT_NAME=$(basename "$LATEST_SPRINT" .md | ccgs_sanitize_text 120)
    echo "Active sprint: $SPRINT_NAME"
fi

# Current milestone
LATEST_MILESTONE=$(ls -t production/milestones/*.md 2>/dev/null | head -1)
if [ -n "$LATEST_MILESTONE" ]; then
    MILESTONE_NAME=$(basename "$LATEST_MILESTONE" .md | ccgs_sanitize_text 120)
    echo "Active milestone: $MILESTONE_NAME"
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
if [ -n "$CODE_ROOT" ] && [ -L "$CCGS_ROOT/$CODE_ROOT" ]; then
    echo "[!] Code health scan skipped: $CODE_ROOT is a symbolic link."
elif [ -n "$CODE_ROOT" ] && [ -d "$CCGS_ROOT/$CODE_ROOT" ]; then
    if ccgs_resolve_state_python; then
      HEALTH=$("$_ccgs_state_python" -I - "$CCGS_ROOT/$CODE_ROOT" <<'PY' 2>/dev/null
import os
import stat
import sys

root = sys.argv[1]
todo = fixme = files = total = 0
truncated = False
for current, dirs, names in os.walk(root, followlinks=False):
    dirs[:] = [name for name in dirs if not os.path.islink(os.path.join(current, name))]
    for name in names:
        if files >= 2000 or total >= 8 * 1024 * 1024:
            truncated = True
            break
        path = os.path.join(current, name)
        try:
            info = os.lstat(path)
            if not stat.S_ISREG(info.st_mode) or info.st_size > 1024 * 1024:
                continue
            with open(path, "rb") as handle:
                data = handle.read(min(info.st_size, 1024 * 1024))
        except OSError:
            continue
        files += 1
        total += len(data)
        todo += data.count(b"TODO")
        fixme += data.count(b"FIXME")
    if truncated:
        break
print("%d\t%d\t%d" % (todo, fixme, 1 if truncated else 0))
PY
)
    else
      HEALTH=$(printf '0\t0\t1')
    fi
    TODO_COUNT=$(printf '%s' "$HEALTH" | cut -f1)
    FIXME_COUNT=$(printf '%s' "$HEALTH" | cut -f2)
    HEALTH_TRUNCATED=$(printf '%s' "$HEALTH" | cut -f3)
    TODO_COUNT=${TODO_COUNT:-0}
    FIXME_COUNT=${FIXME_COUNT:-0}
    if [ "$TODO_COUNT" -gt 0 ] || [ "$FIXME_COUNT" -gt 0 ]; then
        echo ""
        SAFE_CODE_ROOT=$(printf '%s' "$CODE_ROOT" | ccgs_sanitize_text 80)
        echo "Code health: ${TODO_COUNT} TODOs, ${FIXME_COUNT} FIXMEs in ${SAFE_CODE_ROOT}/"
    fi
    [ "$HEALTH_TRUNCATED" = "1" ] && echo "[!] Code health scan stopped at its 2,000-file or 8 MiB budget."
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
