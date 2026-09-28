#!/usr/bin/env bash
set -u

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "$3" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "$3" ;; *) ;; esac; }

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/ccgs-security-config.XXXXXX") || exit 1
project="$test_root/project"
cleanup() { rm -rf -- "$test_root"; }
trap cleanup EXIT

test_python=""
for candidate in python python3 py; do
  if command -v "$candidate" >/dev/null 2>&1 \
      && "$candidate" -I -c 'import sys; raise SystemExit(0 if sys.version_info[0] >= 3 else 1)' >/dev/null 2>&1; then
    test_python=$(command -v "$candidate")
    break
  fi
done
[ -n "$test_python" ] || fail "Python 3 isolated mode is required"

mkdir -p "$project"
cp -R "$repo_root/.claude" "$project/.claude"
git -C "$project" init -q || fail "could not initialize fixture repository"
git -C "$project" config user.name "CCGS Security Test"
git -C "$project" config user.email "security-test@example.invalid"

# F4: committed settings may tighten the safety floor but cannot loosen it.
cat > "$project/project.yaml" <<'YAML'
schema_version: 1
modes:
  automation: autonomous
  review_mode: solo
  rigor: minimal
  workflow: minimal
qa:
  level: minimal
testing:
  strict:
    logic: false
performance:
  enforce: off
YAML
resolved=$(
  cd "$project" || exit 1
  . .claude/hooks/yaml-helper.sh
  for key in modes.automation modes.review_mode modes.rigor modes.workflow qa.level testing.strict.logic performance.enforce; do
    value=$(resolve_setting "$key")
    printf '%s=%s\n' "$key" "${value%%$(printf '\t')*}"
  done
  config_security_notices
) || fail "committed policy resolution failed"
assert_contains "$resolved" "modes.automation=collaborative" "committed automation loosening won"
assert_contains "$resolved" "modes.review_mode=lean" "committed review loosening won"
assert_contains "$resolved" "modes.rigor=standard" "committed rigor loosening won"
assert_contains "$resolved" "modes.workflow=standard" "committed workflow loosening won"
assert_contains "$resolved" "qa.level=standard" "committed QA loosening won"
assert_contains "$resolved" "testing.strict.logic=" "committed strictness loosening won"
assert_contains "$resolved" "performance.enforce=warn" "committed performance loosening won"
assert_contains "$resolved" "Ignored project.yaml modes.automation=autonomous" "ignored loosening was not reported"

cat > "$project/project.local.yaml" <<'YAML'
modes:
  automation: autonomous
  rigor: minimal
testing:
  strict:
    logic: false
performance:
  enforce: off
YAML
local_values=$(
  cd "$project" || exit 1
  . .claude/hooks/yaml-helper.sh
  for key in modes.automation modes.rigor modes.workflow modes.review_mode docs.density modes.story_granularity qa.level team.size testing.strict.logic performance.enforce; do
    value=$(resolve_setting "$key")
    printf '%s=%s\n' "$key" "${value%%$(printf '\t')*}"
  done
) || fail "local policy resolution failed"
assert_contains "$local_values" "modes.automation=autonomous" "local automation override was ignored"
assert_contains "$local_values" "modes.rigor=minimal" "local rigor override was ignored"
assert_contains "$local_values" "modes.workflow=minimal" "local rigor did not derive minimal workflow"
assert_contains "$local_values" "modes.review_mode=solo" "local rigor did not derive solo review"
assert_contains "$local_values" "docs.density=terse" "local rigor did not derive terse docs"
assert_contains "$local_values" "modes.story_granularity=coarse" "local rigor did not derive coarse stories"
assert_contains "$local_values" "qa.level=minimal" "local rigor did not derive minimal QA"
assert_contains "$local_values" "team.size=individual" "local rigor did not derive individual team size"
assert_contains "$local_values" "testing.strict.logic=false" "local strictness override was ignored"
assert_contains "$local_values" "performance.enforce=off" "local performance override was ignored"

rm -f "$project/project.local.yaml"
cat > "$project/project.yaml" <<'YAML'
schema_version: 1
testing:
  strict: false
