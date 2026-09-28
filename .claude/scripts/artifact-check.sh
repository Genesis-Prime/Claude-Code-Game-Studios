#!/usr/bin/env bash
# artifact-check.sh — evaluate every workflow-catalog step's artifact spec
# against what is actually on disk.
#
# Replaces the "Use Glob and Read to verify files exist and have meaningful
# content" loop in /gate-check (and the equivalent hand-scans in /help and
# /project-stage-detect). workflow-catalog.yaml already encodes `glob`,
# `pattern`, `min_count` and `any_of` per step; nothing consumed it
# deterministically, so the model re-derived the same answers by opening files.
#
# EMITS OBSERVATIONS, NOT A VERDICT (per .claude/docs/context-management.md
# rule 2). It reports what is on disk; the CALLER applies the workflow tier,
# the required/optional distinction, and any per-system override. In
# particular this script never says PASS or FAIL, and never decides that an
# ABSENT artifact is a blocker — at `minimal` most of them are not.
#
# Usage: bash .claude/scripts/artifact-check.sh [--phase <id>] [project-root]
#   --phase <id>  restrict output to one phase (concept, systems-design, ...)
#   project-root  defaults to the repo root; an explicit path is taken as-is
#                 (used by the test suite against fixtures).
#
# Output:
#   CATALOG: <path>            the catalog actually read
#   ROOT: <path>               the tree evaluated against
#   PHASES: <n> / STEPS: <n>   denominators — see below
#   PHASE: <id>
#     STEP: <id> required=<bool> repeatable=<bool> check=<kind> status=<status> ...
#
# status values (observations):
#   PRESENT       glob matched, count >= min_count, pattern found if specified
#   ABSENT        no file matched the glob
#   SHORT         files matched but fewer than min_count
#   PATTERN_MISS  files matched but none contained the required pattern
#   UNKNOWN       a bounded scan could not finish within its resource limits
#   INVALID       catalog path data was unsafe; the script exits non-zero
#   NO_CHECK      the step declares no artifact — completion is not detectable
#                 from disk. NOT the same as ABSENT. A `note=` field carries the
#                 catalog's human-readable fallback where one exists.
#
# DENOMINATOR DISCIPLINE (mirrors create-control-manifest / adr-dep-graph.sh):
# STEPS is printed before any per-step line so a caller can tell "0 steps
# reported because the catalog failed to parse" from "0 steps are incomplete".
# A NO_CHECK count is printed too — a phase that is all NO_CHECK has been
# *scanned*, not *satisfied*, and reporting it as clean would be a false pass.
#
# Patterns are POSIX ERE and are matched with `grep -E`, never Python `re`
# (the catalog uses classes like [[:space:]]) and never `grep -P` (unavailable
# on Windows Git Bash — see .claude/docs/coding-standards notes).

set -u

PHASE_FILTER=""
ROOT_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --phase) PHASE_FILTER="${2:-}"; shift 2 ;;
    --phase=*) PHASE_FILTER="${1#--phase=}"; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) ROOT_ARG="$1"; shift ;;
  esac
done

if [ -n "$ROOT_ARG" ]; then
  ROOT="$ROOT_ARG"
else
  cd "$(dirname "$0")/../.." || { echo "artifact-check: cannot reach repo root" >&2; exit 1; }
  ROOT="$(pwd)"
fi

CATALOG="$ROOT/.claude/docs/workflow-catalog.yaml"
if [ ! -f "$CATALOG" ]; then
  echo "artifact-check: catalog not found at $CATALOG" >&2
  exit 1
fi

# Python fallback chain: python -> python3 -> py (matches yaml-helper.sh:65).
PYBIN=""
for candidate in python python3 py; do
  if command -v "$candidate" >/dev/null 2>&1; then
    if "$candidate" -I -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
      PYBIN="$candidate"; break
    fi
  fi
done
if [ -z "$PYBIN" ]; then
  echo "artifact-check: no python 3 interpreter found (tried python, python3, py)" >&2
  exit 1
fi

"$PYBIN" -I - "$CATALOG" "$ROOT" "$PHASE_FILTER" <<'PYEOF'
import ntpath
import os
import re
import stat
import subprocess
import sys

catalog_path, root_arg, phase_filter = sys.argv[1], sys.argv[2], sys.argv[3]

