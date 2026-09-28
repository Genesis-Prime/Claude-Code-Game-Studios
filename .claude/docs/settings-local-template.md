# settings.local.json Template

Create `.claude/settings.local.json` for personal overrides that should NOT
be committed to version control. Add it to `.gitignore`.

## Example settings.local.json

```json
{
  "permissions": {
    "allow": [
      "Read",
      "Glob",
      "Grep"
    ],
    "deny": [
      "Bash(rm -rf *)",
      "Bash(git push --force *)"
    ]
  }
}
```

Project `ask` and `deny` rules still override local `allow` entries. In
particular, local settings cannot bypass prompts for framework edits, network
tools, inline interpreter code, or `.claude/scripts/run-project-command.py run`.
Keep command allow rules narrow and inspect the exact argv before approving a
project command.

Keep Bash commands approval-gated. Wildcard Git, package-manager, Python, and
test-runner grants can execute repository-controlled helpers, plugins, or code
even when the command appears read-only.

## Permission Modes

Claude Code supports different permission modes. Recommended for game dev:

### During Development (Default)
Use **normal mode** — Claude asks before running most commands. This is safest
for production code.

### During Prototyping
Use **auto-accept mode** with limited scope — faster iteration on throwaway code.
Only use this when working in `prototypes/` directory.

Where supported, enable Claude Code's sandbox for shell commands. Permission
patterns decide when to prompt; the sandbox supplies the filesystem and network
containment boundary.

### During Code Review
Use **read-only** permissions — Claude can read and search but not modify files.

## Customizing Hooks Locally

You can add personal hooks in `settings.local.json` that extend (not override)
the project hooks. For example, adding a notification when builds complete:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "date -u",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```
