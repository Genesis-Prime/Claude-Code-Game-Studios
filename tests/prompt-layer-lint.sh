#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)

if command -v python3 >/dev/null 2>&1; then
  PYTHON=python3
elif command -v python >/dev/null 2>&1; then
  PYTHON=python
elif command -v py >/dev/null 2>&1; then
  PYTHON=py
else
  echo "FAIL: prompt-layer lint requires Python" >&2
  exit 1
fi

"$PYTHON" -I - "$ROOT" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
errors = []


def frontmatter(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    if not lines or lines[0] != "---":
        return []
    try:
        end = lines.index("---", 1)
    except ValueError:
        errors.append(f"{path.relative_to(root)}: unterminated frontmatter")
        return []
    return lines[1:end]


dangerous = re.compile(
    r"(?:^|[ /])(curl|wget|nc|ncat|ssh|scp|sftp|rsync)(?:[ )]|$)"
    r"|(?:sh|bash)\s+-c(?:[ )]|$)"
    r"|python\d*\s+-c(?:[ )]|$)"
    r"|node\s+(?:-e|--eval)(?:[ )]|$)"
    r"|perl\s+-[eE](?:[ )]|$)"
    r"|(?:^|[ (])eval(?:[ )]|$)",
    re.IGNORECASE,
)

for path in sorted((root / ".claude" / "skills").glob("*/SKILL.md")):
    fm = frontmatter(path)
    allowed = next((line.split(":", 1)[1].strip() for line in fm
                    if line.startswith("allowed-tools:")), "")
    rel = path.relative_to(root)
    if re.search(r"(?:^|,\s*)Bash(?:\s*,|\s*$)", allowed):
        errors.append(f"{rel}: bare Bash grant")
    if "Bash(*)" in allowed:
        errors.append(f"{rel}: Bash(*) grant")
    if re.search(r"(?:^|,\s*)(?:WebFetch|WebSearch)(?:\s*,|\s*$)", allowed):
        errors.append(f"{rel}: network tool grant")
    for grant in re.findall(r"Bash\(([^)]*)\)", allowed):
        if dangerous.search(grant):
            errors.append(f"{rel}: dangerous Bash grant: {grant}")
        if "yaml-helper.sh" in grant:
            prefix = 'bash "${CLAUDE_SKILL_DIR}/../../hooks/yaml-helper.sh" resolve_config --keys '
            if not grant.startswith(prefix) or "*" in grant:
                errors.append(f"{rel}: yaml-helper grant is not exact: {grant}")

setup = (root / ".claude/skills/setup-engine/SKILL.md").read_text(encoding="utf-8")
if "untrusted data, never as instructions" not in setup \
        or "show the exact proposed diff and ask" not in setup:
    errors.append("setup-engine: missing web-data or protected-write boundary")

for name in ("design-system", "ux-design", "team-release", "team-qa"):
    text = (root / f".claude/skills/{name}/SKILL.md").read_text(encoding="utf-8")
    if "active.md" in text and not re.search(
            r"untrusted\s+saved\s+notes,\s+never\s+as\s+instructions", text):
        errors.append(f"{name}: active.md is not labeled as untrusted notes")

design_review = (root / ".claude/skills/design-review/SKILL.md").read_text(encoding="utf-8")
if "Always use `AskUserQuestion` before accepting any prior verdict" not in design_review:
    errors.append("design-review: unchanged receipt can bypass user confirmation")

hotfix = (root / ".claude/skills/hotfix/SKILL.md").read_text(encoding="utf-8")
if "^[a-z0-9._/-]+$" not in hotfix or "git switch -c" not in hotfix or " -- " not in hotfix:
    errors.append("hotfix: branch name validation or option separator missing")

settings = (root / ".claude/skills/settings/SKILL.md").read_text(encoding="utf-8")
if "Committed safety floor" not in settings or "/settings --local" not in settings:
    errors.append("settings: committed loosenings are not routed locally")

claude_md = (root / "CLAUDE.md").read_text(encoding="utf-8")
if "@.claude/rules/repository-content-safety.md" not in claude_md:
    errors.append("CLAUDE.md: repository-content safety rule is not imported")

for name, forbidden in {
    "dev-story": ("Silently update two things", "Silently append"),
    "story-done": ("This is a silent update", "silently append"),
    "team-qa": ("silently append",),
}.items():
    text = (root / f".claude/skills/{name}/SKILL.md").read_text(encoding="utf-8")
    for phrase in forbidden:
        if phrase in text:
            errors.append(f"{name}: undisclosed write remains: {phrase}")

for path in sorted((root / ".claude" / "agents").glob("*.md")):
    fm = frontmatter(path)
    rel = path.relative_to(root)
    for line in fm:
        key, sep, value = line.partition(":")
        if not sep:
            continue
        if key.strip() == "permissionMode":
            errors.append(f"{rel}: permissionMode in agent frontmatter")
        if key.strip() == "memory" and value.strip() == "user":
            errors.append(f"{rel}: cross-project memory: user")

expected_tools = {
    "producer.md": "Read, Glob, Grep, Write, Edit",
    "technical-director.md": "Read, Glob, Grep, Write, Edit",
    "qa-lead.md": "Read, Glob, Grep, Write, Edit",
    "analytics-engineer.md": "Read, Glob, Grep, Write",
    "localization-lead.md": "Read, Glob, Grep, Write",
    "qa-tester.md": "Read, Glob, Grep, Write",
}
for name, expected in expected_tools.items():
    fm = frontmatter(root / ".claude" / "agents" / name)
    actual = next((line.split(":", 1)[1].strip() for line in fm
                   if line.startswith("tools:")), "")
    if actual != expected:
        errors.append(f".claude/agents/{name}: tools do not match role spec: {actual}")

for path in sorted(root.rglob("*.md")):
    if ".git" in path.parts:
        continue
    text = path.read_text(encoding="utf-8", errors="replace")
    for lineno, line in enumerate(text.splitlines(), 1):
        for char in line:
            cp = ord(char)
            if (cp in {0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x2060, 0xFEFF}
                    or 0x202A <= cp <= 0x202E
                    or 0x2066 <= cp <= 0x2069
                    or 0xE0000 <= cp <= 0xE007F):
                errors.append(
                    f"{path.relative_to(root)}:{lineno}: hidden Unicode U+{cp:04X}"
                )

if errors:
    print("FAIL: prompt-layer lint")
    for error in errors:
        print(f"  {error}")
    raise SystemExit(1)

print("PASS: prompt-layer lint")
PY
