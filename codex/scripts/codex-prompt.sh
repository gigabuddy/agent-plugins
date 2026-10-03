#!/usr/bin/env bash
#
# Gigabuddy — Codex UserPromptSubmit hook: a real prompt ends any unattended
# lockdown.
#
# When someone in the room addresses an idle thread, the agent stamps
# `unattended.json` and queues the wake as the thread's next user message
# (codexWake.ts); the Stop hook marks every turn's end (`turn-ended.json`).
# channel-guard.sh confines a turn only while BOTH exist. This is the human
# typing — clear them, with the guard's other per-lockdown files — unless the
# prompt IS the queued wake: it carries the `<gigabuddy-wake …/>` marker line
# (codexWake.ts renderCodexWake), so the turn is wake-started and the stamps
# must stand. A human prompt that happens to contain the marker only keeps the
# lockdown on — the safe direction.
#
# It also leaves `~/.gigabuddy/codex-hooks.json`, the agent's proof that this plugin's
# command hooks are trusted and running: Codex skips an unapproved hook
# silently, and without the PreToolUse guard a wake from anyone but the
# sponsor would run with the thread's full permissions — so the agent only
# wakes for those once this marker exists (and tells a thread to trust the
# hooks while it doesn't). `gen` names this hook set; a
# change to the guard's hook definitions (which asks for trust again) bumps it
# here and in the agent (CODEX_HOOKS_GEN).
#
# The room awareness and auto-join for the prompt come from the agent's
# `awareness_hook` (an mcp_tool hook beside this one); this script only
# touches files. It never blocks and fails open.

set -uo pipefail

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -z "$SESSION_ID" ] && exit 0

# shellcheck source=lib/gigabuddy-dir.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/gigabuddy-dir.sh"
GB_DIR="$(gigabuddy_dir)"
SDIR="$GB_DIR/sessions/${GIGABUDDY_SESSION_PREFIX:-cx_}$SESSION_ID"
# The trust marker is user-level: hook trust belongs to the Codex install, not
# to a repo, and a thread in a repo it hasn't joined from yet has no scratch dir.
HOME_DIR="${GIGABUDDY_HOME:-$HOME/.gigabuddy}"
mkdir -p "$HOME_DIR" 2>/dev/null \
  && printf '{"gen":1,"ts":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$HOME_DIR/codex-hooks.json.$$" 2>/dev/null \
  && mv "$HOME_DIR/codex-hooks.json.$$" "$HOME_DIR/codex-hooks.json" 2>/dev/null || true

[ -d "$SDIR" ] || exit 0

PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || true)
case "$PROMPT" in
  *'<gigabuddy-wake '*) : ;;
  *) rm -f "$SDIR/unattended.json" "$SDIR/turn-ended.json" "$SDIR/locked-spawn.json" \
          "$SDIR/asked.json" "$SDIR/relay-verdict.json" 2>/dev/null || true ;;
esac
exit 0
