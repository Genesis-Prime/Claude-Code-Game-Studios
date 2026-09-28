#!/usr/bin/env python3
"""Classify explicit Git commit/push invocations in a Bash tool event."""

import json
import os
import re
import shlex
import subprocess
import sys


MAX_EVENT_BYTES = 1024 * 1024
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=.*$", re.S)
CONTROL = {";", "&&", "||", "|", "&", "(", ")"}
GLOBAL_VALUE_OPTIONS = {
    "-C", "-c", "--git-dir", "--work-tree", "--namespace",
    "--super-prefix", "--config-env", "--exec-path",
}
PROTECTED = {"main", "master", "develop"}


class ClassificationError(Exception):
    pass


def _event_command():
    data = sys.stdin.buffer.read(MAX_EVENT_BYTES + 1)
    if len(data) > MAX_EVENT_BYTES:
        raise ClassificationError("hook event exceeds the 1 MiB safety limit")
    try:
        event = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise ClassificationError("hook event is not valid UTF-8 JSON")
    command = event.get("tool_input", {}).get("command")
    if not isinstance(command, str):
        raise ClassificationError("hook event has no string tool_input.command")
    return command


def _segments(command):
    lexer = shlex.shlex(command, posix=True, punctuation_chars="();<>|&")
    lexer.whitespace_split = True
    lexer.commenters = ""
    try:
        tokens = list(lexer)
    except ValueError as exc:
        raise ClassificationError("shell command could not be tokenized: {}".format(exc))
    result = []
    current = []
    for token in tokens:
        if token in CONTROL or all(ch in ";|&()" for ch in token):
            if current:
                result.append(current)
                current = []
        else:
            current.append(token)
    if current:
        result.append(current)
    return result


def _command_start(tokens):
    index = 0
    environment = set()
    while index < len(tokens) and ASSIGNMENT.match(tokens[index]):
        environment.add(tokens[index].split("=", 1)[0])
        index += 1
    while index < len(tokens):
        base = os.path.basename(tokens[index]).lower()
        if base in ("command", "builtin", "exec", "nohup"):
            index += 1
            while index < len(tokens) and tokens[index].startswith("-"):
                index += 1
            continue
        if base == "env":
            index += 1
            while index < len(tokens):
                if tokens[index] == "--":
                    index += 1
                    break
                if ASSIGNMENT.match(tokens[index]):
                    environment.add(tokens[index].split("=", 1)[0])
                    index += 1
                    continue
                if tokens[index] in ("-u", "--unset"):
                    environment.add("*")
                    index += 2
                    continue
                if tokens[index].startswith("-"):
                    environment.add("*")
                    index += 1
                    continue
                break
            continue
        break
    return index, environment


def _git_subcommand(tokens):
    start, environment = _command_start(tokens)
    if start >= len(tokens):
        return None
    executable = os.path.basename(tokens[start]).lower()
    if executable not in ("git", "git.exe"):
        return None
    index = start + 1
    global_args = []
    while index < len(tokens):
        value = tokens[index]
        if value == "--":
            global_args.append(value)
            index += 1
            break
        key = value.split("=", 1)[0]
        if key in GLOBAL_VALUE_OPTIONS:
            if "=" in value:
                option_value = value.split("=", 1)[1]
                global_args.append(value)
                step = 1
            elif index + 1 < len(tokens):
                option_value = tokens[index + 1]
                global_args.extend((value, option_value))
                step = 2
            else:
                return ("ambiguous", [], tokens[start:], global_args, environment)
            if key == "-c" and option_value.lower().startswith("alias."):
                return ("dangerous_alias", [], tokens[start:], global_args, environment)
            index += step
            continue
        if value.lower().startswith("-calias."):
            return ("dangerous_alias", [], tokens[start:], global_args, environment)
        if value in ("--bare", "--no-pager", "--paginate", "-p", "--literal-pathspecs", "--glob-pathspecs", "--noglob-pathspecs", "--icase-pathspecs", "--no-replace-objects"):
            global_args.append(value)
            index += 1
            continue
        if value.startswith("-"):
            return ("ambiguous", [], tokens[start:], global_args, environment)
        return (value, tokens[index + 1 :], tokens[start:], global_args, environment)
    return ("ambiguous", [], tokens[start:], global_args, environment)