MAX_CATALOG_BYTES = 1024 * 1024
MAX_PATTERN_LENGTH = 1024
MAX_DIRECTORIES = 10000
MAX_FILES = 50000
MAX_MATCHES = 2048
MAX_FILE_BYTES = 2 * 1024 * 1024
MAX_TOTAL_SCAN_BYTES = 32 * 1024 * 1024
REPARSE_POINT_ATTRIBUTE = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)


class CatalogError(Exception):
    pass


class ScanBudgetError(Exception):
    pass


def is_redirect(value):
    return stat.S_ISLNK(value.st_mode) or bool(
        getattr(value, "st_file_attributes", 0) & REPARSE_POINT_ATTRIBUTE
    )


root_absolute = os.path.abspath(root_arg)
try:
    root_info = os.lstat(root_absolute)
except OSError as exc:
    sys.stderr.write("artifact-check: project root unavailable: %s\n" % exc.__class__.__name__)
    sys.exit(2)
if is_redirect(root_info) or not stat.S_ISDIR(root_info.st_mode):
    sys.stderr.write("artifact-check: project root must be a physical directory\n")
    sys.exit(2)
root = os.path.realpath(root_absolute)
catalog_path = os.path.join(root, ".claude", "docs", "workflow-catalog.yaml")


def secure_read(path, maximum):
    try:
        before = os.lstat(path)
    except OSError as exc:
        raise CatalogError("file is unavailable: %s" % exc.__class__.__name__)
    if is_redirect(before) or not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise CatalogError("file is linked, redirected, or non-regular")
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        after = os.lstat(path)
        if is_redirect(opened) or not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1:
            raise CatalogError("opened file is linked, redirected, or non-regular")
        if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino) or (opened.st_dev, opened.st_ino) != (after.st_dev, after.st_ino):
            raise CatalogError("file changed while opening")
        if opened.st_size > maximum:
            raise ScanBudgetError("file exceeds the configured size limit")
        chunks = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(65536, maximum + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > maximum:
                raise ScanBudgetError("file exceeds the configured size limit")
        final = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns) != (final.st_dev, final.st_ino, final.st_size, final.st_mtime_ns):
            raise CatalogError("file changed during the read")
        return b"".join(chunks)
    finally:
        os.close(descriptor)

# A gate's own output path is part of the gate: the catalog's `note:` fields
# contain em-dashes, and on a cp1252 console an unreconfigured stdout raises
# UnicodeEncodeError mid-report — dying after some rows have printed, which
# reads as a short but successful run. Force UTF-8 and never crash on a glyph.
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except (AttributeError, ValueError):
    pass


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def strip_val(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        v = v[1:-1]
    return v


# --- parse ---------------------------------------------------------------
# Hand-rolled on purpose: PyYAML is not a guaranteed dependency (yaml-helper.sh
# promises "no external deps beyond a Python 3 interpreter"). The catalog's
# shape is fixed and regular, so an indentation walk is sufficient and cannot
# drag in an import that fails on a user's machine.
try:
    catalog_bytes = secure_read(catalog_path, MAX_CATALOG_BYTES)
except (CatalogError, ScanBudgetError) as exc:
    sys.stderr.write("artifact-check: unsafe catalog: %s\n" % exc)
    sys.exit(2)
lines = [ln.rstrip("\n").rstrip("\r") for ln in catalog_bytes.decode("utf-8", errors="replace").splitlines()]

phases = []            # [(phase_id, [step, ...])]
cur_phase = None
cur_step = None
ctx = None             # None | "artifact" | "any_of"
in_phases = False

for raw in lines:
    if not raw.strip() or raw.lstrip().startswith("#"):
        continue
    ind = indent_of(raw)
    s = raw.strip()

    if ind == 0:
        in_phases = (s == "phases:")
        continue
    if not in_phases:
        continue

    if ind == 2 and s.endswith(":"):
        cur_phase = (s[:-1].strip(), [])
        phases.append(cur_phase)
        cur_step = None
        ctx = None
        continue
    if cur_phase is None:
        continue

    if ind == 6 and s.startswith("- id:"):
        cur_step = {"id": strip_val(s[len("- id:"):]), "required": False,
                    "repeatable": False, "artifact": None, "note": None}
        cur_phase[1].append(cur_step)
        ctx = None
        continue
    if cur_step is None:
        continue

    if ind == 8:
        ctx = None
        if s == "artifact:":
            cur_step["artifact"] = {"glob": None, "pattern": None,
                                    "min_count": 1, "any_of": [], "note": None}
            ctx = "artifact"
        elif s.startswith("required:"):
            cur_step["required"] = strip_val(s[len("required:"):]).lower() == "true"
        elif s.startswith("repeatable:"):
            cur_step["repeatable"] = strip_val(s[len("repeatable:"):]).lower() == "true"
        continue

    art = cur_step["artifact"]
    if art is None:
        continue

    if ind == 10:
        if s == "any_of:":
            ctx = "any_of"
        elif s.startswith("glob:"):
            art["glob"] = strip_val(s[len("glob:"):]); ctx = "artifact"
        elif s.startswith("pattern:"):
            art["pattern"] = strip_val(s[len("pattern:"):]); ctx = "artifact"
        elif s.startswith("min_count:"):
            try:
                art["min_count"] = int(strip_val(s[len("min_count:"):]))
            except ValueError:
                pass
            ctx = "artifact"
        elif s.startswith("note:"):
            art["note"] = strip_val(s[len("note:"):]); ctx = "artifact"
        continue

    if ind >= 12 and ctx == "any_of":
        if s.startswith("- glob:"):
            art["any_of"].append({"glob": strip_val(s[len("- glob:"):]), "pattern": None})
        elif s.startswith("pattern:") and art["any_of"]:
            art["any_of"][-1]["pattern"] = strip_val(s[len("pattern:"):])

# --- evaluate ------------------------------------------------------------
_inventory = None
_unsafe_entries = None
_scan_total = 0


def validate_pattern(pat):
    if not pat or len(pat) > MAX_PATTERN_LENGTH:
        raise CatalogError("glob is empty or too long")
    if "\\" in pat or os.path.isabs(pat) or ntpath.isabs(pat) or ntpath.splitdrive(pat)[0]:
        raise CatalogError("glob must be a portable project-relative path")
    parts = pat.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise CatalogError("glob contains an empty or traversal component")
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in pat):
        raise CatalogError("glob contains a control character")


