#!/usr/bin/env bash

set -u

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "$3" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3" ;;
    *) ;;
  esac
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/ccgs-security.XXXXXX") || exit 1
project="$test_root/project"

cleanup() {
  if [ -n "${test_root:-}" ] && [ -d "$test_root" ]; then
    rm -rf -- "$test_root"
  fi
}
trap cleanup EXIT

mkdir -p "$project"
cp -R "$repo_root/.claude" "$project/.claude"
printf '%s\n' \
  'schema_version: 1' \
  'project:' \
  '  stage: Production' \
  'features:' \
  '  session_state: true' > "$project/project.yaml"

git -C "$project" init -q || fail "temporary Git repository could not be initialized"
git -C "$project" config user.name "CCGS Security Test"
git -C "$project" config user.email "security-test@example.invalid"

test_python=""
for candidate in python python3 py; do
  if command -v "$candidate" >/dev/null 2>&1 \
      && "$candidate" -I -c 'import sys; raise SystemExit(0 if sys.version_info[0] >= 3 else 1)' >/dev/null 2>&1; then
    test_python="$candidate"
    break
  fi
done
[ -n "$test_python" ] || fail "Python 3 isolated mode is required for this regression suite"
test_os=$("$test_python" -I -c 'import os; print(os.name)') \
  || fail "could not determine the native Python platform"

# Exercise the no-descriptor platform branch on every runner. Native Windows
# reaches the same branch without simulation; POSIX runners monkeypatch only
# the feature probe so the fail-closed contract cannot silently regress.
"$test_python" -I - "$project/.claude/hooks/secure-file.py" "$test_root" <<'PY' \
  || fail "secure writer did not fail closed without handle-relative traversal"
import contextlib
import importlib.util
import io
import os
import pathlib
import sys

helper, root_arg = sys.argv[1:]
spec = importlib.util.spec_from_file_location("ccgs_secure_file_probe", helper)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
root = os.path.realpath(root_arg)
module._supports_descriptor_walk = lambda: False
saved_argv = sys.argv
sys.argv = [helper, "replace", root, "windows-fail-closed-probe.txt"]
error = io.StringIO()
try:
    with contextlib.redirect_stderr(error):
        result = module.main()
finally:
    sys.argv = saved_argv
if result != 1 or "fail-closed" not in error.getvalue():
    raise SystemExit("no-descriptor operation did not report fail-closed")
if pathlib.Path(root, "windows-fail-closed-probe.txt").exists():
    raise SystemExit("no-descriptor operation wrote a file")
PY

# Project settings must not silently authorize repository-controlled execution.
risky_permissions=$("$test_python" -I - "$repo_root/.claude/settings.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    settings = json.load(handle)
for item in settings.get("permissions", {}).get("allow", []):
    if item.startswith("Bash("):
        print(item)
PY
)
[ -z "$risky_permissions" ] || fail "committed Bash auto-allow remains: $risky_permissions"
if grep -F '"Bash(git *)"' "$repo_root/.claude/docs/settings-local-template.md" >/dev/null \
    || grep -F '"Bash(npm *)"' "$repo_root/.claude/docs/settings-local-template.md" >/dev/null; then
  fail "local settings template recommends a wildcarded execution grant"
fi

# Agent selection is checked at the tool boundary, not trusted from project YAML.
allowed_agent='{"tool_input":{"subagent_type":"qa-tester"}}'
if ! (cd "$project" && printf '%s\n' "$allowed_agent" | CLAUDE_PROJECT_DIR="$project" bash .claude/hooks/validate-agent.sh); then
  fail "reviewed agent type was rejected"
fi
unknown_agent='{"tool_input":{"subagent_type":"repo-injected-agent"}}'
if (cd "$project" && printf '%s\n' "$unknown_agent" | CLAUDE_PROJECT_DIR="$project" bash .claude/hooks/validate-agent.sh >/dev/null 2>&1); then
  fail "unreviewed agent type was accepted"
fi

# The helper root comes from the running script, never caller or event cwd.
spoof_root="$test_root/spoof-project"
mkdir -p "$spoof_root/.claude/hooks"
export CCGS_SPOOF_MARKER="$test_root/spoof-helper-executed"
printf '%s\n' '#!/bin/sh' 'touch "$CCGS_SPOOF_MARKER"' > "$spoof_root/.claude/hooks/yaml-helper.sh"
spoof_status=$(printf '{"model":{"display_name":"test"},"workspace":{"current_dir":"%s"}}\n' "$spoof_root")
if ! (cd "$spoof_root" && printf '%s\n' "$spoof_status" | CLAUDE_PROJECT_DIR="$project" bash "$project/.claude/statusline.sh" >/dev/null); then
  fail "status line failed when event cwd differed from its trusted root"
fi
[ ! -e "$CCGS_SPOOF_MARKER" ] || fail "status line sourced an event-selected helper"

if (cd "$project" && CLAUDE_PROJECT_DIR="$spoof_root" bash .claude/scripts/project-coherence.sh >/dev/null 2>&1); then
  fail "project coherence accepted an ambient root that differs from its script root"
fi

if [ "$test_os" = "nt" ]; then
  if default_writer=$(
    cd "$spoof_root" || exit 1
    unset CCGS_ROOT
    . "$project/.claude/hooks/path-security.sh"
    printf '%s\n' anchored | ccgs_safe_replace production/session-logs/default-root-probe.log 2>&1
  ); then
    fail "secure writer did not fail closed without handle-relative traversal"
  fi
  assert_contains "$default_writer" "fail-closed" "Windows secure writer did not explain its fail-closed boundary"
else
  default_writer=$(
    cd "$spoof_root" || exit 1
    unset CCGS_ROOT
    . "$project/.claude/hooks/path-security.sh"
    printf '%s\n' anchored | ccgs_safe_replace production/session-logs/default-root-probe.log
    ccgs_safe_read production/session-logs/default-root-probe.log
  ) || fail "path-security default root could not be authenticated"
  [ "$default_writer" = "anchored" ] || fail "path-security default root did not follow its own script"
