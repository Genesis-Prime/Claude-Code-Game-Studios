# Roadmap

Draft assembled on 2026-11-01 from the repo's own docs, TODOs, open issues and pull requests, and an audit of the code. Priorities are Michael's call.

For this fork, open issues and pull requests were not queried (no GitHub API); the sources are the local clone's history and the files in the repo.

## Where it stands

This is Michael's fork of Donchitos's Claude Code Game Studios at framework version 1.1.1 (`project.yaml`; `CHANGELOG.md`, 2026-09-24). Since then the fork has added only security hardening, merged as PRs #8, #9 and #10 between 2026-09-26 and 2026-09-28 (git history). That work covers narrowed skill grants, ask and deny rules, isolated-mode Python, validated checkpoints, fork-owned CODEOWNERS and security reporting, and a CI matrix on Windows, macOS and Linux (`CHANGELOG.md`, "Unreleased"). The template ships no game: 49 agents, 74 skills, 13 wired hooks, 14 rules and 39 templates (audit 2026-11-01).

## Planned (from the repo's own docs)

- Give Forbidden Patterns and Allowed Libraries a `project.yaml` equivalent. Today they live only in `.claude/docs/technical-preferences.md`, which "has no equivalent structure for them yet" (`docs/migration-guide-v1.1.md`; `CHANGELOG.md` 1.1.0, "Deprecated"; `UPGRADING.md`).
- Six settings are documented and accepted but nothing reads them: `accessibility.target`, `cadence.sprint_length`, `cadence.milestone_length`, `strict_gate_checks`, `project.kind`, `features.token_budget_warn_at` (`CHANGELOG.md` 1.1.0, "Settings that don't do anything yet").
- About 30 files under `.claude/` still name `src/` literally, which is correct for Godot and wrong for Unity (`Assets/`) and Unreal (`Source/<Module>/`) (`.claude/docs/directory-structure.md`, "Known residual").

## Known gaps

- From 1.1.0's known limitations, CI on macOS and Linux now runs the framework's own checks (`.github/workflows/ci.yml`). Two still stand: no Unity or Unreal project was compiled, and some engine reference details are marked unverified (`CHANGELOG.md` 1.1.0, "Known limitations").
- The agent-side `model:` field is "untested, not known-broken"; a skill's `model:` is declared but not applied (`.claude/docs/coordination-rules.md`).
- Agent Teams are experimental and have never been used here (`.claude/docs/agent-teams.md`; `.claude/docs/coordination-rules.md`).
- CI pins Python 3.9 (`.github/workflows/ci.yml`). This audit ran the seven CI steps on Linux with Python 3.13 only; 3.9, macOS and Windows were not run locally (audit 2026-11-01).
- Whether `python -I -c` in the CI Python-compile step hits the `Bash(python -c *)` ask rule inside Claude Code has not been tested (audit 2026-11-01).
- Upstream activity after 2026-09-24 has not been checked against the fork (audit 2026-11-01).
- Skill checks (`/skill-test`, `/skill-improve`) run only inside Claude Code, and nothing in CI runs them (audit 2026-11-01; `CCGS Skill Testing Framework/README.md`).

## Open questions

- Keep pulling upstream (Donchitos) releases into the fork? If so, name the remote `template`, as `UPGRADING.md` does, or `upstream`? (audit 2026-11-01)
- Should the README's upstream clone URL, Community links, sponsor badges and `.github/FUNDING.yml` stay pointed at Donchitos? They are correct for a fork today. (audit 2026-11-01)
- Does the story-ID commit rule in `.claude/docs/coding-standards.md` apply to framework work, or only to games built from the template? `AGENTS.md` reads it as the latter. (audit 2026-11-01)
- Should upstream text with em dashes be left alone to keep merges clean (current choice), or rewritten? (audit 2026-11-01)