YAML
strict_parent=$(
  cd "$project" || exit 1
  . .claude/hooks/yaml-helper.sh
  resolve_config --keys testing.strict
)
assert_contains "$strict_parent" "logic=unset" "committed scalar testing.strict=false bypassed the safety floor"
assert_not_contains "$strict_parent" "logic=false" "committed scalar testing.strict=false reached resolved output"

printf '%s\n' solo > "$project/production-review-mode.txt"
mkdir -p "$project/production"
mv "$project/production-review-mode.txt" "$project/production/review-mode.txt"
cat > "$project/project.yaml" <<'YAML'
schema_version: 1
YAML
legacy_review=$(
  cd "$project" || exit 1
  . .claude/hooks/yaml-helper.sh
  resolve_setting modes.review_mode
)
assert_contains "$legacy_review" "lean" "legacy review mirror beat an existing project.yaml"

# F8a: a long malformed line must not consume the hook timeout budget.
"$test_python" -I - "$project" <<'PY' || fail "bounded YAML parser timed out"
from pathlib import Path
import os
import subprocess
import sys

root = Path(sys.argv[1])
(root / "project.yaml").write_text("k" + " " * 50000 + "v\n", encoding="utf-8")
subprocess.run(
    ["bash", "-c", ". .claude/hooks/yaml-helper.sh; resolve_setting modes.workflow >/dev/null"],
    cwd=str(root), check=True, timeout=2,
    env=dict(os.environ, CLAUDE_PROJECT_DIR=str(root)),
)
PY

# F7: project command approval cannot authorize inline interpreter code.
for profile in \
  '["sh", "-c", "echo unsafe"]' \
  '["bash", "-lc", "echo unsafe"]' \
  '["env", "X=1", "python3", "-cprint(1)"]' \
  '["node", "--eval=console.log(1)"]' \
  '["cmd", "/ccalc"]'; do
  printf 'commands:\n  test: %s\n' "$profile" > "$project/project.yaml"
  if (cd "$project" && "$test_python" -I .claude/scripts/run-project-command.py inspect test >/dev/null 2>&1); then
    fail "inline project command was accepted: $profile"
  fi
done

probe="$project/ccgs-relative-probe"
printf '#!/bin/sh\nexit 0\n' > "$probe"
chmod +x "$probe"
printf 'commands:\n  test: ["ccgs-relative-probe"]\n' > "$project/project.yaml"
if (cd "$project" && PATH=".:relative" "$test_python" -I .claude/scripts/run-project-command.py inspect test >/dev/null 2>&1); then
  fail "relative or empty PATH entry resolved a project executable"
fi
printf 'commands:\n  test: ["env", "PATH=.", "ccgs-relative-probe"]\n' > "$project/project.yaml"
if (cd "$project" && "$test_python" -I .claude/scripts/run-project-command.py inspect test >/dev/null 2>&1); then
  fail "env wrapper hid a project-local executable from approval"
fi

# F9: maintenance scripts must use the authenticated writer for every target.
grep -F 'ccgs_safe_replace "$PY"' "$repo_root/.claude/scripts/migrate-v1-config.sh" >/dev/null \
  || fail "migration project.yaml write bypasses secure-file"
grep -F 'ccgs_safe_replace "$REPORT"' "$repo_root/.claude/scripts/migrate-v1-config.sh" >/dev/null \
  || fail "migration report write bypasses secure-file"
grep -F 'ccgs_safe_append "$ARCHIVE"' "$repo_root/.claude/scripts/rotate-session-state.sh" >/dev/null \
  || fail "session archive append bypasses secure-file"
grep -F 'ccgs_safe_delete "$f"' "$repo_root/.claude/scripts/migrate-v1-config.sh" >/dev/null \
  || fail "migration legacy deletion bypasses secure-file"

outside="$test_root/outside"
printf 'preserve\n' > "$outside"
mkdir -p "$project/production"
printf 'Concept\n' > "$project/production/stage.txt"
rm -f "$project/project.yaml"
if ln -s "$outside" "$project/project.yaml" 2>/dev/null; then
  if (cd "$project" && bash .claude/scripts/migrate-v1-config.sh >/dev/null 2>&1); then
    fail "migration accepted a symlinked project.yaml"
  fi
  [ "$(cat "$outside")" = "preserve" ] || fail "migration overwrote a symlink target"
  rm -f "$project/project.yaml"
