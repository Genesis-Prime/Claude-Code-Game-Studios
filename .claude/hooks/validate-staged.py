#!/usr/bin/env python3
"""Validate the exact blobs in Git's index for a pending commit."""

import json
import os
import re
import subprocess
import sys


MAX_PATHS = 4096
MAX_INDEX_BYTES = 32 * 1024 * 1024
MAX_BLOB_BYTES = 2 * 1024 * 1024
MAX_TOTAL_BYTES = 32 * 1024 * 1024
CODE_EXTENSIONS = (".gd", ".cs", ".cpp", ".cc", ".hpp", ".h", ".c", ".py", ".js", ".ts", ".rs", ".java", ".kt", ".lua")
HARD_CODED = re.compile(rb"(damage|health|speed|rate|chance|cost|duration)[ \t]*[:=][ \t]*[0-9]+", re.I)
UNOWNED = re.compile(rb"(TODO|FIXME|HACK)[^(]", re.I)


class ScanError(Exception):
    pass


def _git(root, args, input_data=None, timeout=5):
    kwargs = {
        "cwd": root,
        "stdout": subprocess.PIPE,
        "stderr": subprocess.PIPE,
        "timeout": timeout,
        "check": False,
    }
    if input_data is None:
        kwargs["stdin"] = subprocess.DEVNULL
    else:
        kwargs["input"] = input_data
    try:
        proc = subprocess.run(["git"] + args, **kwargs)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ScanError("Git index scan failed: {}".format(exc.__class__.__name__))
    if proc.returncode != 0:
        raise ScanError("Git index scan returned exit {}".format(proc.returncode))
    if len(proc.stdout) > MAX_INDEX_BYTES:
        raise ScanError("Git index output exceeds the 32 MiB safety limit")
    return proc.stdout


def _paths(root):
    raw = _git(root, ["diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR", "--no-renames"])
    values = [item for item in raw.split(b"\0") if item]
    if len(values) > MAX_PATHS:
        raise ScanError("commit contains more than {} changed paths".format(MAX_PATHS))
    result = []
    for value in values:
        if any(byte < 32 or byte == 127 for byte in value):
            raise ScanError("staged filename contains a control character")
        result.append(os.fsdecode(value))
    return result


def _index_entries(root, wanted):
    raw = _git(root, ["ls-files", "--stage", "-z"])
    mapping = {}
    wanted_set = set(wanted)
    for record in raw.split(b"\0"):
        if not record or b"\t" not in record:
            continue
        prefix, path_bytes = record.split(b"\t", 1)
        fields = prefix.split()
        if len(fields) != 3 or fields[2] != b"0":
            continue
        path = os.fsdecode(path_bytes)
        if path in wanted_set:
            mode = fields[0].decode("ascii", errors="strict")
            if mode not in ("100644", "100755"):
                raise ScanError("staged target is not a regular file: {}".format(path))
            mapping[path] = fields[1].decode("ascii")
    missing = wanted_set.difference(mapping)
    if missing:
        raise ScanError("staged target is missing from the index: {}".format(sorted(missing)[0]))
    return mapping