def glob_regex(pat):
    out = ["^"]
    index = 0
    while index < len(pat):
        char = pat[index]
        if char == "*":
            if index + 1 < len(pat) and pat[index + 1] == "*":
                index += 2
                if index < len(pat) and pat[index] == "/":
                    out.append("(?:.*/)?")
                    index += 1
                else:
                    out.append(".*")
                continue
            out.append("[^/]*")
        elif char == "?":
            out.append("[^/]")
        else:
            out.append(re.escape(char))
        index += 1
    out.append("$")
    return re.compile("".join(out))


def build_inventory():
    safe = []
    unsafe = []
    directory_count = 0
    file_count = 0
    for current, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
        directory_count += 1
        if directory_count > MAX_DIRECTORIES:
            raise ScanBudgetError("directory traversal exceeds the configured limit")
        kept = []
        for name in dirnames:
            full = os.path.join(current, name)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            try:
                info = os.lstat(full)
            except OSError:
                unsafe.append((rel, True))
                continue
            if is_redirect(info) or not stat.S_ISDIR(info.st_mode):
                unsafe.append((rel, True))
            else:
                kept.append(name)
        dirnames[:] = kept
        for name in filenames:
            file_count += 1
            if file_count > MAX_FILES:
                raise ScanBudgetError("file traversal exceeds the configured limit")
            full = os.path.join(current, name)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            try:
                info = os.lstat(full)
            except OSError:
                unsafe.append((rel, False))
                continue
            if is_redirect(info) or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                unsafe.append((rel, False))
            else:
                safe.append((rel, full))
    return safe, unsafe


def match_files(pat):
    global _inventory, _unsafe_entries
    if not pat:
        return []
    validate_pattern(pat)
    matcher = glob_regex(pat)
    if _inventory is None:
        _inventory, _unsafe_entries = build_inventory()
    fixed = re.split(r"[*?]", pat, 1)[0].rstrip("/")
    for rel, is_dir in _unsafe_entries:
        if matcher.match(rel) or (is_dir and (not fixed or rel.startswith(fixed) or fixed.startswith(rel + "/"))):
            raise CatalogError("glob reaches a linked or non-regular path")
    matches = [full for rel, full in _inventory if matcher.match(rel)]
    if len(matches) > MAX_MATCHES:
        raise ScanBudgetError("glob matches more than %d files" % MAX_MATCHES)
    return sorted(matches)


