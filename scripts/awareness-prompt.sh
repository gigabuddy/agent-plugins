#!/usr/bin/env bash
#
# Gigabuddy — UserPromptSubmit hook
#
# Runs at the start of each turn. Three jobs:
#   1. Register this Claude Code session so the MCP server can auto-connect
#      with a stable identity (writes a pending-connect file the server polls).
#   2. Re-baseline the agent on the full current peer state of the place.
#   3. First-run onboarding nudges: not-signed-in (once per session) and
#      statusline-not-configured (once ever) — both agent-mediated offers,
#      since neither can be automated at plugin-install time.
#
# Best-effort throughout: never fail the prompt. The scratch dir is shared
# with the MCP server and is computed identically (project-local .gigabuddy).

set -uo pipefail

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -z "$SESSION_ID" ] && exit 0

# Repo-root anchored so worktrees share one state dir with the MCP server.
# shellcheck source=lib/gigabuddy-dir.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/gigabuddy-dir.sh"
GB_DIR="$(gigabuddy_dir)"
# This session's own dir — every per-session file lives here (one id scheme,
# the host session id verbatim; mirrors sessionDir() in scratch.ts).
SDIR="$GB_DIR/sessions/cc_$SESSION_ID"

# Has this machine signed in at all? client-core writes THREE credential kinds
# (shared / user / agent — libs/client-core/src/lib/credentials.ts), each with a
# staging sibling, and a multi-account setup keeps a copy of every store under
# accounts/<name>/ (accounts.ts). This used to stat the shared pair alone, so an
# agent- or user-only login — which is what the plugin's own `login` writes —
# read as "never signed in" and nudged on the first prompt of EVERY session
# (issue:C7j959GnfM--). Glob the stores instead: a new credential kind cannot
# reintroduce the bug.
#
# The credential home is client state (~/.gigabuddy, GIGABUDDY_HOME per
# accounts.ts CONFIG_DIR) — deliberately NOT gigabuddy_dir(), which resolves the
# repo-local .gigabuddy scratch dir this script shares with the MCP server.
#
# Pure bash, no forks: this runs on every prompt. An unmatched glob expands to
# itself, which the -f test then rejects.
has_gigabuddy_credentials() {
  local home="${GIGABUDDY_HOME:-$HOME/.gigabuddy}" f
  for f in "$home"/*credentials*.json "$home"/accounts/*/*credentials*.json; do
    [ -f "$f" ] && return 0
  done
  return 1
}

# --- 0. A real prompt ends any unattended lockdown ---------------------------
# The channel bridge stamps unattended.json before waking a session and the
# Stop hook marks every turn's end (turn-ended.json); channel-guard.sh locks
# only when BOTH exist — a wake, and no human prompt since the last turn ended.
# THIS is the human prompt: clear both, plus the guard's "a locked turn was
# permitted to spawn subagents" marker (locked-spawn.json) — a new human turn
# re-establishes that every running subagent is the human's. Unless the prompt
# itself is the injected channel event (guarded in case the harness routes
# those through this hook too) — then the turn is channel-started and all
# three must stand. The guard's ask bookkeeping (asked.json, and the bridge's
# relay-verdict.json — see channel-guard-post.sh) goes with them: it only
# describes the lockdown that just ended.
{
  PROMPT_HEAD=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null | head -c 12 || true)
  case "$PROMPT_HEAD" in
    "<channel"*) : ;;
    *) rm -f "$SDIR/unattended.json" "$SDIR/turn-ended.json" "$SDIR/locked-spawn.json" \
            "$SDIR/asked.json" "$SDIR/relay-verdict.json" 2>/dev/null || true ;;
  esac
} || true

# --- 1. Register session for the server's deferred auto-connect -------------
{
  if [ -d "$GB_DIR" ]; then
    mkdir -p "$SDIR" 2>/dev/null || true
    PC="$SDIR/pending-connect.json"
    printf '{"claudeSessionId":"%s","ts":"%s"}\n' \
      "$SESSION_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$PC.tmp" 2>/dev/null \
      && mv "$PC.tmp" "$PC" 2>/dev/null || true
    # A prompt is activity: touch the outbox ts so lastActiveAt (peers' idle
    # clock, and the cache-warmth proxy) updates on prompts too, not only on
    # tool calls. Without this a conversational session reads as idle forever.
    # Same atomic tmp+mv as the PreToolUse writer; last writer wins, both fine.
    OB="$SDIR/outbox.json"
    TS_NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [ -f "$OB" ]; then
      jq --arg ts "$TS_NOW" '.ts = $ts' "$OB" > "$OB.tmp" 2>/dev/null \
        && mv "$OB.tmp" "$OB" 2>/dev/null || true
    else
      printf '{"ts":"%s"}\n' "$TS_NOW" > "$OB.tmp" 2>/dev/null \
        && mv "$OB.tmp" "$OB" 2>/dev/null || true
    fi
  fi
} || true