fi
[ ! -e "$spoof_root/production/session-logs/default-root-probe.log" ] \
  || fail "path-security defaulted to the caller working directory"

# Safety categories are an immutable baseline and specialist values are typed.
cat >> "$project/project.yaml" <<EOF
modes:
  automation_always_ask: [unknown_only]
commands: # typed argv profiles
  test: ["$test_python", "-I", "-c", "import os; assert 'CCGS_SHOULD_NOT_LEAK' not in os.environ; open('typed-command-ran', 'w').write('ok')"]
EOF
if ! (
  cd "$project" || exit 1
  CLAUDE_PROJECT_DIR="$project"
  . .claude/hooks/yaml-helper.sh
  is_always_ask_category scope_changes \
    && is_always_ask_category command_execution \
    && ! is_always_ask_category unknown_only \
    && validate_enum_value specialists.code godot-gdscript-specialist \
    && ! validate_enum_value specialists.code repo-injected-agent >/dev/null 2>&1
); then
  fail "immutable automation defaults or specialist validation failed"
fi

# Typed command profiles do nothing during inspection, reject stale approval,
# and execute the exact approved argv without a shell.
export CCGS_SHOULD_NOT_LEAK="repository commands must not inherit this value"
CCGS_COMMAND_MARKER="$project/typed-command-ran"
command_inspection=$(cd "$project" && "$test_python" -I .claude/scripts/run-project-command.py inspect test) \
  || fail "typed command inspection failed"
[ ! -e "$CCGS_COMMAND_MARKER" ] || fail "command inspection executed the profile"
command_sha=$(printf '%s\n' "$command_inspection" | sed -n 's/^APPROVAL_SHA=//p')
[ -n "$command_sha" ] || fail "typed command inspection emitted no approval SHA"
if (cd "$project" && "$test_python" -I .claude/scripts/run-project-command.py run test --approved-sha deadbeef >/dev/null 2>&1); then
  fail "typed command runner accepted stale approval"
fi
(cd "$project" && "$test_python" -I .claude/scripts/run-project-command.py run test --approved-sha "$command_sha") \
  || fail "typed command runner rejected the exact approved argv"
[ -f "$CCGS_COMMAND_MARKER" ] || fail "typed command runner did not execute the approved argv"

# YAML parsing must not import a repository-local standard-library shadow.
export CCGS_TEST_MARKER="$test_root/re-imported"
printf '%s\n' \
  'import os' \
  'open(os.environ["CCGS_TEST_MARKER"], "w").write("executed")' > "$project/re.py"
yaml_value=$(
  cd "$project" || exit 1
  . .claude/hooks/yaml-helper.sh
  get_yaml_key project.yaml schema_version
)
[ "$yaml_value" = "1" ] || fail "isolated YAML parser returned the wrong value"
[ ! -e "$CCGS_TEST_MARKER" ] || fail "YAML parser imported repository re.py"

# The deterministic artifact scanner uses the same protected interpreter
# boundary and must not import a repository-local glob module.
export CCGS_GLOB_MARKER="$test_root/glob-imported"
printf '%s\n' \
  'import os' \
  'open(os.environ["CCGS_GLOB_MARKER"], "w").write("executed")' > "$project/glob.py"
if ! artifact_output=$(cd "$project" && bash .claude/scripts/artifact-check.sh --phase concept "$project" 2>&1); then
  fail "artifact scanner did not complete: $artifact_output"
fi
[ ! -e "$CCGS_GLOB_MARKER" ] || fail "artifact scanner imported repository glob.py"

catalog_project="$test_root/catalog-project"
mkdir -p "$catalog_project"
cp -R "$repo_root/.claude" "$catalog_project/.claude"
"$test_python" -I - "$catalog_project/.claude/docs/workflow-catalog.yaml" <<'PY'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    body = handle.read()
old = 'glob: "design/gdd/game-concept.md"'
if old not in body:
    raise SystemExit("catalog fixture target missing")
with open(path, "w", encoding="utf-8", newline="\n") as handle:
    handle.write(body.replace(old, 'glob: "../../outside.md"', 1))
PY
if catalog_escape=$(cd "$catalog_project" && bash .claude/scripts/artifact-check.sh --phase concept "$catalog_project" 2>&1); then
  fail "artifact scanner accepted a traversal glob"
fi
assert_contains "$catalog_escape" "INVALID" "artifact scanner did not identify the unsafe catalog path"

# Both JSON hooks must ignore a repository-local json package.
mkdir -p "$project/json" "$project/assets/data"
export CCGS_JSON_MARKER="$test_root/json-imported"
printf '%s\n' \
  'import os' \
  'open(os.environ["CCGS_JSON_MARKER"], "w").write("executed")' > "$project/json/__init__.py"
printf '%s\n' \
  'import os' \
  'open(os.environ["CCGS_JSON_MARKER"], "w").write("executed")' > "$project/json/tool.py"
printf '%s\n' '{"ok": true}' > "$project/assets/data/good.json"
printf '%s\n' '{not-json' > "$project/assets/data/bad.json"

good_payload='{"tool_name":"Write","tool_input":{"file_path":"assets/data/good.json"}}'
if ! good_output=$(cd "$project" && printf '%s\n' "$good_payload" | bash .claude/hooks/validate-assets.sh 2>&1); then
  fail "valid JSON was rejected: $good_output"
fi
[ ! -e "$CCGS_JSON_MARKER" ] || fail "asset hook imported repository json package"

bad_payload='{"tool_name":"Write","tool_input":{"file_path":"assets/data/bad.json"}}'
if bad_output=$(cd "$project" && printf '%s\n' "$bad_payload" | bash .claude/hooks/validate-assets.sh 2>&1); then
  bad_rc=0
