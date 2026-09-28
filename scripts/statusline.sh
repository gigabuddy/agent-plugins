#!/usr/bin/env bash
#
# Gigabuddy — Status line reader (forkless).
#
# The heavy lifting moved into the MCP server (statuslineRenderer.ts), which
# renders `.gigabuddy/sessions/cc_<sessionId>/statusline.txt` event-driven — on inbox
# changes, transcript appends, HEAD flips, host-pressure changes. This script
# is a pure-bash reader: it parses the session id off stdin, reads that file,
# and formats the two time-varying bits (idle clock, office-hours countdown)
# with shell builtins. It spawns ZERO child processes — the old script forked
# ~20 (jq/git/awk/stat/…) per refresh per session, which at a dozen sessions
# was most of a dev container's idle CPU.
#
# File format (v1, written atomically by the renderer):
#   v1 <aliveEpoch> <lastTurnEpoch|0> <coldSecs> <ohUntilEpoch|0>
#   <line1 — live status, with {{IDLE}} and optional {{OHMIN}} placeholders>
#   <line2 — location context; may be empty>
#
# Claude pipes the session JSON on stdin.

shopt -s extglob

# Epoch clock. %(...)T is a printf builtin (bash ≥4.2) — the forkless clock.
# Stock macOS bash is 3.2 and doesn't have it; fall back to ONE `date` fork per
# refresh there. That's negligible on a laptop running a couple of sessions —
# the forkless design exists for container hosts running dozens, and those have
# a modern bash.
NOW=""
printf -v NOW '%(%s)T' -1 2>/dev/null || NOW=""
[[ $NOW == +([0-9]) ]] || NOW=$(date +%s 2>/dev/null)
[[ $NOW == +([0-9]) ]] || NOW=0

# Read all of stdin (builtin; JSON has no NULs so -d '' reads to EOF).
INPUT=""
IFS= read -r -d '' INPUT || true

