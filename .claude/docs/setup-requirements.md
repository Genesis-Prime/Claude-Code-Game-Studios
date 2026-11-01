# Setup Requirements

This template requires a few tools to be installed for full functionality.
Most hooks fail gracefully if tools are missing: nothing breaks, but you lose
validation features. The exception is Python 3: the commit, push and agent
validation hooks block (exit 2) without it rather than let an unvalidated
command through, and the commit and push hooks run on every Bash tool call,
so without Python Claude Code cannot run any shell command in this project.

## Required

| Tool | Purpose | Install |
| ---- | ---- | ---- |
| **Git** | Version control, branch management | [git-scm.com](https://git-scm.com/) |
| **Claude Code** | AI agent CLI | `npm install -g @anthropic-ai/claude-code` |
| **Python 3 with `-I` isolated mode** | Commit, push and agent validation (these hooks block without it), config parsing, JSON validation, secure log writes, and session checkpoint snapshots | [python.org](https://www.python.org/) |

## Recommended

| Tool | Used By | Purpose | Install |
| ---- | ---- | ---- | ---- |
| **jq** | Hooks (6 of 13) | Exact JSON parsing of hook input in the asset, skill-change, agent-audit, notification and session-stop hooks; each falls back to `grep` without it | See below |
| **Bash** | All hooks | Shell script execution | Included with Git for Windows |

### Installing jq

**Windows** (any of these):
```
winget install jqlang.jq
choco install jq
scoop install jq
```

**macOS**:
```
brew install jq
```

**Linux**:
```
sudo apt install jq     # Debian/Ubuntu
sudo dnf install jq     # Fedora
sudo pacman -S jq       # Arch
```

## Platform Notes

### Windows
- Git for Windows includes **Git Bash**, which provides the `bash` command
  used by all hooks in `settings.json`
- Ensure Git Bash is on your PATH (default if installed via the Git installer)
- Hooks use `bash .claude/hooks/[name].sh` — this works on Windows because
  Claude Code invokes commands through a shell that can find `bash.exe`

### macOS / Linux
- Bash is available natively
- Install `jq` via your package manager for exact hook input parsing

## Verifying Your Setup

Run these commands to check prerequisites:

```bash
git --version          # Should show git version
bash --version         # Should show bash version
jq --version           # Should show jq version (optional)
python3 --version      # Should show Python 3 (required for commit, push and agent validation)
```

## What Happens Without Optional Tools

| Missing Tool | Effect |
| ---- | ---- |
| **jq** | No check is skipped. The six hooks that use jq read their input with a `grep` fallback instead, which is less exact on unusual paths. Commit, push and agent validation do not use jq. |
| **Python 3 with `-I`** | `validate-commit.sh`, `validate-push.sh` and `validate-agent.sh` print `BLOCKED: Python 3 isolated mode is required ...` and exit 2. The first two run on every Bash tool call, so every shell command (not only `git commit` and `git push`) is refused, and the third refuses every subagent spawn, until Python is installed. Asset JSON validation warns that the file was not checked. Agent audit log writes fail with a message. Config parsing reports that it could not run. Automatic session checkpoint previews and archives are skipped rather than reading an untrusted path. |
| **Both** | As without Python: shell commands and subagent spawns are blocked; the other hooks exit 0 with reduced or no validation. |

## Optional Performance Settings

CCGS deliberately ships **no** values for the settings below. Each one's best
value depends on your machine, your Claude plan and how you work, so a value
committed here would be a guess every user inherits without noticing. Set the
ones you want in `.claude/settings.local.json`, which is gitignored and yours
alone.

| Setting | What it does | When to change it |
| ---- | ---- | ---- |
| `promptCacheTtl` | How long the main conversation's prompt cache lives. | Raise it if you work in long sessions with gaps; the cache surviving a break avoids re-sending context. |
| `subagentPromptCacheTtl` | The same, for subagents and other off-conversation requests. | Worth raising on a 49-agent project like this one, where `team-*` skills spawn repeatedly. |
| `autoCompactWindow` | How full the context gets before Claude Code compacts it. | Lower it if compaction keeps surprising you mid-task; raise it if you would rather compact less often and keep more history. |
| `skillListingBudgetFraction` | How much context the skill listing may occupy. | CCGS ships 74 skills, so the listing is not small. Lower it if you want more room for work; `skillListingMaxDescChars` trims each description instead. |

`sandbox.enabled` isolates shell commands from your filesystem and network. It
is worth turning on, but it runs on **macOS, Linux and WSL2 only** — it is not
available on native Windows, which is CCGS's primary platform.

CCGS also ships `permissions.ask` rules for framework edits, network clients,
inline interpreter code, and typed project-command runs. Ask rules override
skill grants and local allow rules, but Bash command matching is best-effort;
the sandbox remains the stronger boundary on supported platforms.

### One setting CCGS does ship

`permissions.defaultMode` is set to `default` in `.claude/settings.json`, on
purpose. It makes Claude Code ask before acting, which is what every approval
gate in this framework depends on. Project settings outrank personal ones, so
this holds even if your own config sets `acceptEdits` or `auto` — otherwise
CCGS's collaboration protocol would be silently switched off for you and the
agents would write files you never approved.

If you genuinely want it off, override it in `.claude/settings.local.json`,
which takes precedence. Understand what you are turning off first.

## Recommended IDE

Claude Code works with any editor, but the template is optimized for:
- **VS Code** with the Claude Code extension
- **Cursor** (Claude Code compatible)
- Terminal-based Claude Code CLI
