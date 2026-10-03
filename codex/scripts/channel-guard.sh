#!/usr/bin/env bash
#
# Gigabuddy — PreToolUse hook: UNATTENDED LOCKDOWN for a channel-started turn.
#
# A Claude Code channel event (a mention, ask, or thread reply addressed to
# this agent — see the agent server's channel bridge) can start a turn while
# the user is away, and it does so with the session's FULL permissions:
# channels have no unattended-mode concept of their own. This hook is the
# enforced half of the safety model. "A mention can get you an answer, but
# can't get your laptop to do things."
#
# WHEN it is active — turn provenance, not a time window:
#   The bridge stamps `unattended.json` BEFORE every wake, and the Stop hook
#   (session-close.sh) writes `turn-ended.json` at the end of every turn; the
#   user's next real prompt (awareness-prompt.sh) clears BOTH. The lockdown
#   applies only when both exist: a wake that arrived, and no user prompt
#   since the last turn ended — i.e. THIS turn was started by the channel.
#   A wake landing mid-turn while the human is at the keyboard (a peer
#   replying in a thread this session follows, a friendly human chatting)
#   has the stamp but no marker, and that turn stays unlocked: the human is
#   watching it. If the queued frame then starts its own turn after Stop, the
#   marker is there and that turn is confined.
#   A prompt is not the only proof of presence: when an "ask" below is answered
#   Yes AT THE KEYBOARD, the human is here too. channel-guard-post.sh
#   (PostToolUse) tells that apart from a verdict the sponsor relayed from the
#   room (the bridge leaves relay-verdict.json for those) and clears the same
#   three files — a locally approved call lifts the lockdown for the rest of
#   the turn; a relayed approval covers that one call only.
#
# WHAT it allows — gated on WHO is asking (decision:AGM9OjIn8GtF), not on
# whether someone is at the keyboard, plus the sponsor's policy file. The
# stamp carries `trust`, computed by the bridge from canonical ids (display
# names are anyone's to set):
#     sponsor — the sender IS the human behind this session;
#     trusted — an agent whose stamped sponsor is that human (a sibling in the
#               sponsor's fleet), or any id the sponsor lists in the policy's
#               `trustedSenders` (how a buddy like Katsu gets vouched for —
#               buddies have no sponsor and any room member can drive them, so
#               they are never trusted by category);
#     other   — everyone else.
#   and, for a trusted sibling, `senderTurn`: how the SIBLING's own turn
#   started, read by the bridge from the sibling's session dir on this disk
#   (never asserted by the sender) — `attended` (the sponsor is driving it),
#   `locked` (it was itself woken, so its request is relayed), `unknown` (its
#   state is not here: another host or repo). A sibling's identity is not the
#   risk — on this host it already shares the user's account and files. Relay
#   is: a stranger wakes the sibling, the sibling chats to us.
#   - Gigabuddy collaboration tools (chat, raise, log, answer, …): allowed.
#     They act in the room under the agent's own server-attributed identity.
#   - Read/Grep/Glob: allowed INSIDE the repository only. Paths outside the
#     launch repo, and dotfiles under $HOME, are denied for everyone — a woken
#     turn posts into a shared room (issue:SxYNJgM3aknV).
#   - Everything else (Edit, Write, Bash, Agent, Web*, other MCP servers):
#       sponsor wake, or attended sibling → "allow": the guard steps aside and
#         the session's OWN permission mode governs (auto-mode classifier,
#         allow/deny rules) — exactly as if the sponsor had typed it.
#       locked/unknown sibling + permission relay on → "ask": Claude Code
#         opens its permission prompt, the bridge relays it to the sponsor as
#         a consent request (card in the thread + their inbox), and only the
#         sponsor's approval answers it — or a Yes at the keyboard, which
#         lifts the lockdown (see channel-guard-post.sh).
#       locked/unknown sibling, relay off → deny (an unanswerable "ask" hangs).
#       other → deny. Reply-and-raise only.
#     The policy file (`<scratch>/channel-policy.json`, sponsor-owned: it lives
#     on the sponsor's disk, not in the room) can tighten or loosen per tool:
#       { "sponsor": { "default": "allow", "tools": { "Bash": "ask" } },
#         "trusted": { "default": "ask", "tools": { … } },
#         "others":  { "default": "deny", "tools": { "WebSearch": "allow" } },
#         "trustedSenders": [{ "id": "buddy:katsu…", "placeId": "place:…" }],
#         "reads":   "repo" | "sponsor-only" | "none" }
#     `gigabuddy trust add <name> --in <room>` writes trustedSenders for you.
#     Values: allow | ask | deny. "ask" degrades to deny when relay is off.
#     The `sponsor` block covers the sponsor and attended siblings; the
#     `trusted` block covers locked/unknown siblings and vouched ids, and never
#     inherits the sponsor's allow. "sponsor-only" reads include trusted.
#   - StructuredOutput: always allowed. It is how a subagent hands its answer
#     back — pure output, no side effect — so gating it protects nothing and
#     silently discards the work (issue:5EldoPFv9RzW).
#
# WHOSE turn — background subagents belong to the turn that spawned them:
#   The two stamps are session-wide, but a Workflow / Agent run the HUMAN
#   started keeps running after the main turn yields (Stop fires while it is
#   in flight). A wake landing then must not confine those subagents: their
#   provenance is the human's prompt, and nothing about it changed when the
#   room spoke. Claude Code marks every hook call made inside a subagent with
#   `agent_id`, and a locked turn cannot spawn a subagent without its
#   Agent/Task/Workflow/Skill call passing THIS guard — so absent evidence to
#   the contrary, every subagent in the session is the human's and runs with
#   the session's own permissions. The evidence: when a locked turn's spawner
#   call resolves to allow or ask, the guard records `locked-spawn.json`, and
#   from then on subagent calls take the woken turn's posture like any other
#   (safe side — needs the relay on, or a policy allow, plus a woken turn
#   choosing to spawn). The human's next prompt clears the marker with the
#   stamps.
#
# HARD-DENY hook: unlike the other gigabuddy hooks this one intentionally
# blocks tool calls. It must therefore fail OPEN on its own errors (a broken
# guard must never brick an attended session) — every parse of the HOOK INPUT
# falls back to "allow". Inside a confirmed unattended window, a malformed
# policy file falls back to the DEFAULTS above, never to open.
#
# Lifted from PR #2516's oncall-guard.sh; the waiter that armed it there is
# replaced by the harness channel.

