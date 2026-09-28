#!/usr/bin/env python3
"""Allow only the framework's reviewed agent roster at the Agent boundary."""

import json
import sys


MAX_EVENT_BYTES = 1024 * 1024
ALLOWED = {
    "Explore", "Plan", "general-purpose",
    "accessibility-specialist", "ai-programmer", "analytics-engineer",
    "art-director", "audio-director", "community-manager",
    "creative-director", "devops-engineer", "economy-designer",
    "engine-programmer", "game-designer", "gameplay-programmer",
    "godot-csharp-specialist", "godot-gdextension-specialist",
    "godot-gdscript-specialist", "godot-shader-specialist",
    "godot-specialist", "lead-programmer", "level-designer",
    "live-ops-designer", "localization-lead", "narrative-director",
    "network-programmer", "performance-analyst", "producer", "prototyper",
    "qa-lead", "qa-tester", "release-manager", "security-engineer",
    "sound-designer", "systems-designer", "technical-artist",
    "technical-director", "tools-programmer", "ue-blueprint-specialist",
    "ue-gas-specialist", "ue-replication-specialist", "ue-umg-specialist",
    "ui-programmer", "unity-addressables-specialist", "unity-dots-specialist",
    "unity-shader-specialist", "unity-specialist", "unity-ui-specialist",
    "unreal-specialist", "ux-designer", "world-builder", "writer",
}


def main():
    data = sys.stdin.buffer.read(MAX_EVENT_BYTES + 1)
    if len(data) > MAX_EVENT_BYTES:
        sys.stderr.write("BLOCKED: Agent event exceeds the 1 MiB safety limit\n")
        return 2
    try:
        event = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        sys.stderr.write("BLOCKED: Agent event is not valid UTF-8 JSON\n")
        return 2
    tool_input = event.get("tool_input")
    if not isinstance(tool_input, dict):
        sys.stderr.write("BLOCKED: Agent event has no tool_input object\n")
        return 2
    agent_type = tool_input.get("subagent_type", tool_input.get("agent_type"))
    if not isinstance(agent_type, str) or agent_type not in ALLOWED:
        sys.stderr.write("BLOCKED: unreviewed agent type {!r}\n".format(agent_type))
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