def _blobs(root, ordered):
    if not ordered:
        return {}
    request = b"".join(oid.encode("ascii") + b"\n" for _, oid in ordered)
    metadata = _git(root, ["cat-file", "--batch-check"], request, timeout=10)
    total = 0
    lines = [line.split() for line in metadata.splitlines() if line]
    if len(lines) != len(ordered):
        raise ScanError("Git blob metadata response is truncated")
    for (path, expected_oid), fields in zip(ordered, lines):
        if len(fields) != 3 or fields[0].decode("ascii", errors="ignore") != expected_oid or fields[1] != b"blob":
            raise ScanError("staged target is not a blob: {}".format(path))
        try:
            size = int(fields[2])
        except ValueError:
            raise ScanError("Git blob size is invalid")
        if size > MAX_BLOB_BYTES:
            raise ScanError("staged file exceeds the 2 MiB scan limit: {}".format(path))
        total += size
        if total > MAX_TOTAL_BYTES:
            raise ScanError("staged scan exceeds the 32 MiB total limit")

    raw = _git(root, ["cat-file", "--batch"], request, timeout=10)
    offset = 0
    result = {}
    for path, expected_oid in ordered:
        end = raw.find(b"\n", offset)
        if end < 0:
            raise ScanError("Git blob batch response is truncated")
        header = raw[offset:end].split()
        offset = end + 1
        if len(header) != 3 or header[0].decode("ascii", errors="ignore") != expected_oid:
            raise ScanError("Git blob batch response is invalid")
        if header[1] != b"blob":
            raise ScanError("staged target is not a blob: {}".format(path))
        try:
            size = int(header[2])
        except ValueError:
            raise ScanError("Git blob size is invalid")
        data = raw[offset : offset + size]
        if len(data) != size or raw[offset + size : offset + size + 1] != b"\n":
            raise ScanError("Git blob batch payload is truncated")
        result[path] = data
        offset += size + 1
    return result


def _required_sections(workflow):
    if workflow == "minimal":
        return []
    if workflow == "full":
        return ["Overview", "Player Fantasy", "Detailed", "Formulas", "Edge Cases", "Dependencies", "Tuning Knobs", "Acceptance Criteria"]
    return ["Overview", "Detailed", "Edge Cases", "Dependencies", "Acceptance Criteria"]


def main():
    if len(sys.argv) != 4:
        sys.stderr.write("validate-staged: expected ROOT WORKFLOW CODE_ROOT\n")
        return 2
    root, workflow, code_root = sys.argv[1:]
    try:
        changed = _paths(root)
        relevant = []
        for path in changed:
            is_json = path.startswith("assets/data/") and path.lower().endswith(".json")
            is_gdd = path.startswith("design/gdd/") and path.lower().endswith(".md")
            is_code = bool(code_root) and path.startswith(code_root.rstrip("/") + "/")
            if is_json or is_gdd or is_code:
                relevant.append(path)
        if not relevant:
            if not code_root and any(path.lower().endswith(CODE_EXTENSIONS) for path in changed):
                sys.stderr.write(
                    "SKIPPED: source files are staged but no code root could be resolved; "
                    "hardcoded-value and TODO-owner scans did not run.\n"
                )
            return 0
        oids = _index_entries(root, relevant)
        ordered = [(path, oids[path]) for path in relevant if path in oids]
        blobs = _blobs(root, ordered)
    except ScanError as exc:
        sys.stderr.write("BLOCKED: {}\n".format(exc))
        return 2

    blocked = []
    warnings = []
    sections = _required_sections(workflow)
    prefix = code_root.rstrip("/") + "/" if code_root else ""
    for path in relevant:
        if path not in blobs:
            continue
        data = blobs[path]
        if path.startswith("assets/data/") and path.lower().endswith(".json"):
            try:
                json.loads(data.decode("utf-8-sig"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                blocked.append("BLOCKED: {} is not valid JSON in the Git index".format(path))
        if path.startswith("design/gdd/") and path.lower().endswith(".md") and sections:
            text = data.decode("utf-8", errors="replace").lower()
            for section in sections:
                if section.lower() not in text:
                    warnings.append("DESIGN: {} missing section required at workflow={}: {}".format(path, workflow, section))
        if prefix and path.startswith(prefix):
            lower = path.lower()
            if lower.endswith(CODE_EXTENSIONS) and HARD_CODED.search(data):
                warnings.append("CODE: {} may contain hardcoded gameplay values. Use data files.".format(path))
            if UNOWNED.search(data):
                warnings.append("STYLE: {} has TODO/FIXME without owner tag. Use TODO(name) format.".format(path))

    for line in blocked + warnings:
        sys.stderr.write(line + "\n")
    return 2 if blocked else 0


if __name__ == "__main__":
    raise SystemExit(main())