set -uo pipefail

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -z "$SESSION_ID" ] && exit 0

# shellcheck source=lib/gigabuddy-dir.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/gigabuddy-dir.sh"
GB_DIR="$(gigabuddy_dir)"
SDIR="$GB_DIR/sessions/${GIGABUDDY_SESSION_PREFIX:-cc_}$SESSION_ID"

# Not in an unattended window → allow (the common case, cheap).
# Both files must exist: the wake stamp AND the turn boundary since the last
# user prompt. See "WHEN it is active" above.
[ -f "$SDIR/unattended.json" ] || exit 0
[ -f "$SDIR/turn-ended.json" ] || exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
[ -z "$TOOL_NAME" ] && exit 0

# A call from inside a subagent (`agent_id` set by the harness) belongs to the
# turn that spawned it. Unless a LOCKED turn has been permitted to spawn (the
# marker below), that turn was the human's — allow. See "WHOSE turn" above.
AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)
SPAWN_MARK="$SDIR/locked-spawn.json"
if [ -n "$AGENT_ID" ] && [ ! -f "$SPAWN_MARK" ]; then exit 0; fi

STAMP=$(cat "$SDIR/unattended.json" 2>/dev/null || echo '{}')
STAMP_TS=$(printf '%s' "$STAMP" | jq -r '.ts // "unknown time"' 2>/dev/null || echo "unknown time")
RELAY=$(printf '%s' "$STAMP" | jq -r 'if .relay == true then "true" else "false" end' 2>/dev/null || echo false)
WHO=$(printf '%s' "$STAMP" | jq -r '.from // "someone"' 2>/dev/null || echo someone)
SENDER_ID=$(printf '%s' "$STAMP" | jq -r '.senderId // empty' 2>/dev/null || true)
# `trust` from the bridge; older stamps carry only fromSponsor.
TRUST=$(printf '%s' "$STAMP" | jq -r '.trust // (if .fromSponsor == true then "sponsor" else "other" end)' 2>/dev/null || echo other)
case "$TRUST" in sponsor|trusted|other) : ;; *) TRUST=other ;; esac
# A trusted sibling's own turn provenance (attended / locked / unknown), read
# by the bridge from the sibling's session dir on this disk — never asserted
# by the sender. Older stamps have none: unknown.
SENDER_TURN=$(printf '%s' "$STAMP" | jq -r '.senderTurn // "unknown"' 2>/dev/null || echo unknown)
case "$SENDER_TURN" in attended|locked|unknown) : ;; *) SENDER_TURN=unknown ;; esac

POLICY='{}'
if [ -f "$GB_DIR/channel-policy.json" ]; then
  POLICY=$(jq -c . "$GB_DIR/channel-policy.json" 2>/dev/null || echo '{}')
fi

