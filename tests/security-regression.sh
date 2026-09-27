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

  remove_native_link "$project/production/session-state/active.md" file
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
  remove_native_link "$project/production/session-state" directory
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
  remove_native_link "$project/production/session-state/active.md" file
else
  printf 'SKIP: native interpreter did not permit hard-link regression check\n'
fi

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
printf '%s\n' 'literal' > "$story_worktree/:(glob)*"
printf '%s\n' 'literal' > "$story_worktree/-leading"
printf '%s\n' 'literal' > "$story_worktree/space name"
printf '%s\n' 'must stay unstaged' > "$story_worktree/unrelated.txt"
git -C "$story_worktree" --literal-pathspecs add -- ':(glob)*' '-leading' 'space name'
staged_paths=$(git -C "$story_worktree" diff --cached --name-only)
assert_contains "$staged_paths" ":(glob)*" "literal pathspec did not stage the magic-looking filename"
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