# --- 2. Inject the full peer baseline ---------------------------------------
# Read the inbox for THIS session, not a stale one from a dead session.
INBOX="$SDIR/inbox.json"
if [ ! -f "$INBOX" ]; then
  # Not connected because the agent never started: the launcher recorded why
  # (launch-agent.mjs). Its stand-in server told the agent too, but a nudge to
  # sign in or `connect` would now be wrong advice. A failure from before this
  # session began (the statusline's wait stamp, else the last 30 min) belongs to
  # a session long gone. Once per session.
  FAIL="$GB_DIR/agent-launch-failure.txt"
  if [ -f "$FAIL" ]; then
    FT=""
    FMSG=""
    { IFS= read -r FT && IFS= read -r FMSG; } <"$FAIL" 2>/dev/null || true
    SINCE=$(( $(date +%s) - 1800 ))
    [ -f "$SDIR/statusline-wait" ] && IFS= read -r SINCE <"$SDIR/statusline-wait" && SINCE=$((SINCE - 120))
    case "$FT" in
      '' | *[!0-9]*) FT=0 ;;
    esac
    if [ -n "$FMSG" ] && [ "$FT" -ge "$SINCE" ] 2>/dev/null; then
      NUDGE_FLAG="${TMPDIR:-/tmp}/gigabuddy-launch-nudge-$SESSION_ID"
      if [ ! -f "$NUDGE_FLAG" ]; then
        : > "$NUDGE_FLAG" 2>/dev/null || true
        NUDGE="Gigabuddy's agent failed to start: $FMSG. None of the Gigabuddy tools work this session — tell the user in one line when Gigabuddy comes up; don't call login or connect."
        ESCAPED=$(printf '%s' "$NUDGE" | jq -Rs . 2>/dev/null) \
          && printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' "$ESCAPED"
      fi
      exit 0
    fi
  fi

  # Not connected. Usually the server is just booting — but a user who has
  # never signed in will NEVER connect, and nothing tells them why (the
  # server's stderr hint is invisible in normal use, and the login tool may
  # be deferred out of the agent's visible tool list). Surface it once per
  # session so the agent offers the in-chat `login` flow.
  if ! has_gigabuddy_credentials; then
    NUDGE_FLAG="${TMPDIR:-/tmp}/gigabuddy-login-nudge-$SESSION_ID"
    if [ ! -f "$NUDGE_FLAG" ]; then
      : > "$NUDGE_FLAG" 2>/dev/null || true
      NUDGE="Gigabuddy is installed but not signed in, so awareness/presence is inactive. At a natural moment this turn, offer to sign the user in: call the gigabuddy \`login\` tool and relay the URL + code it returns (the gigabuddy tools exist but may be deferred — find them via tool search, never by searching the filesystem). One-time setup. If the user declines, drop it — this hint is once per session."
      ESCAPED=$(printf '%s' "$NUDGE" | jq -Rs . 2>/dev/null) \
        && printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' "$ESCAPED"
    fi
    exit 0
  fi

  # Signed in but not connected. Usually a join is seconds away (the server
  # auto-joins the repo's pinned room on this very prompt) — say nothing. But a
  # repo with NO pin and no cached place of its own never auto-joins, and
  # nothing used to tell the agent, so it ran the whole session with only the
  # pre-connect tool list (issue:4C85a7IYkilv). The server writes its
  # resolution to autoconnect.json at boot; fall back to the pin file if that
  # hasn't landed yet. Once per session.
  AC_KIND=$(jq -r '.kind // empty' "$SDIR/autoconnect.json" 2>/dev/null || true)
  if [ -z "$AC_KIND" ]; then
    [ -f "$GB_DIR/default-place.json" ] && AC_KIND="pinned" || AC_KIND="none"
  fi
  # Which room is the PERSON's call, not the agent's: a "last room used" hint
  # read as the answer, and an agent joined a room one other session had
  # wandered into (task:Iy6JadJJ6QOF). List the candidates, never rank them.
  if [ "$AC_KIND" = "none" ] || [ "$AC_KIND" = "ambiguous" ]; then
    NUDGE_FLAG="${TMPDIR:-/tmp}/gigabuddy-connect-nudge-$SESSION_ID"
    if [ ! -f "$NUDGE_FLAG" ]; then
      : > "$NUDGE_FLAG" 2>/dev/null || true
      # The ambiguous case names the rooms recent sessions split between;
      # otherwise offer every room this repo has used.
      CANDIDATES=""
      if [ "$AC_KIND" = "ambiguous" ]; then
        CANDIDATES=$(jq -r --slurpfile sp "$GB_DIR/sanctioned-places.json" \
          '[.placeIds[]? as $id | ($sp[0].places // [] | map(select(.placeId == $id)) | .[0].placeName // $id) + " (" + $id + ")"] | join(", ")' \
          "$SDIR/autoconnect.json" 2>/dev/null || true)
      fi
      [ -z "$CANDIDATES" ] && CANDIDATES=$(jq -r '[.places[]? | "\(.placeName // .placeId) (\(.placeId))"] | join(", ")' \
        "$GB_DIR/sanctioned-places.json" 2>/dev/null || true)
      [ -z "$CANDIDATES" ] && CANDIDATES=$(jq -r '[.placeIds[]?] | join(", ")' "$SDIR/autoconnect.json" 2>/dev/null || true)
      NUDGE="Gigabuddy: signed in but NOT connected. This repo has no default room"
      [ "$AC_KIND" = "ambiguous" ] && NUDGE="$NUDGE and its recent sessions were in different rooms"
      NUDGE="$NUDGE, so no auto-join happened. The work/page/ledger/inbox verbs (search, read_work, raise, decide, inbox, pickup_work, …) only appear once connected."
      [ -n "$CANDIDATES" ] && NUDGE="$NUDGE Rooms this repo has used: $CANDIDATES."
      NUDGE="$NUDGE Before doing anything that needs those verbs, ASK the user which room to join — don't pick one yourself, not even the most recent. Then call the gigabuddy \`connect\` tool with that placeId (the gigabuddy tools may be deferred; find them via tool search); its result says how to offer making that room the repo's default. If the user's request doesn't need Gigabuddy, mention the offline state in one line and carry on. Once per session."
      ESCAPED=$(printf '%s' "$NUDGE" | jq -Rs . 2>/dev/null) \
        && printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' "$ESCAPED"
    fi
  fi
  exit 0