else
  bad_rc=$?
fi
[ "$bad_rc" -eq 2 ] || fail "invalid JSON did not produce exit 2: $bad_output"

git -C "$project" add -- assets/data/bad.json
commit_payload='{"tool_name":"Bash","tool_input":{"command":"git commit -F .git/CCGS_COMMIT_MSG"}}'
if commit_output=$(cd "$project" && printf '%s\n' "$commit_payload" | bash .claude/hooks/validate-commit.sh 2>&1); then
  commit_rc=0
else
  commit_rc=$?
fi
[ "$commit_rc" -eq 2 ] || fail "commit hook did not block invalid staged JSON: $commit_output"
[ ! -e "$CCGS_JSON_MARKER" ] || fail "commit hook imported repository json package"

commit_wrapped='{"tool_name":"Bash","tool_input":{"command":"command env CCGS_TEST=1 git -C . commit -F .git/CCGS_COMMIT_MSG"}}'
if (cd "$project" && printf '%s\n' "$commit_wrapped" | CLAUDE_PROJECT_DIR="$project" bash .claude/hooks/validate-commit.sh >/dev/null 2>&1); then
  fail "wrapped Git commit bypassed validation"
fi
git -C "$project" config alias.ci commit
alias_commit='{"tool_name":"Bash","tool_input":{"command":"git ci -F .git/CCGS_COMMIT_MSG"}}'
if (cd "$project" && printf '%s\n' "$alias_commit" | CLAUDE_PROJECT_DIR="$project" bash .claude/hooks/validate-commit.sh >/dev/null 2>&1); then
  fail "Git commit alias bypassed validation"
fi
runtime_alias='{"tool_name":"Bash","tool_input":{"command":"git -c alias.ci=commit ci -F .git/CCGS_COMMIT_MSG"}}'
if (cd "$project" && printf '%s\n' "$runtime_alias" | CLAUDE_PROJECT_DIR="$project" bash .claude/hooks/validate-commit.sh >/dev/null 2>&1); then
  fail "runtime Git alias bypassed commit classification"
fi
config_env_alias='{"tool_name":"Bash","tool_input":{"command":"ALIAS=commit git --config-env=alias.ci=ALIAS ci --dry-run"}}'
if (cd "$project" && printf '%s\n' "$config_env_alias" | CLAUDE_PROJECT_DIR="$project" bash .claude/hooks/validate-commit.sh >/dev/null 2>&1); then
  fail "--config-env Git alias bypassed commit classification"
fi
commit_tree='{"tool_name":"Bash","tool_input":{"command":"git commit-tree HEAD^{tree}"}}'
if ! (cd "$project" && printf '%s\n' "$commit_tree" | CLAUDE_PROJECT_DIR="$project" bash .claude/hooks/validate-commit.sh >/dev/null 2>&1); then
  fail "git commit-tree was misclassified as git commit"
fi
ambiguous_commit='{"tool_name":"Bash","tool_input":{"command":"sh -c '\''git commit'\''"}}'
if (cd "$project" && printf '%s\n' "$ambiguous_commit" | CLAUDE_PROJECT_DIR="$project" bash .claude/hooks/validate-commit.sh >/dev/null 2>&1); then
  fail "ambiguous nested Git commit was allowed"
fi

# Commit and push validation must not validate one repository and then operate
# on another through shell cwd changes, Git context options, or alternate index
# environment variables.
other_repo="$test_root/other-repo"
mkdir -p "$other_repo"
git -C "$other_repo" init -q
git -C "$other_repo" config alias.ci commit
cross_cwd='{"tool_name":"Bash","tool_input":{"command":"cd ../other-repo && git commit"}}'
if (cd "$project" && printf '%s\n' "$cross_cwd" | CLAUDE_PROJECT_DIR="$project" bash .claude/hooks/validate-commit.sh >/dev/null 2>&1); then
  fail "shell cwd change redirected a validated commit to another repository"
fi
cross_context='{"tool_name":"Bash","tool_input":{"command":"git -C ../other-repo commit"}}'
if (cd "$project" && printf '%s\n' "$cross_context" | CLAUDE_PROJECT_DIR="$project" bash .claude/hooks/validate-commit.sh >/dev/null 2>&1); then
  fail "Git -C redirected a validated commit to another repository"
fi
cross_alias='{"tool_name":"Bash","tool_input":{"command":"git -C ../other-repo ci"}}'
if (cd "$project" && printf '%s\n' "$cross_alias" | CLAUDE_PROJECT_DIR="$project" bash .claude/hooks/validate-commit.sh >/dev/null 2>&1); then
  fail "alternate-repository Git alias bypassed commit classification"
fi
alternate_index='{"tool_name":"Bash","tool_input":{"command":"GIT_INDEX_FILE=.git/alternate-index git commit"}}'
if (cd "$project" && printf '%s\n' "$alternate_index" | CLAUDE_PROJECT_DIR="$project" bash .claude/hooks/validate-commit.sh >/dev/null 2>&1); then
  fail "alternate Git index bypassed commit validation"
fi
cross_status='{"tool_name":"Bash","tool_input":{"command":"git -C ../other-repo status"}}'
if ! (cd "$project" && printf '%s\n' "$cross_status" | CLAUDE_PROJECT_DIR="$project" bash .claude/hooks/validate-commit.sh >/dev/null 2>&1); then
  fail "non-commit Git command in another repository was falsely blocked"
fi

# Validation must follow the index blob, not whichever bytes are in the worktree.
printf '%s\n' '{"now": "valid only in worktree"}' > "$project/assets/data/bad.json"
if (cd "$project" && printf '%s\n' "$commit_payload" | CLAUDE_PROJECT_DIR="$project" bash .claude/hooks/validate-commit.sh >/dev/null 2>&1); then
  fail "invalid indexed JSON was hidden by valid worktree bytes"
