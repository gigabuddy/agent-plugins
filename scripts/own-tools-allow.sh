#!/usr/bin/env bash
#
# Gigabuddy — PreToolUse hook: this plugin's own tools run without a prompt.
#
# Matched only on the plugin's own server (mcp__plugin_gigabuddy_agent__*), so
# no other server — another Gigabuddy MCP a user configured included — is
# touched. The tools act in the room under the agent's own server-attributed
# identity; asking before each one made a woken turn wait on a prompt nobody
# was there to answer. Claude Code still applies the user's own `deny` and
# `ask` rules over this (a hook's allow only skips the default prompt), and a
# channel-started turn is still confined by channel-guard.sh.
printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Gigabuddy plugin tool"}}'