fi

linked_project="$test_root/linked-project"
outside_production="$test_root/outside-production"
mkdir -p "$linked_project" "$outside_production"
cp -R "$repo_root/.claude" "$linked_project/.claude"
printf 'Concept\n' > "$outside_production/stage.txt"
printf 'lean\n' > "$outside_production/review-mode.txt"
cat > "$linked_project/project.yaml" <<'YAML'
schema_version: 1
project:
  stage: Concept
modes:
  review_mode: lean
YAML
if ln -s "$outside_production" "$linked_project/production" 2>/dev/null; then
  if (cd "$linked_project" && bash .claude/scripts/migrate-v1-config.sh --finalize >/dev/null 2>&1); then
    fail "migration finalized through a linked production directory"
  fi
  [ -f "$outside_production/stage.txt" ] || fail "migration deleted external stage through a linked parent"
  [ -f "$outside_production/review-mode.txt" ] || fail "migration deleted external review mode through a linked parent"
fi

# F12: every non-staged commit creator asks, and case variants are validated.
for subcommand in merge cherry-pick revert am rebase commit-tree update-ref; do
  payload=$(printf '{"tool_input":{"command":"git %s placeholder"}}' "$subcommand")
  if printf '%s\n' "$payload" | "$test_python" -I "$project/.claude/hooks/git-command-security.py" commit "$project" >/dev/null 2>&1; then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -eq 3 ] || fail "git $subcommand was not classified as an ask-only commit creator (rc=$rc)"
done

mkdir -p "$project/Assets/Data"
printf '{ invalid json\n' > "$project/Assets/Data/bad.json"
printf 'schema_version: 1\nengine:\n  name: Unity\n' > "$project/project.yaml"
git -C "$project" add -- project.yaml Assets/Data/bad.json
if "$test_python" -I "$project/.claude/hooks/validate-staged.py" "$project" standard Assets >/dev/null 2>&1; then
  fail "case-variant Assets/Data invalid JSON skipped staged validation"
fi

# F16: free-text output is typed, local engine overrides are ignored, and
# project-coherence does not expand find output into grep arguments.
cat > "$project/project.yaml" <<'YAML'
schema_version: 1
engine:
  name: Godot
  version: "bad/version"
platform:
  cert_tier: root
workflow_overrides:
  system_overrides:
    invalid-key: chaotic
YAML
cat > "$project/project.local.yaml" <<'YAML'
engine:
  name: Unity
testing:
  strict: maybe
YAML
typed=$(
  cd "$project" || exit 1
  . .claude/hooks/yaml-helper.sh
  resolve_config --keys engine,platform.cert_tier,system_overrides
  validate_yaml_enum "$project/project.local.yaml" 2>&1 || true
)
assert_contains "$typed" "engine: Godot (project.yaml)" "engine version validation did not drop unsafe text"
assert_not_contains "$typed" "platform.cert_tier: root" "invalid certification tier reached resolved output"
assert_contains "$typed" "system_overrides: none" "invalid system override reached resolved output"
assert_contains "$typed" "testing.strict" "testing.strict scalar skipped enum validation"
cat > "$project/project.local.yaml" <<'YAML'
testing:
  strict:
    logic: maybe
YAML
cat >> "$project/project.yaml" <<'YAML'
testing:
  strict:
    logic: true
YAML
strict_leaf=$(
  cd "$project" || exit 1
  . .claude/hooks/yaml-helper.sh
  resolve_config --keys testing.strict
)
assert_contains "$strict_leaf" "logic=true" "invalid local strictness did not fall through to committed true"
assert_not_contains "$strict_leaf" "logic=maybe" "invalid local strictness reached resolved output"
if grep -E 'for .*\$\(|grep .*[`$]\(find' "$repo_root/.claude/scripts/project-coherence.sh" >/dev/null; then
  fail "project-coherence still expands find output into a command"
fi

echo "PASS: security regression config and command layer"