fi
git -C "$project" add -- assets/data/bad.json
printf '%s\n' '{broken only in worktree' > "$project/assets/data/bad.json"
if ! (cd "$project" && printf '%s\n' "$commit_payload" | CLAUDE_PROJECT_DIR="$project" bash .claude/hooks/validate-commit.sh >/dev/null 2>&1); then
  fail "valid indexed JSON was rejected because worktree bytes differed"
fi
commit_all='{"tool_name":"Bash","tool_input":{"command":"git commit -a --dry-run -m probe"}}'
if (cd "$project" && printf '%s\n' "$commit_all" | CLAUDE_PROJECT_DIR="$project" bash .claude/hooks/validate-commit.sh >/dev/null 2>&1); then
  fail "git commit -a could add unvalidated worktree bytes after index validation"
fi
commit_path='{"tool_name":"Bash","tool_input":{"command":"git commit --dry-run -m probe -- assets/data/bad.json"}}'
if (cd "$project" && printf '%s\n' "$commit_path" | CLAUDE_PROJECT_DIR="$project" bash .claude/hooks/validate-commit.sh >/dev/null 2>&1); then
  fail "pathspec commit could add unvalidated worktree bytes after index validation"
fi
same_context='{"tool_name":"Bash","tool_input":{"command":"git -C . commit"}}'
if ! (cd "$project" && printf '%s\n' "$same_context" | CLAUDE_PROJECT_DIR="$project" bash .claude/hooks/validate-commit.sh >/dev/null 2>&1); then
  fail "Git -C pointing at the trusted repository was falsely blocked"
fi

link_blob=$(printf '%s\n' '"outside.json"' | git -C "$project" hash-object -w --stdin)
git -C "$project" update-index --add --cacheinfo "120000,$link_blob,assets/data/link.json"
if (cd "$project" && printf '%s\n' "$commit_payload" | CLAUDE_PROJECT_DIR="$project" bash .claude/hooks/validate-commit.sh >/dev/null 2>&1); then
  fail "non-regular staged JSON target was accepted"
fi
git -C "$project" reset -q -- assets/data/link.json

push_payload='{"tool_name":"Bash","tool_input":{"command":"git -C . push origin HEAD:refs/heads/main"}}'
push_output=$(cd "$project" && printf '%s\n' "$push_payload" | CLAUDE_PROJECT_DIR="$project" bash .claude/hooks/validate-push.sh 2>&1) \
  || fail "full protected refspec could not be classified"
assert_contains "$push_output" "main" "full protected refspec produced no warning"
git -C "$project" config alias.ship 'push origin HEAD:refs/heads/main'
alias_push='{"tool_name":"Bash","tool_input":{"command":"git ship"}}'
alias_push_output=$(cd "$project" && printf '%s\n' "$alias_push" | CLAUDE_PROJECT_DIR="$project" bash .claude/hooks/validate-push.sh 2>&1) \
  || fail "Git push alias could not be classified"
assert_contains "$alias_push_output" "main" "Git push alias produced no protected-branch warning"
config_env_push='{"tool_name":"Bash","tool_input":{"command":"ALIAS=push git --config-env=alias.ship=ALIAS ship --dry-run origin"}}'
if (cd "$project" && printf '%s\n' "$config_env_push" | CLAUDE_PROJECT_DIR="$project" bash .claude/hooks/validate-push.sh >/dev/null 2>&1); then
  fail "--config-env Git alias bypassed push classification"
fi
configured_push='{"tool_name":"Bash","tool_input":{"command":"git -c remote.origin.push=HEAD:refs/heads/main push --dry-run origin"}}'
configured_push_output=$(cd "$project" && printf '%s\n' "$configured_push" | CLAUDE_PROJECT_DIR="$project" bash .claude/hooks/validate-push.sh 2>&1) \
  || fail "configured push refspec could not be classified"
assert_contains "$configured_push_output" "main" "configured push refspec produced no protected-branch warning"
cross_push='{"tool_name":"Bash","tool_input":{"command":"git -C ../other-repo push origin HEAD:refs/heads/main"}}'
if (cd "$project" && printf '%s\n' "$cross_push" | CLAUDE_PROJECT_DIR="$project" bash .claude/hooks/validate-push.sh >/dev/null 2>&1); then
  fail "Git -C redirected a validated push to another repository"
fi

# The staged GDD scan is a separate Python invocation. It must use the same
# isolated boundary and therefore must not import repository sitecustomize.py.
git -C "$project" reset -q -- assets/data/bad.json
mkdir -p "$project/design/gdd"
printf '%s\n' \
  '# Overview' \
  '## Detailed' \
  '## Edge Cases' \
  '## Dependencies' \
  '## Acceptance Criteria' > "$project/design/gdd/security.md"
git -C "$project" add -- design/gdd/security.md
export CCGS_SITECUSTOMIZE_MARKER="$test_root/sitecustomize-imported"
printf '%s\n' \
  'import os' \
  'open(os.environ["CCGS_SITECUSTOMIZE_MARKER"], "w").write("executed")' > "$project/sitecustomize.py"
if ! gdd_output=$(cd "$project" && printf '%s\n' "$commit_payload" | bash .claude/hooks/validate-commit.sh 2>&1); then
  fail "valid staged GDD was rejected: $gdd_output"
fi
[ ! -e "$CCGS_SITECUSTOMIZE_MARKER" ] || fail "GDD scan imported repository sitecustomize.py"

# Notification text must travel as data, never inside PowerShell source.
mkdir -p "$test_root/bin" "$test_root/notify-capture"
printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s" "$CCGS_NOTIFICATION_MESSAGE" > "$CCGS_NOTIFY_CAPTURE_DIR/message"' \
  'printf "%s\n" "$@" > "$CCGS_NOTIFY_CAPTURE_DIR/arguments"' > "$test_root/bin/powershell.exe"