# The sponsor's explicit vouch list (`gigabuddy trust add …`) promotes an
# `other` sender to `trusted` (never to sponsor). Matched on canonical id
# only; an entry with a placeId applies to wakes from that room alone.
# Entries are {id, placeId?} objects or (legacy) bare id strings.
PLACE_ID=$(printf '%s' "$STAMP" | jq -r '.placeId // empty' 2>/dev/null || true)
if [ "$TRUST" = "other" ] && [ -n "$SENDER_ID" ]; then
  VOUCHED=$(printf '%s' "$POLICY" | jq -r --arg id "$SENDER_ID" --arg place "$PLACE_ID" '
    (.trustedSenders // [])
    | map(if type == "string" then {id: .} else . end)
    | any(.id == $id and ((.placeId // null) == null or .placeId == $place))
  ' 2>/dev/null || echo false)
  [ "$VOUCHED" = "true" ] && TRUST=trusted
fi

deny() {
  local reason="$1"
  local escaped
  escaped=$(printf '%s' "$reason" | jq -Rs . 2>/dev/null) || exit 0
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$escaped"
  exit 0
}

ask() {
  local reason="$1"
  local escaped
  # Record WHICH call was escalated so the PostToolUse half
  # (channel-guard-post.sh) can tell, when it runs, who answered: the sponsor
  # from the room (the bridge leaves a relay-verdict) or the human at the
  # keyboard — whose approval lifts the lockdown like a prompt would.
  local tool_use_id
  tool_use_id=$(printf '%s' "$INPUT" | jq -r '.tool_use_id // empty' 2>/dev/null || true)
  jq -nc --arg tool "$TOOL_NAME" --arg toolUseId "$tool_use_id" --arg agentId "$AGENT_ID" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{tool: $tool, toolUseId: $toolUseId, agentId: $agentId, ts: $ts}' > "$SDIR/asked.json.tmp" 2>/dev/null \
    && mv "$SDIR/asked.json.tmp" "$SDIR/asked.json" 2>/dev/null || true
  escaped=$(printf '%s' "$reason" | jq -Rs . 2>/dev/null) || exit 0
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":%s}}\n' "$escaped"
  exit 0
}

# Name the cause so an operator can tell a lockdown from a broken tool: the
# wake stamp (who, when) and the turn boundary, both under this session's dir.
TAIL="The lockdown lifts when the user next types in this session, or approves one of these prompts at the keyboard (an approval relayed from the room covers that one call only). Cause: $SDIR/unattended.json (wake from $WHO at $STAMP_TS) together with turn-ended.json in the same dir — a wake arrived and no human prompt has followed. (Set GIGABUDDY_CHANNEL_GUARD=open before launching to disable it; $GB_DIR/channel-policy.json tunes it per tool.)"

# --- 1. Collaboration surface: always allowed -------------------------------
# StructuredOutput is a subagent's return value, not an action on the machine.
case "$TOOL_NAME" in
  mcp__*gigabuddy*__*) exit 0 ;;
  ToolSearch|TaskOutput|ListAgents|AskUserQuestion|StructuredOutput) exit 0 ;;
esac

# --- 2. Reads: inside the repo only, never dotfiles under $HOME ---------------
case "$TOOL_NAME" in
  Read|Grep|Glob)
    READS=$(printf '%s' "$POLICY" | jq -r '.reads // "repo"' 2>/dev/null || echo repo)
    case "$READS" in
      none) deny "Unattended lockdown: file reads are disabled by this session's channel policy while the user is away. Reply in the thread and capture any requested work with \`raise\`. $TAIL" ;;
      sponsor-only)
        [ "$TRUST" != "other" ] || deny "Unattended lockdown: this turn was started by $WHO, who is not this session's sponsor or one of the sponsor's agents, and the channel policy limits reads to those wakes. Reply in the thread and capture any requested work with \`raise\`. $TAIL"
        ;;
    esac

    # The path the tool will touch. Grep/Glob default to cwd when no path is given.
    TARGET=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null || true)
    PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
    REPO_ROOT=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PROJECT_DIR")
    [ -n "$TARGET" ] || TARGET="$PROJECT_DIR"
    case "$TARGET" in
      /*) : ;;
      ~*) TARGET="${HOME}${TARGET#\~}" ;;
      *) TARGET="$PROJECT_DIR/$TARGET" ;;
    esac
    # Resolve symlinks where the path exists; a not-yet-existing path resolves lexically.
    RESOLVED=$(cd "$(dirname "$TARGET")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$TARGET")") || RESOLVED="$TARGET"
    REPO_RESOLVED=$(cd "$REPO_ROOT" 2>/dev/null && pwd -P) || REPO_RESOLVED="$REPO_ROOT"

    # Dotfiles directly under $HOME (~/.ssh, ~/.zshrc, ~/.claude, ~/.config …)
    # and env files anywhere: secrets by convention, refused for everyone.
    case "$RESOLVED" in
      "$HOME"/.*|*/.env|*/.env.*)
        deny "Unattended lockdown: reading $RESOLVED is refused while the user is away, whoever asked — dotfiles under \$HOME and env files hold secrets, and a woken turn posts into a shared room. $TAIL" ;;
    esac
    case "$RESOLVED" in
      "$REPO_RESOLVED"|"$REPO_RESOLVED"/*) exit 0 ;;
    esac
    deny "Unattended lockdown: $RESOLVED is outside this session's repository ($REPO_RESOLVED); while the user is away reads stay inside the repo. $TAIL"
    ;;
esac

# --- 3. Everything else: the sponsor's posture for this tool -----------------
# decision:AGM9OjIn8GtF — gated on WHO is asking, not on whether someone is at
# the keyboard. The sponsor, or a sibling the sponsor is driving, runs as if
# the sponsor had typed: the guard steps aside ("allow") and the session's OWN
# permission mode governs from here. A sibling that is itself in a locked turn
# is passing someone's words on; one whose state is not on this disk cannot be
# told apart — both ask. "Allow" here is not "unrestricted".
case "$TRUST" in
  sponsor)
    POSTURE=$(printf '%s' "$POLICY" | jq -r --arg t "$TOOL_NAME" '.sponsor.tools[$t] // .sponsor.default // "allow"' 2>/dev/null || echo allow)
    SUBJECT="your sponsor ($WHO)"
    ;;
  trusted)
    if [ "$SENDER_TURN" = "attended" ]; then
      # The sponsor's own posture: they are the one asking, through their agent.
      POSTURE=$(printf '%s' "$POLICY" | jq -r --arg t "$TOOL_NAME" '.sponsor.tools[$t] // .sponsor.default // "allow"' 2>/dev/null || echo allow)
      SUBJECT="$WHO, an agent your sponsor is driving (its own turn is attended)"
    else
      # The trusted block stands on its own — it never inherits the sponsor's
      # allow, because this request may have been relayed from a stranger.
      POSTURE=$(printf '%s' "$POLICY" | jq -r --arg t "$TOOL_NAME" '.trusted.tools[$t] // .trusted.default // "ask"' 2>/dev/null || echo ask)
      SUBJECT="$WHO, an agent your sponsor trusts whose own turn is $SENDER_TURN (its request may itself have been relayed from someone else)"
    fi
    ;;
  *)
    POSTURE=$(printf '%s' "$POLICY" | jq -r --arg t "$TOOL_NAME" '.others.tools[$t] // .others.default // "deny"' 2>/dev/null || echo deny)
    SUBJECT="$WHO, who is not this session's sponsor"
    ;;
esac
case "$POSTURE" in
  allow|ask|deny) : ;;
  *) POSTURE=deny ;;
esac
# An "ask" needs someone able to answer it: with the relay off the local
# dialog would sit unanswered until the user returns. Deny instead.
if [ "$POSTURE" = "ask" ] && [ "$RELAY" != "true" ]; then POSTURE=deny; fi

# A locked turn about to spawn subagents (allowed outright, or handed to the
# sponsor to approve — we cannot see the verdict, so count the attempt): from
# here on, subagent calls are no longer presumed the human's. See "WHOSE turn".
if [ "$POSTURE" != "deny" ]; then
  case "$TOOL_NAME" in
    Agent|Task|Workflow|Skill)
      printf '{"ts":"%s","tool":"%s","from":%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TOOL_NAME" \
        "$(printf '%s' "$WHO" | jq -Rs . 2>/dev/null || echo '""')" > "$SPAWN_MARK.tmp" 2>/dev/null \
        && mv "$SPAWN_MARK.tmp" "$SPAWN_MARK" 2>/dev/null || true
      ;;
  esac
fi

case "$POSTURE" in
  allow) exit 0 ;;
  ask) ask "Unattended: this turn was started by $SUBJECT while the user is away. $TOOL_NAME needs the sponsor's approval — the prompt is relayed to them as a consent request (a card in the room thread and their inbox) and only the sponsor can approve it; if the user is in fact at this keyboard, their Yes here lifts the lockdown for the rest of the turn. If it is not approved, reply in the thread and capture the work with \`raise\`. $TAIL" ;;
  *) deny "Unattended lockdown: this turn was started by $SUBJECT while the user is away, so only conversation and in-repo reads are allowed — the gigabuddy tools, Read/Grep/Glob. Reply in the thread, capture any requested work with \`raise\`, and stop. $TAIL" ;;
esac
