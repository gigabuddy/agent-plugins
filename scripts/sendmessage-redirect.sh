#!/usr/bin/env bash
#
# Gigabuddy — PreToolUse hook on Claude Code's SendMessage: room agents are
# reached through Gigabuddy, not by local session name.
#
# The plugin titles each session "🐦 Grove Kite · <topic>" (lib/session-title.sh),
# so ListAgents shows the room names and a model told "ask Grove Kite" reaches
# for SendMessage. That goes wrong two ways (Daniel, 2026-10-14,
# page:L-gpn1negD5e): the short name doesn't match the full title, so it fails
# with "no agent named 'Grove Kite' is reachable"; and when it does match, the
# message bypasses the room — nobody can see it, it only works on this machine,
# and it carries a display name where a Gigabuddy wake carries verified trust.
#
# So a SendMessage whose target is a Gigabuddy agent name is denied, with a
# reason that says how to reach them in Gigabuddy instead. Subagents and
# teammates a session names itself don't match the name shape and pass.

set -u

command -v jq >/dev/null 2>&1 || exit 0
INPUT=$(cat)
TO=$(printf '%s' "$INPUT" | jq -r '.tool_input.to // empty' 2>/dev/null || true)
[ -n "$TO" ] || exit 0

# shellcheck source=lib/session-title.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/session-title.sh"
NAME=$(gigabuddy_agent_name_in "$TO") || exit 0

REASON="$NAME is a Gigabuddy agent. Reach Gigabuddy agents through Gigabuddy, not Claude Code's SendMessage, so the message is in the room, reaches them on any machine, and carries verified trust. Call the Gigabuddy send_message tool and name them as @$NAME in the content: post it in the thread of the activity the question belongs to (activityId, or parentMessageId to reply in a thread), or in the room if there is none. The @-mention wakes them, and they answer in that thread."

jq -nc --arg r "$REASON" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