SID=""
[[ $INPUT =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && SID=${BASH_REMATCH[1]}
PD=""
[[ $INPUT =~ \"project_dir\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && PD=${BASH_REMATCH[1]}
[[ -z $PD ]] && PD=${CLAUDE_PROJECT_DIR:-$PWD}

# Locate the rendered file. Server and hooks both anchor the scratch dir on the
# REPOSITORY ROOT (lib/gigabuddy-dir.sh, mirroring scratch.ts), so a worktree and
# its main checkout resolve to the same place and this is a direct lookup.
#
# The upward search this replaces was a workaround for the split it fixes: the
# server wrote under ITS cwd while this script searched from the project dir, so
# a mid-session worktree switch left them looking at different dirs — which is
# what surfaced as a false "(offline)".
# shellcheck source=lib/gigabuddy-dir.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/gigabuddy-dir.sh"
GB_DIR="$(CLAUDE_PROJECT_DIR="$PD" gigabuddy_dir)"
SDIR="$GB_DIR/sessions/cc_$SID"
F=""
if [[ -n $SID && -f $SDIR/statusline.txt ]]; then
  F=$SDIR/statusline.txt
fi

# Persist the harness-reported context window for the MCP server. Claude Code
# ≥2.1.x sends `context_window.context_window_size` on this stdin — the ONLY
# place the true window (incl. the [1m] plans) is machine-readable — and the
# server can't see stdin, so this reader is the bridge (claudeContext.ts reads
# it as the `harness` window source). Write-on-change: one page-cache read per
# refresh, a write only when the value first appears or changes. Still no forks.
# Runs even before the renderer's file exists so the server has the window at
# first render — and since both sides now resolve the same repo-root dir, the
# pre-boot location is already the server's own rather than a guess.
if [[ -n $SID && -n $GB_DIR ]] &&
  [[ $INPUT =~ \"context_window_size\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
  CTXLINE="v1 ${BASH_REMATCH[1]}"
  [[ -d $SDIR ]] || mkdir -p "$SDIR" 2>/dev/null || true
  CF=$SDIR/ctxwin.txt
  OLDCTX=""
  [[ -f $CF ]] && IFS= read -r OLDCTX <"$CF"
  [[ $OLDCTX != "$CTXLINE" ]] && printf '%s\n' "$CTXLINE" >"$CF" 2>/dev/null
fi

if [[ -z $F ]]; then
  # Renderer hasn't produced a line yet. EVERY fresh session passes through here
  # for the first seconds (the server boots, resolves the session, writes the
  # file), so the default message must be calm and claim nothing. Only when the
  # file is still missing after a grace period is something actually wrong —
  # usually a resident server that predates the forkless renderer (plugin
  # updated while it was running) or a server that failed to boot — and a
  # restart of Claude Code is the fix for both. A wait-stamp (epoch of the
  # first miss, written via redirection — still no forks) is how this stateless
  # reader tells "just booting" from "stuck".
  if [[ -n $SID && -n $GB_DIR && $NOW != 0 ]]; then
    [[ -d $SDIR ]] || mkdir -p "$SDIR" 2>/dev/null || true
    W=$SDIR/statusline-wait
    T0=""
    [[ -f $W ]] && IFS= read -r T0 <"$W"
    if [[ $T0 != +([0-9]) ]]; then
      T0=""
      printf '%s\n' "$NOW" >"$W" 2>/dev/null || true
    fi
    # The launcher (launch-agent.mjs) records WHY when no agent could start —
    # say that instead of guessing. Only a failure from around this session's
    # start counts; an older one belongs to a session long gone.
    FT=""
    FMSG=""
    if [[ -f $GB_DIR/agent-launch-failure.txt ]]; then
      { IFS= read -r FT && IFS= read -r FMSG; } <"$GB_DIR/agent-launch-failure.txt" 2>/dev/null
    fi
    if [[ $FT == +([0-9]) && -n $FMSG ]] && ((FT >= ${T0:-$NOW} - 120)); then
      echo "🍄 gigabuddy failed to start: $FMSG"
      exit 0
    fi
    if [[ -n $T0 ]] && ((NOW - T0 >= 30)); then
      echo "🍄 gigabuddy isn't starting — restart Claude Code to reload the plugin"
      exit 0
    fi
  fi
  echo "🍄 gigabuddy starting…"
  exit 0
fi

META=""
L1=""
L2=""
{
  IFS= read -r META
  IFS= read -r L1
  IFS= read -r L2
} <"$F"

VER=""
ALIVE=0
LASTTURN=0
COLD=3600
OHUNTIL=0
read -r VER ALIVE LASTTURN COLD OHUNTIL _ <<<"$META"
if [[ $VER != v1 ]]; then
  echo "🍄 gigabuddy"
  exit 0
fi

# Idle clock: hidden under a minute; ❄ once the prompt cache is presumably cold.
IDLE_REPL=""
if [[ $LASTTURN == +([0-9]) ]] && ((LASTTURN > 0)) && ((NOW >= LASTTURN)); then
  ((S = NOW - LASTTURN))
  ((M = S / 60))
  if ((M >= 1)); then
    if ((M < 60)); then
      T="${M}m"
    else
      ((H = M / 60, R = M % 60))
      T="${H}h"
      ((R > 0)) && T="${H}h${R}m"
    fi
    [[ $COLD == +([0-9]) ]] && ((COLD > 0)) && ((S >= COLD)) && T="$T ❄"
    IDLE_REPL=" · 🕐 $T"
  fi
fi
L1=${L1/'{{IDLE}}'/$IDLE_REPL}

# Office-hours countdown (origin windows only; the renderer re-renders the
# line without the segment once the window expires — we just fill minutes).
if [[ $OHUNTIL == +([0-9]) ]] && ((OHUNTIL > 0)); then
  ((LEFT = (OHUNTIL - NOW) / 60))
  ((LEFT < 0)) && LEFT=0
  L1=${L1/'{{OHMIN}}'/$LEFT}
fi

# Liveness: the renderer re-stamps aliveEpoch every 30s; if it stopped, flag it.
[[ $ALIVE == +([0-9]) ]] && ((NOW - ALIVE > 90)) && L1="$L1 · ⚡↓"

if [[ -n $L2 ]]; then
  printf '%s\n%s\n' "$L1" "$L2"
else
  printf '%s\n' "$L1"
fi