fi

INBOX_JSON=$(cat "$INBOX" 2>/dev/null || echo '{}')
SEQ=$(printf '%s' "$INBOX_JSON" | jq -r '.seq // 0' 2>/dev/null || echo 0)
EVENT_COUNT=$(printf '%s' "$INBOX_JSON" | jq '.events | length' 2>/dev/null || echo 0)

# Read place name from connection.json if available
PLACE_NAME=""
CONN_FILE="$GB_DIR/connection.json"
if [ -f "$CONN_FILE" ]; then
  PLACE_NAME=$(jq -r '.placeName // empty' "$CONN_FILE" 2>/dev/null || true)
fi

SELF_REPO=$(jq -r '.repo // empty' "$SDIR/outbox.json" 2>/dev/null || true)
# When THIS server process booted (it stamps autoconnect.json at startup).
BOOT_TS=$(jq -r '.ts // empty' "$SDIR/autoconnect.json" 2>/dev/null || true)
CONTEXT=$(printf '%s' "$INBOX_JSON" | jq -r --arg placeName "$PLACE_NAME" --arg selfRepo "$SELF_REPO" --arg bootTs "$BOOT_TS" --argjson now "$(date +%s)" '
  # Snapshot freshness: inbox.json is rewritten whenever any peer frame arrives
  # (at least every heartbeat while the socket lives), so a snapshot minutes old
  # means something is off — everything below is then a guess, and saying so
  # beats rendering stale peers as live. Two distinct causes, told apart by the
  # server boot stamp:
  #   - server booted AFTER the snapshot → a previous process of this same
  #     session wrote it (claude --resume, /reload-plugins, a crash or reboot);
  #     the new server rejoins the room at boot, so the join is landing NOW —
  #     not a dead connection, and never grounds to declare Gigabuddy offline;
  #   - same server → OUR socket is down; the sidecar reconnects on its own
  #     heartbeat, and session_status is the live truth, not this file.
  def iso: sub("\\.[0-9]+";"") | try fromdateiso8601 catch null;
  ((.ts // "") | iso) as $snapTs |
  ($now - ($snapTs // $now)) as $snapAge |
  (($bootTs | iso) as $boot | $boot != null and $snapTs != null and $boot > $snapTs) as $restarted |
  "You are " + .self.displayName
  + (if $placeName != "" then " in " + $placeName else "" end)
  + ( if $restarted then
        "\nℹ The Gigabuddy server restarted after this snapshot (session resumed / plugin reloaded) and is rejoining the room now — the door verbs reappear once joined. Do NOT treat Gigabuddy as offline: if a verb you need is missing, call session_status and retry. Peer info below is from before the restart."
      elif $snapAge >= 180 then
        "\n⚠ Awareness snapshot is " + (($snapAge/60)|floor|tostring) + "m old — the live socket may be down (it reconnects on its own heartbeat). Call session_status before treating Gigabuddy as offline; peer info below may be stale."
      else "" end )
  + "\n"
  # Peer ROSTER RETIRED (2026-08-22, idea:OJuidt4hrY_b): the full per-turn
  # listing (every peer, absolute `touching:` paths, idle clocks) cost ~10 KB a
  # turn in a busy room with near-zero actionable content. Until the awareness
  # digest lands (page:OaPM-L3NmeCg), render ONE summary line — counts plus the
  # live peers sharing this repo — and point at get_awareness for the roster.
  # Conflict events still arrive via the PreToolUse hook; events render below.
  + ( (.peers // []) as $ps
      | ([ $ps[] | select(
            ( (.beatAt == null) or (($now * 1000 - .beatAt) < 90000) )
            and ( (.lastActiveAt == null)
                  or (($now - ( .lastActiveAt | sub("\\.[0-9]+";"") | try fromdateiso8601 catch $now )) < (.coldSecs // 3600)) )
          ) ]) as $live
      # Same repo = same repoId when both sides publish one (display names
      # collide across worktrees/forks); the name match is the old-peer fallback.
      | (.self.repoId // "") as $selfRepoId
      | ((.self.repo // "") | if . != "" then . else $selfRepo end) as $selfRepoName
      | ([ $live[] | select(
            if ($selfRepoId != "" and (.repoId // "") != "") then .repoId == $selfRepoId
            else ($selfRepoName != "" and .repo == $selfRepoName) end
          ) | .displayName ]) as $here
      | "Peers: " + ($ps | length | tostring) + " in the room · " + ($live | length | tostring) + " live"
        + (if ($here | length) > 0 then " · live in this repo: " + ($here | join(", ")) else "" end)
        + " (get_awareness for the full roster)" )
  # House rules: standing directives for this place, re-stamped every turn
  # (headlines only — the connect briefing carried the full block).
  + ( if ((.houseRules // []) | length) > 0 then
      "\nHouse rules here (standing directives):\n"
      + ([.houseRules[] | "  ▸ " + .] | join("\n"))
    else "" end )
  + ( if (.events | length) > 0 then
      "\nRecent activity:\n" + ([.events[-8:][] |
        if .type == "peer_joined" then "  → \(.peer) joined"
        elif .type == "peer_left" then "  ← \(.peer) left"
        elif .type == "peer_changed" then "  △ \(.peer): \(.detail)"
        elif .type == "conflict" then "  ⚠ \(.peer) also editing \(.files | join(", "))"
        elif .type == "page_updated" then "  📄 \(.detail) updated by \(.peer)"
        elif .type == "attachment" then "  📎 \(.peer) attached \(.detail) to your activity"
        elif .type == "mention" then "  💬 \(.peer) mentioned you: \(.detail)" + (if .threadId then " [reply in thread \(.threadId)]" else "" end)
        elif .type == "thread_reply" then "  💬 \(.peer) replied in a thread you follow: \(.detail // "")" + (if .threadId then " [thread \(.threadId)]" else "" end)
        elif .type == "ask" then "  📨 ASK for you from \(.peer): \(.detail // "")" + (if .threadId then " [discuss in thread \(.threadId)]" else "" end)
        elif .type == "attention" then "  👀 \(.detail // "")" + (if .threadId then " [session \(.threadId)]" else "" end)
        elif .type == "named" then "  · \(.peer) named you without an @-mention (did not wake you): \(.detail // "")" + (if .threadId then " [thread \(.threadId)]" else "" end)
        else "  \(.type): \(.peer)" end
      ] | join("\n"))
    else "" end )
' 2>/dev/null || true)

# --- 3. One-time statusline setup offer --------------------------------------
# Claude Code does NOT apply a plugin settings.json `statusLine` (only the
# `agent`/`subagentStatusLine` keys are honored from plugin settings), so the
# gigabuddy status bar needs an entry in the USER's own settings. If no
# statusLine is configured anywhere, nudge the agent ONCE EVER (persistent
# flag) to offer wiring it up in-chat. Any existing statusLine — gigabuddy or
# not — means stay silent: never offer to clobber the user's own status bar.
if [ -n "$CONTEXT" ] && [ ! -f "$HOME/.gigabuddy/statusline-nudge-shown" ]; then
  if ! grep -qs '"statusLine"' \
      "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json" \
      "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/settings.json" \
      "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/settings.local.json"; then
    mkdir -p "$HOME/.gigabuddy" 2>/dev/null || true
    : > "$HOME/.gigabuddy/statusline-nudge-shown" 2>/dev/null || true
    SL_NUDGE=""
    # Quoted heredoc: the snippet must land verbatim (no expansion here).
    IFS= read -r -d '' SL_NUDGE <<'SLEOF' || true
One-time setup offer — the Gigabuddy status bar isn't wired up (Claude Code ignores plugin statusline settings, so it needs one entry in the user's own settings). At a natural moment, offer it: a live status line showing place, peers, current activity, and idle time at the bottom of the terminal. If the user wants it, merge this top-level key into ~/.claude/settings.json (preserve their other settings) and tell them to restart Claude Code:

  "statusLine": {
    "type": "command",
    "command": "bash -c 'script=$(ls -td ~/.claude/plugins/cache/gigabuddy/gigabuddy/*/scripts/statusline.sh 2>/dev/null | head -1); [ -f \"$script\" ] && exec \"$script\" || echo \"🍄 no plugin\"'",
    "refreshInterval": 5
  }

If they decline, drop it — this offer never repeats.
SLEOF
    [ -n "$SL_NUDGE" ] && CONTEXT="$CONTEXT

$SL_NUDGE"
  fi
fi

# Baseline the seq so the PreToolUse hook only injects deltas from here on.
mkdir -p "$SDIR" 2>/dev/null || true
printf '{"lastSeenSeq":%s,"lastEventCount":%s}\n' "$SEQ" "$EVENT_COUNT" \
  > "$SDIR/hook-state.json.tmp" 2>/dev/null \
  && mv "$SDIR/hook-state.json.tmp" "$SDIR/hook-state.json" 2>/dev/null || true

# --- 4. Session title carries the room name ----------------------------------
# "🐺 Plum Wolf · <title>" on the session and its terminal tab, so a person
# with many sessions open can match each to its agent (lib/session-title.sh).
SESSION_TITLE_OUT=""
SESSION_TITLE_HINT=""
{
  # shellcheck source=lib/session-title.sh
  . "$(dirname "${BASH_SOURCE[0]}")/lib/session-title.sh"
  SELF_NAME=$(printf '%s' "$INBOX_JSON" | jq -r '.self.displayName // empty' 2>/dev/null || true)
  CUR_TITLE=$(printf '%s' "$INPUT" | jq -r '.session_title // empty' 2>/dev/null || true)
  # Claude's own topic title isn't in the hook input; it is the transcript's
  # last "ai-title" line (re-appended as the topic moves; ~20 ms on a 2 MB file).
  TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
  TOPIC=""
  [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] &&
    TOPIC=$(grep -a '"type":"ai-title"' "$TRANSCRIPT" 2>/dev/null | tail -1 | jq -r '.aiTitle // empty' 2>/dev/null || true)
  [ -n "$SELF_NAME" ] && gigabuddy_session_title "$SELF_NAME" "$CUR_TITLE" "$TOPIC" "$SDIR"
} || true

if [ -n "$CONTEXT" ] || [ -n "$SESSION_TITLE_OUT" ]; then
  jq -nc --arg ctx "$CONTEXT" --arg hint "$SESSION_TITLE_HINT" --arg title "$SESSION_TITLE_OUT" '
    {hookSpecificOutput: (
      {hookEventName: "UserPromptSubmit"}
      + (if $ctx != "" then
           {additionalContext: ("Gigabuddy awareness —\n" + $ctx + (if $hint != "" then "\n" + $hint else "" end))}
         else {} end)
      + (if $title != "" then {sessionTitle: $title} else {} end)
    )}'
fi

exit 0