def _configured_alias(root, name, global_args):
    if not re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]*$", name):
        return None
    try:
        proc = subprocess.run(
            ["git"] + global_args + ["config", "--get", "alias." + name], cwd=root,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, timeout=2, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.decode("utf-8", errors="replace").strip()


def _global_config_values(global_args):
    result = []
    index = 0
    while index < len(global_args):
        value = global_args[index]
        key = value.split("=", 1)[0]
        if key in GLOBAL_VALUE_OPTIONS:
            if "=" in value:
                option_value = value.split("=", 1)[1]
                index += 1
            elif index + 1 < len(global_args):
                option_value = global_args[index + 1]
                index += 2
            else:
                break
            if key == "-c":
                result.append(option_value)
            continue
        index += 1
    return result


def _has_global_option(global_args, wanted):
    return any(value.split("=", 1)[0] == wanted for value in global_args)


def _alias_environment_safe(environment):
    return not any(
        name == "*" or name in ("HOME", "XDG_CONFIG_HOME", "PATH") or name.startswith("GIT_")
        for name in environment
    )


def _context_safe(root, global_args, environment):
    if any(name == "*" or name == "PATH" or name.startswith("GIT_") for name in environment):
        return False
    current = os.path.realpath(root)
    expected = os.path.normcase(current)
    index = 0
    while index < len(global_args):
        value = global_args[index]
        key = value.split("=", 1)[0]
        if key == "-C":
            if "=" in value:
                path = value.split("=", 1)[1]
                index += 1
            elif index + 1 < len(global_args):
                path = global_args[index + 1]
                index += 2
            else:
                return False
            current = os.path.realpath(os.path.join(current, path)) if not os.path.isabs(path) else os.path.realpath(path)
            continue
        if key in ("--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env") \
                or value == "--bare":
            return False
        if key == "-c":
            configured = value.split("=", 1)[1] if "=" in value else (
                global_args[index + 1] if index + 1 < len(global_args) else ""
            )
            config_key = configured.split("=", 1)[0].lower()
            if config_key in ("core.bare", "core.worktree", "extensions.worktreeconfig") \
                    or config_key.startswith("include.") or config_key.startswith("includeif."):
                return False
            index += 1 if "=" in value else 2
            continue
        index += 1
    return os.path.normcase(current) == expected


def _alias_result(root, subcommand, args, target, global_args, environment, seen=None):
    seen = set() if seen is None else seen
    if subcommand in seen or len(seen) >= 8:
        return "ambiguous", [], global_args, environment
    if not _alias_environment_safe(environment) or _has_global_option(global_args, "--config-env"):
        return "ambiguous", [], global_args, environment
    value = _configured_alias(root, subcommand, global_args)
    if value is None:
        return "other", [], global_args, environment
    if value.startswith("!"):
        return "ambiguous", [], global_args, environment
    try:
        expansion = shlex.split(value, posix=True)
    except ValueError:
        return "ambiguous", [], global_args, environment
    parsed = _git_subcommand(["git"] + expansion + args)
    if parsed is None:
        return "ambiguous", [], global_args, environment
    expanded_subcommand, expanded_args, _, expanded_globals, expanded_environment = parsed
    combined_globals = global_args + expanded_globals
    combined_environment = environment.union(expanded_environment)
    if expanded_subcommand == target:
        return "target", expanded_args, combined_globals, combined_environment
    if expanded_subcommand in ("ambiguous", "dangerous_alias"):
        return "ambiguous", [], combined_globals, combined_environment
    seen.add(subcommand)
    return _alias_result(
        root, expanded_subcommand, expanded_args, target,
        combined_globals, combined_environment, seen,
    )


def _invocations(command, target, root):
    found = []
    unclassified = []
    force_ambiguous = False
    cwd_changed = False
    for segment in _segments(command):
        command_index, _ = _command_start(segment)
        if command_index < len(segment) and os.path.basename(segment[command_index]).lower() in ("cd", "pushd", "popd"):
            cwd_changed = True
        parsed = _git_subcommand(segment)
        if parsed is None:
            unclassified.append(" ".join(segment))
            continue
        subcommand, args, raw, global_args, environment = parsed
        if subcommand == target:
            if cwd_changed or not _context_safe(root, global_args, environment):
                force_ambiguous = True
            else:
                found.append((args, raw, global_args))
        elif subcommand in ("ambiguous", "dangerous_alias"):
            unclassified.append(" ".join(raw))
            force_ambiguous = force_ambiguous or subcommand == "dangerous_alias"
        else:
            alias_result, alias_args, alias_globals, alias_environment = _alias_result(
                root, subcommand, args, target, global_args, environment,
            )
            if alias_result == "target":
                if cwd_changed or not _context_safe(root, alias_globals, alias_environment):
                    force_ambiguous = True
                else:
                    found.append((alias_args, raw, alias_globals))
            elif alias_result == "ambiguous":
                force_ambiguous = True
    probe = re.compile(r"\bgit(?:\.exe)?\b.*\b{}\b".format(re.escape(target)), re.I | re.S)
    ambiguous = not found and (force_ambiguous or bool(probe.search("\n".join(unclassified))))
    return found, ambiguous


def _destination(refspec):
    value = refspec.lstrip("+")
    if ":" in value:
        value = value.rsplit(":", 1)[1]
    value = value.rstrip("/")
    return value.rsplit("/", 1)[-1]


def _protected_refspec(refspec):
    value = refspec.lstrip("+")
    if value.startswith("^"):
        return ""
    if value == ":":
        return "all protected branches"
    destination = value.rsplit(":", 1)[1] if ":" in value else value
    if destination.startswith("refs/heads/") and "*" in destination:
        return "all protected branches"
    name = _destination(value)
    return name if name in PROTECTED else ""


def _commit_uses_worktree(args):
    dangerous_long = {
        "--all", "--include", "--only", "--interactive", "--patch",
        "--pathspec-from-file", "--pathspec-file-nul",
    }
    value_options = {
        "--message", "--file", "--reuse-message", "--reedit-message",
        "--fixup", "--squash", "--author", "--date", "--cleanup",
        "--trailer", "--template",
    }
    short_value = {"-m", "-F", "-C", "-c"}
    index = 0
    while index < len(args):
        value = args[index]
        if value == "--":
            return index + 1 < len(args)
        key = value.split("=", 1)[0]
        if key in dangerous_long:
            return True
        if key in value_options:
            index += 1 if "=" in value else 2
            continue
        if value in short_value:
            index += 2
            continue
        if value.startswith(("-m", "-F", "-C", "-c", "-S")) and len(value) > 2:
            index += 1
            continue
        if value.startswith("-") and not value.startswith("--"):
            flags = value[1:]
            if any(flag in flags for flag in ("a", "i", "o", "p")):
                return True
            index += 1
            continue
        if value.startswith("-"):
            index += 1
            continue
        return True
    return False


def _current_branch(root):
    try:
        proc = subprocess.run(
            ["git", "symbolic-ref", "-q", "--short", "HEAD"], cwd=root,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, timeout=2, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if proc.returncode != 0:
        return ""
    return proc.stdout.decode("utf-8", errors="replace").strip()


def _protected_push(args, root, global_args):
    if any(arg in ("--all", "--mirror") for arg in args):
        return "all protected branches"
    delete = "--delete" in args or "-d" in args
    value_options = {"--repo", "--receive-pack", "--exec", "--push-option", "-o"}
    positional = []
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == "--":
            positional.extend(args[index + 1 :])
            break
        key = arg.split("=", 1)[0]
        if key in value_options:
            index += 1 if "=" in arg else 2
            continue
        if arg.startswith("-"):
            index += 1
            continue
        positional.append(arg)
        index += 1
    refspecs = positional[1:] if positional else []
    if delete and refspecs:
        for item in refspecs:
            protected = _protected_refspec(item)
            if protected:
                return protected
    for item in refspecs:
        protected = _protected_refspec(item)
        if protected:
            return protected
    if not refspecs:
        for configured in _global_config_values(global_args):
            if "=" not in configured:
                continue
            key, value = configured.split("=", 1)
            lower = key.lower()
            if lower.startswith("remote.") and lower.endswith(".push"):
                protected = _protected_refspec(value)
                if protected:
                    return protected
            if lower.startswith("remote.") and lower.endswith(".mirror") \
                    and value.lower() in ("true", "yes", "on", "1"):
                return "all protected branches"
            if lower == "push.default" and value.lower() == "matching":
                return "all protected branches"
        branch = _current_branch(root)
        if branch in PROTECTED:
            return branch
        return "implicit or configured refs"
    return ""


def main():
    if len(sys.argv) not in (2, 3) or sys.argv[1] not in ("commit", "push"):
        sys.stderr.write("git-command-security: expected commit|push [project-root]\n")
        return 2
    target = sys.argv[1]
    root = sys.argv[2] if len(sys.argv) == 3 else os.getcwd()
    try:
        command = _event_command()
        found, ambiguous = _invocations(command, target, root)
    except ClassificationError as exc:
        sys.stderr.write("git-command-security: {}\n".format(exc))
        return 2
    if ambiguous:
        sys.stderr.write("git-command-security: possible git {} command could not be classified safely\n".format(target))
        return 2
    if not found:
        return 1
    if target == "commit" and any(_commit_uses_worktree(args) for args, _, _ in found):
        sys.stderr.write("git-command-security: commit options may read unvalidated worktree bytes\n")
        return 2
    if target == "push":
        protected = ""
        for args, _, global_args in found:
            protected = _protected_push(args, root, global_args)
            if protected:
                break
        sys.stdout.write(protected)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
