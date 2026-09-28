#!/bin/bash
# rotate-session-state.sh — move active.md's narrative into the session log,
# leaving the checkpoint behind.
#
# WHY THIS EXISTS
# active.md is two things at once: a small machine-read CHECKPOINT that hooks
# inject, and a free-form narrative for humans. Only the first is bounded by the
# schema. Left alone the second grows without limit -- it reached 712 lines /
# 44 KB before this script existed -- and every session paid to preview a file
# that was mostly history the commit log already records.
#
# Rotation keeps the checkpoint, appends the narrative to a dated file under
# production/session-logs/, and starts the Notes section fresh. Nothing is
# deleted.
#
# EXPLICIT INVOCATION ONLY. No hook calls this. session-start.sh observes that
# the file is large and names this script; the user decides whether to run it.
# Helpers here emit observations, never verdicts (CLAUDE.md) -- and silently
# moving a user's working notes would be a verdict.
#
# Usage:
#   bash .claude/scripts/rotate-session-state.sh            # rotate
#   bash .claude/scripts/rotate-session-state.sh --dry-run  # show, change nothing
#   bash .claude/scripts/rotate-session-state.sh --help

set -u
cd "$(dirname "$0")/../.." || exit 1
REPO="$PWD"
. "$REPO/.claude/hooks/path-security.sh" 2>/dev/null || {
  echo "rotate-session-state: trusted file helper is unavailable" >&2
  exit 1
}

STATE="production/session-state/active.md"
LOGDIR="production/session-logs"
DRY=0

case "${1:-}" in
  --help|-h)
    sed -n '2,30p' "$0" | sed 's/^# \?//'
    exit 0 ;;
  --dry-run) DRY=1 ;;
  "") ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac

if [ ! -f "$STATE" ]; then
  echo "no session state at $STATE — nothing to rotate"
  exit 0
fi
if ! STATE_CONTENT=$(ccgs_safe_read "$STATE" "$REPO" 2>/dev/null); then
  echo "REFUSED: $STATE is linked, redirected, non-regular, or unreadable." >&2
  exit 3
fi

if ! printf '%s\n' "$STATE_CONTENT" | grep -q '<!-- /CHECKPOINT -->'; then
  echo "REFUSED: $STATE has no <!-- /CHECKPOINT --> marker."
  echo "  Rotation splits the file at that marker, so without it this script"
  echo "  cannot tell the checkpoint from the narrative and would move both."
  echo "  Re-create the file from .claude/docs/templates/session-state.md first."
  exit 3
fi

# Everything through the marker is the checkpoint; everything after is narrative.
SPLIT=$(printf '%s\n' "$STATE_CONTENT" | grep -n '<!-- /CHECKPOINT -->' | head -1 | cut -d: -f1)
TOTAL=$(printf '%s\n' "$STATE_CONTENT" | awk 'END { print NR }')
NARRATIVE=$((TOTAL - SPLIT))

if [ "$NARRATIVE" -le 5 ]; then
  echo "narrative is $NARRATIVE lines — nothing worth rotating"
  exit 0
fi

# Date comes from the filesystem, not `date`, so a dry run and the real run
# agree and repeated runs on the same day append to one file.
STAMP=$(date +%Y-%m-%d 2>/dev/null || echo "undated")
ARCHIVE="$LOGDIR/session-state-$STAMP.md"

if [ "$DRY" = "1" ]; then
  echo "DRY RUN — no changes written"
  echo "  checkpoint kept : lines 1-$SPLIT"
  echo "  narrative moved : lines $((SPLIT + 1))-$TOTAL ($NARRATIVE lines)"
  echo "  destination     : $ARCHIVE"
  exit 0
fi

if ! {
  echo ""
  echo "---"
  echo ""
  echo "## Rotated from active.md on $STAMP ($NARRATIVE lines)"
  echo ""
  printf '%s\n' "$STATE_CONTENT" | tail -n "+$((SPLIT + 1))"
} | ccgs_safe_append "$ARCHIVE" "$REPO"; then
  echo "rotate-session-state: REFUSED — archive target is linked, redirected, or unsafe: $ARCHIVE" >&2
  exit 1
fi

if ! {
  printf '%s\n' "$STATE_CONTENT" | head -n "$SPLIT"
  echo ""
  echo "---"
  echo ""
  echo "## Notes"
  echo ""
  echo "_Narrative through $STAMP rotated to \`$ARCHIVE\`._"
  echo ""
} | ccgs_safe_replace "$STATE" "$REPO"; then
  echo "rotate-session-state: FAILED — could not safely replace $STATE" >&2
  echo "  $STATE is UNCHANGED (the narrative is now in BOTH $ARCHIVE and $STATE)." >&2
  exit 1
fi

echo "rotated $NARRATIVE lines -> $ARCHIVE"
echo "$STATE is now $(ccgs_safe_read "$STATE" "$REPO" 2>/dev/null | awk 'END { print NR }') lines"
