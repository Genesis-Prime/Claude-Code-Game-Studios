#!/usr/bin/env bash

# Resolve every executable and data path from this status line's repository.
_CCGS_CLAUDE_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"
[ -n "$_CCGS_CLAUDE_DIR" ] || exit 0
. "$_CCGS_CLAUDE_DIR/hooks/trusted-root.sh" 2>/dev/null || exit 0
ccgs_bootstrap_trusted_root "$_CCGS_CLAUDE_DIR/.." || exit 0
. "$_CCGS_CLAUDE_DIR/hooks/path-security.sh" 2>/dev/null || exit 0

# Claude Code Game Studios — Status Line
# Receives JSON on stdin, outputs a single-line status.
#
# Segments: ctx% | model | production stage [| Epic > Feature > Task]

input=$(cat)

# --- Parse JSON (jq with grep fallback) ---
if command -v jq &>/dev/null; then
  model=$(echo "$input" | jq -r '.model.display_name // "Unknown"')
  used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
  event_cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
else
  model=$(echo "$input" | grep -oE '"display_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*: *"//;s/"//')
  used_pct=$(echo "$input" | grep -oE '"used_percentage"[[:space:]]*:[[:space:]]*[0-9]+' | head -1 | sed 's/.*: *//')
  event_cwd=$(echo "$input" | grep -oE '"current_dir"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*: *"//;s/"//')
  [ -z "$model" ] && model="Unknown"
fi
model=$(printf '%s' "${model:-Unknown}" | ccgs_sanitize_text 80)
case "${used_pct:-}" in
  ''|*[!0-9]*) used_pct="" ;;
  *) [ "$used_pct" -le 100 ] 2>/dev/null || used_pct="" ;;
esac

# Event cwd is presentation data only. It never selects code, configuration,
# or state. All reads below stay under the authenticated script root.
event_cwd=$(echo "$event_cwd" | sed 's|\\|/|g')
cwd="$CCGS_ROOT"

# --- Context usage ---
if [ -n "$used_pct" ]; then
  ctx_label="ctx: ${used_pct}%"
else
  ctx_label="ctx: --"
fi

# --- Production stage ---
# Priority 1: project.stage from project.yaml
stage=""
project_yaml="$cwd/project.yaml"
yaml_helper="$_CCGS_CLAUDE_DIR/hooks/yaml-helper.sh"
if [ -f "$project_yaml" ] && [ -f "$yaml_helper" ]; then
  source "$yaml_helper"
  stage=$(get_yaml_key "$project_yaml" project.stage 2>/dev/null)