def pattern_hits(files, pattern):
    """POSIX ERE via grep -E. Python's re cannot parse [[:space:]], and grep -P
    is unavailable on Windows Git Bash."""
    if not pattern:
        return files
    global _scan_total
    if len(pattern) > MAX_PATTERN_LENGTH or "\x00" in pattern:
        raise CatalogError("pattern is empty, contains NUL, or is too long")
    hits = []
    for f in files:
        try:
            data = secure_read(f, MAX_FILE_BYTES)
            _scan_total += len(data)
            if _scan_total > MAX_TOTAL_SCAN_BYTES:
                raise ScanBudgetError("pattern scan exceeds the 32 MiB total limit")
            rc = subprocess.run(["grep", "-qE", "--", pattern], input=data,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                timeout=2, check=False).returncode
        except OSError:
            return None          # no grep — caller reports UNKNOWN rather than a false miss
        except subprocess.TimeoutExpired:
            raise ScanBudgetError("pattern scan exceeded its per-file timeout")
        if rc == 0:
            hits.append(f)
    return hits


def evaluate(art):
    """-> (status, kind, detail dict). Observation only; no verdict."""
    if art is None:
        return "NO_CHECK", "none", {}

    try:
        if art["any_of"]:
            for i, alt in enumerate(art["any_of"]):
                files = match_files(alt["glob"])
                if not files:
                    continue
                hits = pattern_hits(files, alt["pattern"])
                if hits is None:
                    return "UNKNOWN", "any_of", {"why": "grep-unavailable"}
                if hits:
                    return "PRESENT", "any_of", {"match": alt["glob"], "alt": str(i + 1)}
            return "ABSENT", "any_of", {"alts": str(len(art["any_of"]))}

        if not art["glob"]:
            return "NO_CHECK", "none", ({"note": art["note"]} if art["note"] else {})

        files = match_files(art["glob"])
        if not files:
            return "ABSENT", "glob", {"glob": art["glob"]}

        hits = pattern_hits(files, art["pattern"])
        if hits is None:
            return "UNKNOWN", "glob", {"why": "grep-unavailable"}
        if art["pattern"] and not hits:
            return "PATTERN_MISS", "glob", {"glob": art["glob"], "found": str(len(files))}

        counted = hits if art["pattern"] else files
        need = art["min_count"]
        if len(counted) < need:
            return "SHORT", "glob", {"glob": art["glob"], "count": str(len(counted)), "min": str(need)}
        d = {"count": str(len(counted))}
        if need > 1:
            d["min"] = str(need)
        return "PRESENT", "glob", d
    except CatalogError as exc:
        return "INVALID", "catalog", {"why": str(exc).replace(" ", "-")}
    except ScanBudgetError as exc:
        return "UNKNOWN", "budget", {"why": str(exc).replace(" ", "-")}


sel = [(pid, steps) for pid, steps in phases if not phase_filter or pid == phase_filter]

if phase_filter and not sel:
    known = ", ".join(pid for pid, _ in phases) or "(none parsed)"
    sys.stderr.write("artifact-check: unknown phase '%s' (known: %s)\n" % (phase_filter, known))
    sys.exit(2)

total_steps = sum(len(s) for _, s in sel)
print("CATALOG: %s" % os.path.relpath(catalog_path, root).replace(os.sep, "/"))
print("ROOT: %s" % root.replace(os.sep, "/"))
print("PHASES: %d" % len(sel))
print("STEPS: %d" % total_steps)

no_check = 0
invalid = 0
rows = []
for pid, steps in sel:
    rows.append("PHASE: %s" % pid)
    for st in steps:
        status, kind, det = evaluate(st["artifact"])
        if status == "NO_CHECK":
            no_check += 1
        if status == "INVALID":
            invalid += 1
        extra = "".join(" %s=%s" % (k, v) for k, v in sorted(det.items()) if v is not None)
        rows.append("  STEP: %s required=%s repeatable=%s check=%s status=%s%s"
                    % (st["id"], str(st["required"]).lower(),
                       str(st["repeatable"]).lower(), kind, status, extra))

# Printed BEFORE the rows so a caller reading top-down knows how much of what
# follows is undetectable-from-disk before it reads any of it.
print("NO_CHECK: %d" % no_check)
for r in rows:
    print(r)
if invalid:
    sys.stderr.write("artifact-check: rejected %d unsafe catalog path(s)\n" % invalid)
    sys.exit(2)
PYEOF
