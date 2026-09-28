#!/usr/bin/env python3
"""Inspect and run typed project command argv without a shell."""

import argparse
import hashlib
import json
import os
import re
import signal
import shutil
import stat
import subprocess
import sys
import threading


MAX_CONFIG_BYTES = 1024 * 1024
MAX_OUTPUT_BYTES = 4 * 1024 * 1024
MAX_ARGS = 64
MAX_ARG_BYTES = 4096
ALLOWED_NAMES = {"build", "test", "run", "smoke"}
ALLOWED_ENVIRONMENT = {
    "PATH", "HOME", "USER", "LOGNAME", "USERPROFILE", "SYSTEMROOT",
    "WINDIR", "COMSPEC", "PATHEXT", "TMPDIR", "TMP", "TEMP", "LANG",
    "LANGUAGE", "TERM", "COLORTERM", "DISPLAY", "WAYLAND_DISPLAY",
    "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "XAUTHORITY",
    "__CF_USER_TEXT_ENCODING",
}
LINE = re.compile(r"^  (build|test|run|smoke):[ \t]*(\[.*\])[ \t]*(?:#.*)?$")
COMMANDS_HEADER = re.compile(r"^commands:[ \t]*(?:#.*)?$")
REPARSE_POINT_ATTRIBUTE = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
SHELL_INLINE_FLAGS = {
    "sh": {"-c"},
    "bash": {"-c"},
    "zsh": {"-c"},
    "dash": {"-c"},
    "ksh": {"-c"},
    "fish": {"-c"},
    "pwsh": {"-command", "-c", "-encodedcommand"},
    "powershell": {"-command", "-c", "-encodedcommand"},
    "cmd": {"/c", "/k"},
    "node": {"-e", "-p", "--eval"},
    "perl": {"-e"},
    "ruby": {"-e"},
    "php": {"-r"},
    "osascript": {"-e"},
}


class CommandError(Exception):
    pass


def _redirect(value):
    return stat.S_ISLNK(value.st_mode) or bool(
        getattr(value, "st_file_attributes", 0) & REPARSE_POINT_ATTRIBUTE
    )


def _root():
    scripts = os.path.dirname(os.path.realpath(__file__))
    return os.path.realpath(os.path.join(scripts, "..", ".."))