chmod +x "$test_root/bin/powershell.exe"
export CCGS_NOTIFY_CAPTURE_DIR="$test_root/notify-capture"
notify_payload='{"message":"’;Write-Output CCGS_NOTIFY_PROBE;#"}'
notify_output=$(cd "$project" && PATH="$test_root/bin:$PATH" \
  printf '%s\n' "$notify_payload" | PATH="$test_root/bin:$PATH" bash .claude/hooks/notify.sh)
attempt=0
while [ ! -f "$CCGS_NOTIFY_CAPTURE_DIR/arguments" ] && [ "$attempt" -lt 20 ]; do
  sleep 0.05
  attempt=$((attempt + 1))
done
[ -f "$CCGS_NOTIFY_CAPTURE_DIR/arguments" ] || fail "notification stub did not run"
captured_message=$(cat "$CCGS_NOTIFY_CAPTURE_DIR/message")
captured_arguments=$(cat "$CCGS_NOTIFY_CAPTURE_DIR/arguments")
assert_contains "$captured_message" "CCGS_NOTIFY_PROBE" "notification payload was not passed through the environment"
assert_not_contains "$captured_arguments" "CCGS_NOTIFY_PROBE" "notification payload entered PowerShell source"
assert_contains "$notify_output" "CCGS_NOTIFY_PROBE" "notification confirmation lost the message"

# A regular checkpoint is readable and all recovery hooks consume its snapshot.
mkdir -p "$project/production/session-state"
printf '%s\n' \
  '<!-- STATUS -->' \
  'Epic: SEC-1' \
  'Feature: secure-state' \
  'Task: safe-checkpoint' \
  '<!-- /STATUS -->' \
  '<!-- CHECKPOINT -->' \
  'validated checkpoint content' \
  '<!-- /CHECKPOINT -->' > "$project/production/session-state/active.md"

state_content=$(
  cd "$project" || exit 1
  CCGS_ROOT="$project"
  . .claude/hooks/path-security.sh
  ccgs_read_session_state "$project"
) || fail "regular checkpoint was rejected"
assert_contains "$state_content" "validated checkpoint content" "regular checkpoint content was lost"

start_output=$(cd "$project" && printf '{}\n' | bash .claude/hooks/session-start.sh)
pre_output=$(cd "$project" && bash .claude/hooks/pre-compact.sh)
post_output=$(cd "$project" && bash .claude/hooks/post-compact.sh)
status_input=$(printf '{"model":{"display_name":"test"},"context_window":{"used_percentage":1},"workspace":{"current_dir":"%s"}}' "$project")
status_output=$(cd "$project" && printf '%s\n' "$status_input" | bash .claude/statusline.sh)
assert_contains "$start_output" "validated checkpoint content" "SessionStart did not emit the validated checkpoint"
assert_contains "$pre_output" "validated checkpoint content" "PreCompact did not emit the validated checkpoint"
assert_contains "$post_output" "validated checkpoint content" "PostCompact did not emit the validated checkpoint"
assert_contains "$status_output" "safe-checkpoint" "status line did not parse the validated checkpoint"

# Repeated atomic swaps must either return the known safe file or reject the
# read. Bytes from the alternating symlink target must never be released.
race_root="$test_root/race-project"
mkdir -p "$race_root/production/session-state"
printf '%s\n' 'safe race content' > "$race_root/production/session-state/active.md"
"$test_python" -I - "$project/.claude/hooks/read-session-state.py" "$race_root" "$test_root/secret-race.txt" <<'PY'
import importlib.util
import os
import subprocess
import sys
import threading

reader_path, root, secret_path = sys.argv[1:]
safe_bytes = b"safe race content\n"
secret_bytes = b"CCGS_RACE_SECRET\n"
with open(secret_path, "wb") as handle:
    handle.write(secret_bytes)

