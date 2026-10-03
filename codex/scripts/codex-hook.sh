#!/usr/bin/env bash
#
# Gigabuddy — runs one of the shared hook scripts for a Codex thread.
#
# The hook scripts are shared with the Claude Code plugin (assemble-codex.sh
# copies them in beside this file) and read the same stdin payload — Codex
# sends Claude's shape: session_id (the thread id), cwd, prompt, tool_name,
# tool_input. The one difference is the session dir: a Codex thread's agent
# keeps its state under `sessions/cx_<threadId>`, not `cc_<id>`.
#
# Usage (hooks.json): codex-hook.sh <script.sh>

export GIGABUDDY_SESSION_PREFIX=cx_
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  */* | "") exit 0 ;;
esac
[ -x "$HERE/$1" ] || exit 0
exec "$HERE/$1"
