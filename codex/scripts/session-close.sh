#!/usr/bin/env bash
#
# Gigabuddy — Stop hook: the staged session's end-of-turn prompt
#
# Session kernel (decision:85dxOsnuuz2L; plan page:o2nInoTllp4w §7): an agent
# conversation working inside a STAGED SESSION produces pages / ideas /
# decisions that stay with the session until it publishes ONE digest to the
# room. "Conversation end" for an agent is the end of a turn — there is no
# later moment the model can still act in (SessionEnd cannot inject context).
# So at Stop, when the focused activity is a staged session, nudge the three
# ways forward: session_publish / keep open / complete_activity. Close ≠
# discard: nothing here ever closes or deletes anything — sessions are
# durable handles; leaving one open is always safe.
#
# Rate-limited (one nudge per 10 minutes per session) so a long working
# conversation isn't nagged every turn, and silent when the session isn't
# staged, not connected, or has NOTHING PENDING (issue:0fqxnBEHYg56: a
# session whose output is a PR, not pages, was nudged every ten minutes to
# review a change set of zero). The pending count is the server's, carried
# into the inbox by its session beats; when the inbox does not know it
# (null), the nudge stands — unknown must never read as "nothing to do".
# Reads only the inbox file the MCP server writes — hooks have no network and
# no MCP access.
#
# Second job, unconditional and first: mark the turn boundary. The channel
# lockdown (channel-guard.sh) is keyed on turn PROVENANCE — it locks only when
# a wake stamp exists AND no user prompt has happened since the last turn
# ended. This marker is the "turn ended" half; awareness-prompt.sh clears it
# on the human's next real prompt. Without it a wake landing mid-turn would
# lock a turn the human is watching.

set -uo pipefail

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -z "$SESSION_ID" ] && exit 0

# shellcheck source=lib/gigabuddy-dir.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/gigabuddy-dir.sh"
GB_DIR="$(gigabuddy_dir)"
SDIR="$GB_DIR/sessions/${GIGABUDDY_SESSION_PREFIX:-cc_}$SESSION_ID"

# --- 0. Turn boundary marker (see header) -----------------------------------
{
  if [ -d "$GB_DIR" ]; then
    mkdir -p "$SDIR" 2>/dev/null || true
    TE="$SDIR/turn-ended.json"
    printf '{"ts":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TE.tmp" 2>/dev/null \
      && mv "$TE.tmp" "$TE" 2>/dev/null || true
  fi
} || true

INBOX="$SDIR/inbox.json"
[ -f "$INBOX" ] || exit 0   # not connected → nothing to say

MODE=$(jq -r '.self.sessionMode // empty' "$INBOX" 2>/dev/null || true)
[ "$MODE" = "staged" ] || exit 0
ACTIVITY_ID=$(jq -r '.self.activityId // empty' "$INBOX" 2>/dev/null || true)
LABEL=$(jq -r '.self.activityLabel // empty' "$INBOX" 2>/dev/null || true)
[ -n "$ACTIVITY_ID" ] || exit 0
# jq's `//` keeps a 0 (only null/false fall through), so a known-empty session
# reads "0" and an unknown count reads "unknown".
PENDING=$(jq -r '.self.sessionPendingCount // "unknown"' "$INBOX" 2>/dev/null || echo unknown)
[ "$PENDING" = "0" ] && exit 0   # nothing unpublished → nothing to say (and no nudge stamp)

NOW=$(date +%s)
NS="$SDIR/session-close-nudge.json"
LAST=0
[ -f "$NS" ] && LAST=$(jq -r '.ts // 0' "$NS" 2>/dev/null || echo 0)
[ "$(( NOW - LAST ))" -ge 600 ] || exit 0
printf '{"ts":%s}\n' "$NOW" > "$NS.tmp" 2>/dev/null && mv "$NS.tmp" "$NS" 2>/dev/null || true

case "$PENDING" in
  unknown) HAVE="Anything you produced in it is not in the room yet." ;;
  1)       HAVE="1 unpublished item is not in the room yet." ;;
  *)       HAVE="$PENDING unpublished items are not in the room yet." ;;
esac
MSG="Staged session open: \"$LABEL\" ($ACTIVITY_ID). $HAVE Before you stop: session_review $ACTIVITY_ID to see the change set, then either session_publish $ACTIVITY_ID (ONE digest lands in the room; default set = everything pending, session_annotate to opt items out), keep it open (it is durable — nothing is lost; publish later), or complete_activity when the work has landed (it refuses while change is unpublished unless allowUnpublished:true). Never discard — unpublished work stays attributed to the session."

jq -n --arg msg "$MSG" '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":$msg}}' 2>/dev/null || true
exit 0
