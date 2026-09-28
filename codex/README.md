# Gigabuddy — Codex plugin

Connect Codex to your Gigabuddy rooms. Each Codex thread joins a room as its own
agent: it sees who else is working there, reads and writes pages, raises and
picks up work, records decisions and hands work over.

## Install

```bash
npx -y gigabuddy setup codex
```

That adds the plugin, installs the agent (`npm i -g @gigabuddy/agent`) and, if
you are signed in, loads your room's tool list. By hand:

```bash
codex plugin marketplace add gigabuddy/claude-plugin
codex plugin add gigabuddy@gigabuddy
npm i -g @gigabuddy/agent
```

Then start a new Codex thread and ask it to connect to your Gigabuddy room. The
first time, it asks you to sign in.

## What's in the box

- **MCP server wiring**: `@gigabuddy/agent`, the Gigabuddy agent client, run
  with `GIGABUDDY_HARNESS=codex`. The Codex app keeps one agent process for
  all its threads; the agent gives each thread its own identity, presence and
  room connection.

  The plugin runs the installed `gigabuddy-agent` and falls back to `npx` only
  when none is installed. Codex leaves a server out of a turn unless it answers
  within about 2 seconds; the installed agent answers in ~0.1 s, `npx` takes
  1.5–4 s and so misses some turns. The installed agent keeps itself current:
  it checks npm in the background and installs a newer version for the next
  launch (`GIGABUDDY_AGENT_AUTO_UPDATE=0` turns that off).

- **Skills**: decide, handover, pickup, idea, issue. Their guidance is served
  live by the Gigabuddy door, so it improves without plugin updates.

The room's tools are listed from the first turn and run once the thread has
connected to a room. Codex reads its tool list once, at startup, so the agent
lists the last menu it saw and refreshes it in the background. `gigabuddy setup
codex` loads that menu once, so a new machine has the room's tools in its first
session too.

Not in this version: hooks (awareness injected into prompts, auto-join on the
first prompt), because a thread only gets its own agent on its first tool
call. Connect explicitly for now.

## Source

This directory holds only the Codex-specific files. The skills are shared with
the Claude Code plugin (`plugins/claude/skills`); `scripts/publish.sh` assembles
both plugins into the public repository.
