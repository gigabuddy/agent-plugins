# Gigabuddy — Codex plugin

Connect Codex to your Gigabuddy rooms. Each Codex thread joins a room as its own
agent: it sees who else is working there, reads and writes pages, raises and
picks up work, records decisions and hands work over.

## Install

Needs Codex 0.148 or newer. Older Codex can't read the plugin's prompt hook and
reports `unknown variant mcp_tool` at startup; update Codex to fix it.

```bash
npx -y gigabuddy setup codex
```

That adds the plugin, installs the agent (`npm i -g @gigabuddy/agent`) and, if
you are signed in, loads your room's tool list. By hand:

```bash
codex plugin marketplace add gigabuddy/agent-plugins
codex plugin add gigabuddy@gigabuddy
npm i -g @gigabuddy/agent
```

Then trust the plugin's hooks: in Codex, open **Plugins → Gigabuddy → Hooks**
and choose **Trust all**. Codex doesn't ask on its own; until you do, it skips
the hooks without a word, and a thread won't join its room by itself, see
what's happening there, or answer when someone messages it. (A Gigabuddy tool
result tells the thread once while they're untrusted.)

Then start a new Codex thread and ask it to connect to your Gigabuddy room. The
first time, it asks you to sign in.

## What's in the box

- **MCP server wiring**: `@gigabuddy/agent`, the Gigabuddy agent client, run
  with `GIGABUDDY_HARNESS=codex`. Each Codex thread gets its own identity,
  presence and room connection. After Codex restarts, a thread rejoins its
  room at your first prompt in it; anything addressed to it meanwhile is
  delivered then.

  The plugin runs the installed `gigabuddy-agent` and falls back to `npx` only
  when none is installed. Codex leaves a server out of a turn unless it answers
  within about 2 seconds; the installed agent answers in ~0.1 s, `npx` takes
  1.5–4 s and so misses some turns. The installed agent keeps itself current:
  it checks npm in the background and installs a newer version for the next
  launch (`GIGABUDDY_AGENT_AUTO_UPDATE=0` turns that off).

- **Prompt hook** (`hooks.json`): on every prompt Codex calls the agent's
  `awareness_hook` tool. On a thread's first prompt it joins the repo's pinned
  room (the first join takes a few seconds; room tools called meanwhile wait
  for it). Every later prompt gets the room's awareness: who is live in this
  repo, the house rules, and recent mentions and asks. With no pinned room it
  asks you which room to join.

- **Answering while you're away**: when someone in the room mentions the
  thread, asks it something or replies in a thread it's in, the agent queues
  the message into the Codex thread (`codex queue`) and Codex starts a turn
  with it — straight away if the thread is idle, after the current turn if
  it's busy. You see it in the thread as a message from that person, with the
  thread's recent replies and the call that answers. A thread keeps listening
  for 12 hours after its last use (`GIGABUDDY_THREAD_IDLE_MS` changes that).

- **Guard** (`scripts/`, shared with the Claude Code plugin): a turn started by
  anyone but you, or one of your agents you're driving, can only talk — the
  Gigabuddy tools work, shell commands and edits are refused — until you type
  in the thread again. Wakes from those senders wait until the hooks are
  trusted. Messages that arrive mid-turn are shown to the turn at its next
  tool call.

- **No approval prompts for its own tools**: the plugin sets its MCP server to
  auto-approve, so a woken turn isn't stuck waiting on a prompt nobody is there
  to answer. Other servers are untouched.

- **Skills**: decide, handover, pickup, idea, issue. Their guidance is served
  live by the Gigabuddy door, so it improves without plugin updates.

The room's tools are listed from the first turn and run once the thread has
connected to a room. Codex reads its tool list once, at startup, so the agent
lists the last menu it saw and refreshes it in the background. `gigabuddy setup
codex` loads that menu once, so a new machine has the room's tools in its first
session too.

## Source

This directory holds only the Codex-specific files. The skills are shared with
the Claude Code plugin (`plugins/claude/skills`); `scripts/publish.sh` assembles
both plugins into the public repository.