spec = importlib.util.spec_from_file_location("ccgs_state_reader", reader_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

active = os.path.join(root, "production", "session-state", "active.md")
next_path = active + ".next"
stop = threading.Event()
skip = threading.Event()
successful_swaps = [0]


# A regular-file replacement in the exact interval between lstat and open must
# be rejected even when the replacement remains at the path after opening.
replacement_path = active + ".replacement"
with open(replacement_path, "wb") as handle:
    handle.write(secret_bytes)
original_inspect = module._inspect_path
inspect_count = [0]


def inspect_then_swap(path_root):
    result = original_inspect(path_root)
    inspect_count[0] += 1
    if inspect_count[0] == 1:
        os.replace(replacement_path, active)
    return result


module._inspect_path = inspect_then_swap
try:
    try:
        module._read_validated(root)
    except module.StateReadError:
        pass
    else:
        raise SystemExit("pre-open regular-file swap was accepted")
finally:
    module._inspect_path = original_inspect
with open(active, "wb") as handle:
    handle.write(safe_bytes)

# Keep the Windows-only bit test live on every platform, then exercise a real
# directory junction when the suite runs under Windows Python.
fake_reparse = type("FakeStat", (), {"st_file_attributes": module.REPARSE_POINT_ATTRIBUTE})()
if not module._is_reparse_point(fake_reparse):
    raise SystemExit("Windows reparse-point attribute was not recognized")

if os.name == "nt":
    test_parent = os.path.dirname(root)
    junction_root = os.path.join(test_parent, "junction-project")
    external_production = os.path.join(test_parent, "junction-external-production")
    junction_path = os.path.join(junction_root, "production")
    external_state = os.path.join(external_production, "session-state")
    os.makedirs(junction_root)
    os.makedirs(external_state)
    with open(os.path.join(external_state, "active.md"), "wb") as handle:
        handle.write(secret_bytes)
    junction_env = os.environ.copy()
    junction_env["CCGS_JUNCTION_PATH"] = junction_path
    junction_env["CCGS_JUNCTION_TARGET"] = external_production
    created = subprocess.run(
        [
            "powershell.exe",
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            "New-Item -ItemType Junction -Path $env:CCGS_JUNCTION_PATH "
            "-Target $env:CCGS_JUNCTION_TARGET -ErrorAction Stop | Out-Null",
        ],
        env=junction_env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if created.returncode != 0:
        details = created.stdout.decode("utf-8", errors="replace").strip()
        raise SystemExit("could not create Windows junction regression fixture: {}".format(details))
    try:
        try:
            module._read_validated(junction_root)
        except module.StateReadError:
            pass
        else:
            raise SystemExit("checkpoint under a Windows junction was accepted")
    finally:
        os.rmdir(junction_path)


def swapper():
    use_link = True
    while not stop.is_set():
        try:
            try:
                os.unlink(next_path)
            except FileNotFoundError:
                pass
            if use_link:
                try:
                    os.symlink(secret_path, next_path)
                except (OSError, NotImplementedError):
                    skip.set()
                    return
            else:
                with open(next_path, "wb") as handle:
                    handle.write(safe_bytes)
            os.replace(next_path, active)
            successful_swaps[0] += 1
            use_link = not use_link
        except (FileNotFoundError, PermissionError):
            continue


worker = threading.Thread(target=swapper)
worker.start()
try:
    for _ in range(2000):
        if skip.is_set():
            break
        try:
            data = module._read_validated(root)
        except module.StateReadError:
            continue
        if data != safe_bytes:
            raise SystemExit("race reader released unvalidated bytes")
finally:
    stop.set()
    worker.join()
    try:
        os.unlink(next_path)
    except FileNotFoundError:
        pass
if not skip.is_set() and successful_swaps[0] == 0:
    raise SystemExit("race test completed without a successful adversarial swap")
PY
[ "$?" -eq 0 ] || fail "checkpoint race regression failed"

# A direct symlink must not disclose its target through any automatic consumer.
create_native_link() {
  "$test_python" -I - "$1" "$2" "$3" <<'PY'
import os
import sys

target, link_path, link_kind = sys.argv[1:]
try:
    if link_kind == "hard":
        os.link(target, link_path)
    else:
        os.symlink(target, link_path, target_is_directory=(link_kind == "directory"))
        if not os.path.islink(link_path):
            raise OSError("native interpreter did not create a symbolic link")
except (OSError, NotImplementedError):
    raise SystemExit(1)
PY
}

remove_native_link() {
  "$test_python" -I - "$1" "$2" <<'PY'
import os
import sys

link_path, link_kind = sys.argv[1:]
try:
    if os.name == "nt" and link_kind == "directory":
        os.rmdir(link_path)
    else:
        os.unlink(link_path)
except FileNotFoundError:
    pass
if os.path.lexists(link_path):
    raise SystemExit("native link cleanup left the path in place")
PY
}

secret_sentinel="CCGS_SECRET_SENTINEL_7f6c8a"
printf '%s\n' \
  '<!-- STATUS -->' \
  "Task: $secret_sentinel" \
  '<!-- /STATUS -->' \
  '<!-- CHECKPOINT -->' \
  "$secret_sentinel" \
  '<!-- /CHECKPOINT -->' > "$test_root/secret.txt"
rm -f -- "$project/production/session-state/active.md"

if create_native_link "$test_root/secret.txt" "$project/production/session-state/active.md" file 2>/dev/null; then
  if rejected_content=$(
    cd "$project" || exit 1
    CCGS_ROOT="$project"
    . .claude/hooks/path-security.sh
    ccgs_read_session_state "$project" 2>/dev/null
  ); then
    fail "symlinked checkpoint was accepted"
  fi
  assert_not_contains "$rejected_content" "$secret_sentinel" "secure reader disclosed a symlink target"

  malicious_outputs="$(cd "$project" && printf '{}\n' | bash .claude/hooks/session-start.sh 2>&1)
$(cd "$project" && bash .claude/hooks/pre-compact.sh 2>&1)
$(cd "$project" && bash .claude/hooks/post-compact.sh 2>&1)
$(cd "$project" && printf '{}\n' | bash .claude/hooks/session-stop.sh 2>&1)
$(cd "$project" && printf '%s\n' "$status_input" | bash .claude/statusline.sh 2>&1)"
  assert_not_contains "$malicious_outputs" "$secret_sentinel" "an automatic consumer disclosed a symlink target"
  if [ -f "$project/production/session-logs/session-log.md" ]; then
    session_log=$(cat "$project/production/session-logs/session-log.md")
    assert_not_contains "$session_log" "$secret_sentinel" "Stop hook archived a symlink target"
  fi

  remove_native_link "$project/production/session-state/active.md" file \
    || fail "file-symlink regression fixture cleanup failed"
else
  printf 'SKIP: native interpreter did not permit file-symlink regression check\n'
fi

rmdir "$project/production/session-state"
mkdir -p "$test_root/redirected-state"
cp "$test_root/secret.txt" "$test_root/redirected-state/active.md"
if create_native_link "$test_root/redirected-state" "$project/production/session-state" directory 2>/dev/null; then
  if (
    cd "$project" || exit 1
    CCGS_ROOT="$project"
    . .claude/hooks/path-security.sh
    ccgs_read_session_state "$project" >/dev/null 2>&1
  ); then
    fail "checkpoint under a symlinked parent was accepted"
  fi
  remove_native_link "$project/production/session-state" directory \
    || fail "directory-symlink regression fixture cleanup failed"
else
  printf 'SKIP: native interpreter did not permit directory-symlink regression check\n'
fi
mkdir -p "$project/production/session-state"

if create_native_link "$test_root/secret.txt" "$project/production/session-state/active.md" hard 2>/dev/null; then
  if (
    cd "$project" || exit 1
    CCGS_ROOT="$project"
    . .claude/hooks/path-security.sh
    ccgs_read_session_state "$project" >/dev/null 2>&1
  ); then
    fail "hard-linked checkpoint was accepted"
  fi
  remove_native_link "$project/production/session-state/active.md" file \
    || fail "hard-link regression fixture cleanup failed"
else
  printf 'SKIP: native interpreter did not permit hard-link regression check\n'
fi

# Automatic writers must preserve ordinary behavior and reject redirected leaf
# and parent paths without changing the outside target.
safe_root=$(cd "$project" && pwd -P)
if [ "$test_os" = "nt" ]; then
  if writer_value=$(printf '%s\n' replacement \
      | "$test_python" -I "$project/.claude/hooks/secure-file.py" replace "$safe_root" production/session-logs/writer-probe.log 2>&1); then
    fail "native Windows secure writer used a path-based fallback"
  fi
  assert_contains "$writer_value" "fail-closed" "native Windows writer did not report its security boundary"
  [ ! -e "$project/production/session-logs/writer-probe.log" ] \
    || fail "fail-closed Windows writer created an output file"
else
  writer_value=$(
    cd "$project" || exit 1
    CCGS_ROOT="$safe_root"
    . .claude/hooks/path-security.sh
    printf '%s\n' first | ccgs_safe_append production/session-logs/writer-probe.log
    printf '%s\n' replacement | ccgs_safe_replace production/session-logs/writer-probe.log
    ccgs_safe_read production/session-logs/writer-probe.log
  ) || fail "regular secure writer operations failed"
  [ "$writer_value" = "replacement" ] || fail "secure writer did not preserve replacement bytes"

  concurrent_log="production/session-logs/concurrent-writer-probe.log"
  writer_pids=""
  writer_index=1
  while [ "$writer_index" -le 40 ]; do
    (
      printf 'entry-%s\n' "$writer_index" \
        | "$test_python" -I "$project/.claude/hooks/secure-file.py" append "$safe_root" "$concurrent_log"
    ) &
    writer_pids="$writer_pids $!"
    writer_index=$((writer_index + 1))
  done
  for writer_pid in $writer_pids; do
    wait "$writer_pid" || fail "concurrent secure writer process failed"
  done
  concurrent_value=$("$test_python" -I "$project/.claude/hooks/secure-file.py" read "$safe_root" "$concurrent_log") \
    || fail "concurrent secure writer output could not be read"
  concurrent_count=$(printf '%s\n' "$concurrent_value" | grep -c '^entry-[0-9][0-9]*$')
  unique_count=$(printf '%s\n' "$concurrent_value" | sort -u | grep -c '^entry-[0-9][0-9]*$')
  [ "$concurrent_count" -eq 40 ] && [ "$unique_count" -eq 40 ] \
    || fail "concurrent secure appends lost or duplicated audit records"
fi

outside_writer="$test_root/outside-writer.txt"
printf '%s\n' 'outside sentinel' > "$outside_writer"
rm -f -- "$project/production/session-logs/writer-probe.log"
if create_native_link "$outside_writer" "$project/production/session-logs/writer-probe.log" file 2>/dev/null; then
  if (
    cd "$project" || exit 1
    CCGS_ROOT="$safe_root"
    . .claude/hooks/path-security.sh
    printf '%s\n' attacker | ccgs_safe_append production/session-logs/writer-probe.log >/dev/null 2>&1
  ); then
    fail "secure writer followed a symlinked target"
  fi
  [ "$(cat "$outside_writer")" = "outside sentinel" ] || fail "symlinked writer target was modified"
  remove_native_link "$project/production/session-logs/writer-probe.log" file \
    || fail "writer symlink fixture cleanup failed"
else
  printf 'SKIP: native interpreter did not permit writer-symlink regression check\n'
fi

mkdir -p "$test_root/outside-log-parent"
if create_native_link "$test_root/outside-log-parent" "$project/production/redirected-logs" directory 2>/dev/null; then
  if (
    cd "$project" || exit 1
    CCGS_ROOT="$safe_root"
    . .claude/hooks/path-security.sh
    printf '%s\n' attacker | ccgs_safe_append production/redirected-logs/probe.log >/dev/null 2>&1
  ); then
    fail "secure writer followed a symlinked parent"
  fi
  [ ! -e "$test_root/outside-log-parent/probe.log" ] || fail "redirected parent received writer output"
  remove_native_link "$project/production/redirected-logs" directory \
    || fail "writer parent-symlink fixture cleanup failed"
else
  printf 'SKIP: native interpreter did not permit writer parent-symlink check\n'
fi

# A catalog artifact may not be a link to content outside the project root.
cp "$repo_root/.claude/docs/workflow-catalog.yaml" "$catalog_project/.claude/docs/workflow-catalog.yaml"
mkdir -p "$catalog_project/design/gdd"
if create_native_link "$test_root/secret.txt" "$catalog_project/design/gdd/game-concept.md" file 2>/dev/null; then
  if linked_catalog=$(cd "$catalog_project" && bash .claude/scripts/artifact-check.sh --phase concept "$catalog_project" 2>&1); then
    fail "artifact scanner accepted a linked artifact target"
  fi
  assert_contains "$linked_catalog" "INVALID" "linked catalog target was not identified as unsafe"
  remove_native_link "$catalog_project/design/gdd/game-concept.md" file \
    || fail "catalog symlink fixture cleanup failed"
else
  printf 'SKIP: native interpreter did not permit catalog-symlink regression check\n'
fi

# Dependency labels are emitted as data rather than interpolated into sed code.
if grep -F -- 'sed "s|^|  $(basename "$f") -> |"' "$repo_root/.claude/scripts/review-scope.sh" >/dev/null; then
  fail "review-scope still interpolates a filename into a sed program"
fi
grep -F -- "printf '  %s -> %s\\n' \"\$base\" \"\$dependency\"" "$repo_root/.claude/scripts/review-scope.sh" >/dev/null \
  || fail "review-scope lost data-only dependency formatting"

# The skill fixes must preserve literal paths, linked worktrees, and truthful CI text.
grep -F -- 'git --literal-pathspecs add --' "$repo_root/.claude/skills/story-done/SKILL.md" >/dev/null \
  || fail "story-done does not disable Git pathspec magic"
grep -F -- 'git rev-parse --git-path' "$repo_root/.claude/skills/story-done/SKILL.md" >/dev/null \
  || fail "story-done does not resolve the per-worktree Git path"
grep -F -- 'May I write this to [resolved path]?' "$repo_root/.claude/skills/story-done/SKILL.md" >/dev/null \
  || fail "story-done omits path-specific write approval"

story_repo="$test_root/story-repo"
story_worktree="$test_root/story-worktree"
mkdir -p "$story_repo"
git -C "$story_repo" init -q
git -C "$story_repo" config user.name "CCGS Security Test"
git -C "$story_repo" config user.email "security-test@example.invalid"
printf '%s\n' 'base' > "$story_repo/base.txt"
git -C "$story_repo" add -- base.txt
git -C "$story_repo" commit -q -m "test: base"
git -C "$story_repo" worktree add -q -b security-test "$story_worktree"
printf '%s\n' 'literal' > "$story_worktree/-leading"
printf '%s\n' 'literal' > "$story_worktree/space name"
printf '%s\n' 'must stay unstaged' > "$story_worktree/unrelated.txt"

# The magic pathspec is valid Git syntax on every platform even though Windows
# cannot create a filename containing ':' or '*'. Prove the unsafe form would
# select unrelated files, then prove literal mode rejects it without staging.
unsafe_preview=$(git -C "$story_worktree" add -n -- ':(glob)*' 2>&1) \
  || fail "Git magic-pathspec control did not execute: $unsafe_preview"
assert_contains "$unsafe_preview" "unrelated.txt" "magic-pathspec control did not select the unrelated file"
if git -C "$story_worktree" --literal-pathspecs add -- ':(glob)*' >/dev/null 2>&1; then
  fail "literal pathspec mode accepted a nonexistent magic-looking path"
fi
staged_after_rejection=$(git -C "$story_worktree" diff --cached --name-only)
[ -z "$staged_after_rejection" ] || fail "rejected literal pathspec staged files: $staged_after_rejection"

git -C "$story_worktree" --literal-pathspecs add -- '-leading' 'space name'
staged_paths=$(git -C "$story_worktree" diff --cached --name-only)
assert_contains "$staged_paths" "-leading" "literal pathspec did not stage the option-looking filename"
assert_contains "$staged_paths" "space name" "literal pathspec did not stage the spaced filename"
assert_not_contains "$staged_paths" "unrelated.txt" "literal pathspec staged an unrelated file"

message_path=$(git -C "$story_worktree" rev-parse --git-path CCGS_COMMIT_MSG)
[ -n "$message_path" ] || fail "Git did not resolve the linked-worktree message path"
message_probe="$test_root/commit-message-executed"
printf '%s\n' "feat: literal \$(touch $message_probe)" > "$message_path"
git -C "$story_worktree" commit -q -F "$message_path"
[ ! -e "$message_probe" ] || fail "literal commit message executed shell content"

if grep -F -- 'Tests run automatically on every push to `main` and on every pull request.' \
    "$repo_root/.claude/skills/test-setup/SKILL.md" >/dev/null; then
  fail "test-setup still promises Unreal pull request validation"
fi
pull_request_count=$(grep -c '^  pull_request:' "$repo_root/.claude/skills/test-setup/SKILL.md")
[ "$pull_request_count" -eq 1 ] || fail "only the credentialless Godot scaffold may run on pull requests"
unity_section=$(awk '
  /^### Unity$/ { block=$0 ORS; inside=1; next }
  inside { block=block $0 ORS }
  inside && /^### Unreal Engine$/ { last=block; inside=0 }
  END { printf "%s", last }
' "$repo_root/.claude/skills/test-setup/SKILL.md")
assert_not_contains "$unity_section" "pull_request:" "Unity license workflow still accepts pull requests"
assert_contains "$unity_section" "UNITY_LICENSE" "Unity scaffold lost its trusted-push license configuration"
assert_contains "$unity_section" "persist-credentials: false" "Unity checkout still persists credentials"
godot_section=$(awk '
  /^### Godot 4$/ { block=$0 ORS; inside=1; next }
  inside { block=block $0 ORS }
  inside && /^### Unity$/ { last=block; inside=0 }
  END { printf "%s", last }
' "$repo_root/.claude/skills/test-setup/SKILL.md")
assert_contains "$godot_section" "publish-report: false" "Godot PR workflow still tries to publish check runs"
assert_contains "$godot_section" "upload-report: false" "Godot action still performs its own artifact upload"
assert_contains "$godot_section" 'if: ${{ !cancelled() }}' "Godot artifact upload does not handle failed tests safely"
unreal_section=$(awk '
  /^### Unreal Engine$/ { block=$0 ORS; inside=1; next }
  inside { block=block $0 ORS }
  inside && /^---$/ { last=block; inside=0 }
  END { printf "%s", last }
' "$repo_root/.claude/skills/test-setup/SKILL.md")
assert_not_contains "$unreal_section" "pull_request:" "Unreal persistent runner still accepts pull requests"
assert_contains "$unreal_section" "Do not add a pull request trigger to this job." "Unreal scaffold lacks the persistent-runner trigger warning"
assert_contains "$unreal_section" "persist-credentials: false" "Unreal checkout still persists credentials"

unpinned_actions=$(grep -E '^[[:space:]]+uses:' "$repo_root/.claude/skills/test-setup/SKILL.md" \
  | grep -Ev '@[0-9a-f]{40}([[:space:]]|$)' || true)
[ -z "$unpinned_actions" ] || fail "test-setup emits mutable action references: $unpinned_actions"

printf 'PASS: security regression suite\n'
