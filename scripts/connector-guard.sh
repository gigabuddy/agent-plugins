#!/usr/bin/env bash
#
# Gigabuddy — PreToolUse hook: keep the session on the plugin, not a claude.ai
# Gigabuddy connector.
#
# A Gigabuddy connector added on claude.ai syncs into Claude Code (and the
# desktop app's Code mode) as `mcp__claude_ai_<name>__<tool>`, serving the same
# door verbs as this plugin. Its tools act as the connector's OAuth grant agent:
# one identity for every conversation, a different one from this session's
# agent. Replies can't be routed back to the conversation that asked, and a
# consent card names an agent the person isn't talking to (Virginia's desktop
# sessions all showed as one agent until she reconnected, 2026-09-28).
#
# A plugin can't switch a connector off (its settings take only display keys,
# and ENABLE_CLAUDEAI_MCP_SERVERS=false turns off every connector), so this
# hook refuses the connector's calls and points the model at the plugin's own
# tools.
#
# Which connector is ours — people name connectors themselves, so:
#   - a claude.ai connector whose name contains "gigabuddy" (any case): every tool;
#   - any other claude.ai connector: a tool whose name is one of this door's
#     verbs, read from the door menu the agent caches beside its credential
#     (doorMenuCache.ts), except the four names other connectors plausibly
#     share (search, get, log, send_message).
# Anything else passes untouched. Fails open: no jq, no input, no menu → allow.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)

[[ "$TOOL_NAME" == mcp__claude_ai_* ]] || exit 0

REST=${TOOL_NAME#mcp__claude_ai_}
SERVER=${REST%%__*}
TOOL=${REST#*__}
[ -n "$SERVER" ] && [ -n "$TOOL" ] && [ "$TOOL" != "$REST" ] || exit 0

ours=false
shopt -s nocasematch
[[ "$SERVER" == *gigabuddy* ]] && ours=true
shopt -u nocasematch

if [ "$ours" = false ]; then
  case "$TOOL" in
    search | get | log | send_message) exit 0 ;;
  esac
  HOME_DIR=${GIGABUDDY_HOME:-$HOME/.gigabuddy}
  shopt -s nullglob
  for menu in "$HOME_DIR"/door-menu-*.json "$HOME_DIR"/accounts/*/door-menu-*.json; do
    if jq -e --arg t "$TOOL" 'any(.tools[]?; .name == $t)' "$menu" >/dev/null 2>&1; then
      ours=true
      break
    fi
  done
  shopt -u nullglob
fi

[ "$ours" = true ] || exit 0

PLUGIN_TOOL="mcp__plugin_gigabuddy_agent__${TOOL}"
REASON="Don't use the claude.ai Gigabuddy connector (${TOOL_NAME}) in Claude Code: it acts as a different agent from this session, so replies can't find their way back here and approvals name the wrong agent. Use the Gigabuddy plugin's own tool instead: ${PLUGIN_TOOL} (load it with ToolSearch if it's deferred; call connect first if you aren't in a room)."

jq -n --arg reason "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