fi
# Priority 2: legacy stage.txt fallback
if [ -z "$stage" ]; then
  stage=$(ccgs_safe_read "production/stage.txt" "$cwd" 2>/dev/null \
      | sed -n '1p' | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
fi
if [ -n "$stage" ] && command -v validate_enum_value >/dev/null 2>&1 \
    && ! validate_enum_value project.stage "$stage" 2>/dev/null; then
  stage=""
fi
stage=$(printf '%s' "$stage" | ccgs_sanitize_text 40)

# Priority 3: Auto-detect from artifacts
if [ -z "$stage" ]; then
  concept_file="$cwd/design/gdd/game-concept.md"
  systems_file="$cwd/design/gdd/systems-index.md"
  tech_prefs="$cwd/.claude/docs/technical-preferences.md"

  has_concept=false
  has_systems=false
  engine_configured=false
  src_count=0

  [ -f "$concept_file" ] && has_concept=true
  [ -f "$systems_file" ] && has_systems=true

  # Check if engine is configured (project.yaml first, fall back to technical-preferences.md)
  if [ -f "$project_yaml" ] && [ -f "$yaml_helper" ]; then
    # yaml-helper may have been sourced above for stage; sourcing again is idempotent
    source "$yaml_helper"
    engine_name=$(get_yaml_key "$project_yaml" engine.name 2>/dev/null)
    [ -n "$engine_name" ] && engine_configured=true
  fi
  if [ "$engine_configured" = false ] && [ -f "$tech_prefs" ]; then
    # Leading whitespace tolerated, matching detect-gaps.sh and the migrator.
    # This is the THIRD copy of "is the engine configured in
    # technical-preferences.md" in the tree, and it was the last one still
    # anchored to column 0 -- an indented bullet read as unconfigured here while
    # the other two read it as configured, so the auto-detect ladder below
    # dropped the project to an earlier stage than the rest of the system saw.
    engine_line=$(grep -m1 -E '^[[:space:]]*-[[:space:]]+\*\*Engine\*\*:' "$tech_prefs" 2>/dev/null || true)
    if [ -n "$engine_line" ] && ! echo "$engine_line" | grep -q "TO BE CONFIGURED"; then
      engine_configured=true
    fi
  fi

  # Count source files (language-agnostic)
  if [ -d "$cwd/src" ]; then
    src_count=$(find "$cwd/src" -type f \( -name "*.gd" -o -name "*.cs" -o -name "*.cpp" -o -name "*.h" -o -name "*.py" -o -name "*.rs" -o -name "*.lua" -o -name "*.tscn" -o -name "*.tres" \) 2>/dev/null | wc -l | tr -d ' ')
  fi

  # Check for ADRs (signals Pre-Production phase)
  has_adrs=false
  if ls "$cwd/docs/architecture/"adr-*.md 2>/dev/null | head -1 | grep -q .; then
    has_adrs=true
  fi

  # Determine stage (check from most-advanced backward)
  if [ "$src_count" -ge 10 ] 2>/dev/null; then
    stage="Production"
  elif [ "$has_adrs" = true ]; then
    stage="Pre-Production"
  elif [ "$engine_configured" = true ]; then
    stage="Technical Setup"
  elif [ "$has_systems" = true ]; then
    stage="Systems Design"
  elif [ "$has_concept" = true ]; then
    stage="Concept"
  else
    stage="Concept"
  fi
fi
# --- Process posture (modes.rigor) ---
# Use the same root-anchored resolution policy as skills and SessionStart.
rigor=""
if [ -f "$project_yaml" ] && [ -f "$yaml_helper" ]; then
  source "$yaml_helper"
  rigor=$(resolve_setting modes.rigor 2>/dev/null | cut -f1)
fi
if [ -n "$rigor" ] && ! validate_enum_value modes.rigor "$rigor" 2>/dev/null; then
  rigor=""
fi
rigor=$(printf '%s' "$rigor" | ccgs_sanitize_text 20)

# --- Epic/Feature/Task breadcrumb (Production+ only) ---
breadcrumb=""
if [ "$stage" = "Production" ] || [ "$stage" = "Polish" ] || [ "$stage" = "Release" ]; then
  if command -v ccgs_session_state_path_present >/dev/null 2>&1 \
      && ccgs_session_state_path_present "$cwd" \
      && state_content=$(ccgs_read_session_state "$cwd" 2>/dev/null); then
    # Parse structured STATUS block
    in_block=false
    epic="" feature="" task=""
    while IFS= read -r line; do
      case "$line" in
        *"<!-- STATUS -->"*) in_block=true; continue ;;
        *"<!-- /STATUS -->"*) break ;;
      esac
      if [ "$in_block" = true ]; then
        case "$line" in
          Epic:*) epic=$(echo "$line" | sed 's/^Epic: *//' | ccgs_sanitize_text 80) ;;
          Feature:*) feature=$(echo "$line" | sed 's/^Feature: *//' | ccgs_sanitize_text 80) ;;
          Task:*) task=$(echo "$line" | sed 's/^Task: *//' | ccgs_sanitize_text 80) ;;
        esac
      fi
    done < <(printf '%s\n' "$state_content")

    # Build breadcrumb from whatever is set
    parts=""
    [ -n "$epic" ] && parts="$epic"
    [ -n "$feature" ] && parts="${parts:+$parts > }$feature"
    [ -n "$task" ] && parts="${parts:+$parts > }$task"
    [ -n "$parts" ] && breadcrumb=" | $parts"
  fi
fi

# --- Assemble ---
printf "%s" "${ctx_label} | ${model} | ${stage}${rigor:+ · $rigor}${breadcrumb}"