def _read_config(root):
    path = os.path.join(root, "project.yaml")
    try:
        before = os.lstat(path)
    except OSError as exc:
        raise CommandError("project.yaml is unavailable: {}".format(exc.__class__.__name__))
    if _redirect(before) or not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise CommandError("project.yaml is linked, redirected, or non-regular")
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        after = os.lstat(path)
        if _redirect(opened) or not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1:
            raise CommandError("opened project.yaml is unsafe")
        if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino) or (opened.st_dev, opened.st_ino) != (after.st_dev, after.st_ino):
            raise CommandError("project.yaml changed while opening")
        if opened.st_size > MAX_CONFIG_BYTES:
            raise CommandError("project.yaml exceeds the 1 MiB safety limit")
        chunks = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(65536, MAX_CONFIG_BYTES + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > MAX_CONFIG_BYTES:
                raise CommandError("project.yaml exceeds the 1 MiB safety limit")
        return b"".join(chunks).decode("utf-8")
    except UnicodeDecodeError:
        raise CommandError("project.yaml is not UTF-8")
    finally:
        os.close(descriptor)


def _profiles(text):
    profiles = {}
    in_commands = False
    for raw in text.splitlines():
        if raw and not raw.startswith((" ", "\t")):
            in_commands = bool(COMMANDS_HEADER.match(raw))
            continue
        if not in_commands or not raw.strip() or raw.lstrip().startswith("#"):
            continue
        match = LINE.match(raw)
        if not match:
            if raw.startswith("  ") and not raw.startswith("    "):
                raise CommandError("commands entries must be inline JSON-style argv arrays")
            continue
        name, encoded = match.groups()
        if name in profiles:
            raise CommandError("duplicate commands.{} entry".format(name))
        try:
            argv = json.loads(encoded)
        except json.JSONDecodeError:
            raise CommandError("commands.{} is not a valid JSON-style array".format(name))
        if not isinstance(argv, list) or not argv or len(argv) > MAX_ARGS:
            raise CommandError("commands.{} must contain 1 to {} arguments".format(name, MAX_ARGS))
        for value in argv:
            if not isinstance(value, str) or not value or len(value.encode("utf-8")) > MAX_ARG_BYTES:
                raise CommandError("commands.{} contains an invalid argument".format(name))
            if "\x00" in value or any(ord(ch) < 32 and ch not in "\t" for ch in value):
                raise CommandError("commands.{} contains a control character".format(name))
        profiles[name] = argv
    return profiles


def _extra(value):
    if value is None:
        return []
    try:
        result = json.loads(value)
    except json.JSONDecodeError:
        raise CommandError("--extra-json is not valid JSON")
    if not isinstance(result, list) or len(result) > MAX_ARGS:
        raise CommandError("--extra-json must be an argv array")
    for item in result:
        if not isinstance(item, str) or not item or len(item.encode("utf-8")) > MAX_ARG_BYTES or "\x00" in item:
            raise CommandError("--extra-json contains an invalid argument")
    return result


def _receipt(name, argv, timeout, executable, environment):
    environment_bytes = json.dumps(
        sorted(environment.items()), ensure_ascii=False, separators=(",", ":"),
    ).encode("utf-8")
    payload = json.dumps(
        {
            "command": name,
            "argv": argv,
            "cwd": ".",
            "timeout_seconds": timeout,
            "executable": executable,
            "environment_sha256": hashlib.sha256(environment_bytes).hexdigest(),
        },
        ensure_ascii=False,
        separators=(",", ":"),
    )
    return payload, hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _clean_environment():
    result = {}
    for key, value in os.environ.items():
        upper = key.upper()
        if upper in ALLOWED_ENVIRONMENT or upper.startswith("LC_"):
            result[key] = value
    return result


def _command_basename(value):
    name = os.path.basename(value).lower()
    if name.endswith((".exe", ".cmd", ".bat", ".com")):
        name = os.path.splitext(name)[0]
    return name


def _reject_inline_code(argv):
    inspected = list(argv)
    name = _command_basename(inspected[0])
    if name == "env":
        raise CommandError(
            "env wrappers are not allowed in project commands; configure the actual executable directly"
        )
    args = [value.lower() for value in inspected[1:]]
    flags = set(args)
    if (name == "python" or name.startswith("python") or name == "py") \
            and any(value == "-c" or value.startswith("-c") for value in args):
        raise CommandError("inline interpreter code is not allowed in project commands")
    blocked = SHELL_INLINE_FLAGS.get(name, set())
    if name in {"sh", "bash", "zsh", "dash", "ksh", "fish"} and any(
            value.startswith("-") and not value.startswith("--") and "c" in value[1:]
            for value in args):
        raise CommandError("inline shell or interpreter code is not allowed in project commands")
    attached = any(
        any(value == flag or value.startswith(flag + "=")
            or (len(flag) == 2 and value.startswith(flag) and len(value) > 2)
            or (flag in ("-command", "-encodedcommand") and value.startswith(flag))
            for flag in blocked)
        for value in args
    )
    if blocked.intersection(flags) or attached:
        raise CommandError("inline shell or interpreter code is not allowed in project commands")


def _executable_identity(requested, root, environment):
    has_separator = os.sep in requested or (os.altsep is not None and os.altsep in requested)
    if has_separator or os.path.isabs(requested):
        candidate = requested if os.path.isabs(requested) else os.path.join(root, requested)
    else:
        search_path = next(
            (value for key, value in environment.items() if key.upper() == "PATH"),
            None,
        )
        safe_entries = []
        for entry in (search_path or "").split(os.pathsep):
            if not entry or not os.path.isabs(entry):
                continue
            safe_entries.append(entry)
        candidate = shutil.which(requested, path=os.pathsep.join(safe_entries))
    if not candidate:
        raise CommandError("command executable could not be resolved")
    resolved = os.path.realpath(os.path.abspath(candidate))
    try:
        info = os.stat(resolved)
    except OSError as exc:
        raise CommandError("command executable is unavailable: {}".format(exc.__class__.__name__))
    if not stat.S_ISREG(info.st_mode) or _redirect(info):
        raise CommandError("command executable is not a regular file")
    return {
        "requested": requested,
        "resolved": resolved,
        "device": info.st_dev,
        "inode": info.st_ino,
        "size": info.st_size,
        "mtime_ns": getattr(info, "st_mtime_ns", int(info.st_mtime * 1000000000)),
    }


def _terminate(proc):
    try:
        if os.name != "nt":
            os.killpg(proc.pid, signal.SIGKILL)
        else:
            proc.kill()
    except OSError:
        pass


def _run(argv, root, timeout, environment):
    options = {
        "cwd": root,
        "env": environment,
        "stdin": subprocess.DEVNULL,
        "stdout": subprocess.PIPE,
        "stderr": subprocess.STDOUT,
    }
    if os.name != "nt":
        options["start_new_session"] = True
    proc = subprocess.Popen(argv, **options)
    chunks = []
    size = [0]
    over = threading.Event()

    def reader():
        while True:
            chunk = proc.stdout.read(65536)
            if not chunk:
                return
            remaining = MAX_OUTPUT_BYTES - size[0]
            if remaining > 0:
                chunks.append(chunk[:remaining])
                size[0] += min(len(chunk), remaining)
            if len(chunk) > remaining:
                over.set()
                _terminate(proc)
                return

    worker = threading.Thread(target=reader)
    worker.daemon = True
    worker.start()
    try:
        returncode = proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        _terminate(proc)
        proc.wait()
        worker.join(timeout=2)
        sys.stdout.buffer.write(b"".join(chunks))
        raise CommandError("command exceeded the {} second timeout".format(timeout))
    worker.join(timeout=2)
    sys.stdout.buffer.write(b"".join(chunks))
    if over.is_set():
        raise CommandError("command output exceeded the 4 MiB safety limit")
    return returncode


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("inspect", "run"))
    parser.add_argument("name", choices=sorted(ALLOWED_NAMES))
    parser.add_argument("--extra-json")
    parser.add_argument("--approved-sha")
    parser.add_argument("--timeout", type=int, default=300)
    args = parser.parse_args()
    try:
        root = _root()
        profiles = _profiles(_read_config(root))
        if args.name not in profiles:
            raise CommandError("commands.{} is not configured as an argv array".format(args.name))
        if args.timeout < 1 or args.timeout > 1800:
            raise CommandError("timeout must be between 1 and 1800 seconds")
        argv = profiles[args.name] + _extra(args.extra_json)
        _reject_inline_code(argv)
        environment = _clean_environment()
        executable = _executable_identity(argv[0], root, environment)
        payload, digest = _receipt(args.name, argv, args.timeout, executable, environment)
        if args.action == "inspect":
            sys.stdout.write("APPROVAL_SHA={}\nRECEIPT={}\n".format(digest, payload))
            return 0
        if not args.approved_sha or args.approved_sha != digest:
            raise CommandError("exact command approval is missing or stale; run inspect again")
        return _run([executable["resolved"]] + argv[1:], root, args.timeout, environment)
    except (CommandError, OSError) as exc:
        sys.stderr.write("project-command: {}\n".format(exc))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
