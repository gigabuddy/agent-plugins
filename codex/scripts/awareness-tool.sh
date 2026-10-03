#!/usr/bin/env bash
#
# Gigabuddy — PreToolUse hook
#
# Two INDEPENDENT, best-effort jobs. Neither may ever block or deny the tool,
# and one failing must not kill the other:
#
#   (a) inbound  — inject NEW awareness events since last seen, deduped on the
#                  server's presence version (the inbox `seq`). Silent if the
#                  version hasn't advanced. Pure local file read, no socket.
#   (b) outbound — broadcast enriched state: current file, recent file history,
#                  repo, branch, and derived intent from the tool name.
#                  Written to the outbox the server polls. Fire-and-forget.
#                  Paths under the repo root are written REPO-RELATIVE (with
#                  `root` saying relative to what); the agent normalizes the
#                  rest — nothing machine-local is ever broadcast
#                  (decision:OaXqlRbYuEPM).
#
# The scratch dir is shared with the MCP server, computed identically.

set -uo pipefail

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -z "$SESSION_ID" ] && exit 0

# Repo-root anchored so worktrees share one state dir with the MCP server.
# shellcheck source=lib/gigabuddy-dir.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/gigabuddy-dir.sh"
GB_DIR="$(gigabuddy_dir)"
SDIR="$GB_DIR/sessions/${GIGABUDDY_SESSION_PREFIX:-cc_}$SESSION_ID"

# --- (b) outbound: broadcast enriched awareness state (fire-and-forget) -------
{
  if [ -d "$GB_DIR" ]; then
    TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
    CUR_FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // .tool_input.file // .tool_input.command // empty' 2>/dev/null || true)

    # Derive intent from tool name
    INTENT=""
    case "$TOOL_NAME" in
      Read)              INTENT="reading" ;;
      Edit|Write|MultiEdit|NotebookEdit) INTENT="editing" ;;
      Bash)
        CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
        case "$CMD" in
          git\ *)        INTENT="git" ;;
          nx\ test*|npx\ nx\ test*|npx\ vitest*) INTENT="testing" ;;
          nx\ build*|npx\ nx\ build*) INTENT="building" ;;
          nx\ lint*|npx\ nx\ lint*|npx\ eslint*) INTENT="linting" ;;
          nx\ serve*|npx\ nx\ serve*) INTENT="running dev server" ;;
          nx\ deploy*|npx\ nx\ deploy*) INTENT="deploying" ;;
          npm\ install*) INTENT="installing deps" ;;
          grep*|find*)   INTENT="searching" ;;
          curl*|wget*)   INTENT="fetching" ;;
          *)             INTENT="running command" ;;
        esac
        # For bash, extract file from command if no file_path
        if [ -z "$CUR_FILE" ] || [ "$CUR_FILE" = "$CMD" ]; then
          CUR_FILE=""
        fi
        ;;
      mcp__*)            INTENT="using tools" ;;
      Agent)             INTENT="delegating" ;;
      WebSearch)         INTENT="researching" ;;
      WebFetch)          INTENT="fetching" ;;
      *)                 INTENT="working" ;;
    esac

    # Get repo name and branch. No owner: the agent publishes its sponsor.
    PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
    REPO_ROOT=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")
    REPO=$([ -n "$REPO_ROOT" ] && basename "$REPO_ROOT" 2>/dev/null || basename "$PROJECT_DIR" 2>/dev/null || echo "")
    BRANCH=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

    # Repo-relative where it is cheap and certain: under REPO_ROOT and not inside
    # a nested worktree/submodule (a `.git` between the file and the root). Pure
    # builtins — no fork. Anything else stays as given; the agent resolves it.
    gb_rel() {
      GB_REL="$1"
      [ -n "$REPO_ROOT" ] || return 0
      case "$1" in "$REPO_ROOT"/*) ;; *) return 0 ;; esac
      local d="${1%/*}"
      while [ -n "$d" ] && [ "$d" != "$REPO_ROOT" ]; do
        [ -e "$d/.git" ] && return 0
        d="${d%/*}"
      done
      GB_REL="${1#"$REPO_ROOT"/}"
    }
    if [ -n "$CUR_FILE" ]; then gb_rel "$CUR_FILE"; CUR_FILE="$GB_REL"; fi

    [ -d "$SDIR" ] || mkdir -p "$SDIR" 2>/dev/null || true
    OB="$SDIR/outbox.json"

    # Read existing file history and edited files from previous outbox
    PREV_FILES="[]"
    PREV_EDITED="[]"
    if [ -f "$OB" ]; then
      PREV_FILES=$(jq -r '.recentFiles // []' "$OB" 2>/dev/null || echo "[]")
      PREV_EDITED=$(jq -r '.editedFiles // []' "$OB" 2>/dev/null || echo "[]")
    fi

    # Append current file to history (deduped, max 10)
    if [ -n "$CUR_FILE" ]; then
      RECENT_FILES=$(printf '%s' "$PREV_FILES" | jq --arg f "$CUR_FILE" '
        [($f)] + [.[] | select(. != $f)] | .[0:10]
      ' 2>/dev/null || echo "[]")
    else
      RECENT_FILES="$PREV_FILES"
    fi

    # Track edited files separately (edit tools only), MOST RECENT FIRST,
    # deduped, max 50 — the agent publishes the head as `editing`.
    EDITED_FILES="$PREV_EDITED"
    case "$TOOL_NAME" in
      Edit|Write|MultiEdit|NotebookEdit)
        if [ -n "$CUR_FILE" ]; then
          EDITED_FILES=$(printf '%s' "$PREV_EDITED" | jq --arg f "$CUR_FILE" '
            [($f)] + [.[] | select(. != $f)] | .[0:50]
          ' 2>/dev/null || echo "[]")
        fi
        ;;
    esac

    # Throttled git stats — only recompute every 30s
    UNCOMMITTED="null"
    GIT_STATS="null"
    if [ -f "$OB" ]; then
      OB_MOD=$(stat -c %Y "$OB" 2>/dev/null || stat -f %m "$OB" 2>/dev/null || echo 0)
      NOW_EPOCH=$(date +%s)
      ELAPSED=$(( NOW_EPOCH - OB_MOD ))
      if [ "$ELAPSED" -lt 30 ]; then
        UNCOMMITTED=$(jq -r '.uncommittedFiles // null' "$OB" 2>/dev/null || echo "null")
        GIT_STATS=$(jq -r '.gitStats // null' "$OB" 2>/dev/null || echo "null")
      fi
    fi
    if [ "$UNCOMMITTED" = "null" ]; then
      # -z: NUL-separated, root-relative, unquoted — survives spaces; a rename
      # (R/C) carries its old path as the NEXT entry, which is skipped.
      UNCOMMITTED=$(git -C "$PROJECT_DIR" status --porcelain -z 2>/dev/null | jq -R -s '
        split("\u0000") | map(select(length > 0))
        | reduce .[] as $e ({out: [], skip: false};
            if .skip then .skip = false
            else (.out += [$e[3:]]) | (if ($e[0:2] | test("[RC]")) then .skip = true else . end) end)
        | .out' 2>/dev/null || echo "[]")
      MAIN_BRANCH=$(git -C "$PROJECT_DIR" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@refs/remotes/origin/@@' || echo "main")
      DIFF_STAT=$(git -C "$PROJECT_DIR" diff --stat "$MAIN_BRANCH"...HEAD 2>/dev/null | tail -1)
      if [ -n "$DIFF_STAT" ]; then
        FC=$(echo "$DIFF_STAT" | grep -oE '[0-9]+ file' | grep -oE '[0-9]+' || echo "0")
        INS=$(echo "$DIFF_STAT" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
        DEL=$(echo "$DIFF_STAT" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo "0")
        GIT_STATS=$(printf '{"filesChanged":%s,"insertions":%s,"deletions":%s}' "${FC:-0}" "${INS:-0}" "${DEL:-0}")
      else
        GIT_STATS="{}"
      fi
    fi

    # Write enriched outbox
    jq -n \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg tool "$TOOL_NAME" \
      --arg file "$CUR_FILE" \
      --arg intent "$INTENT" \
      --arg repo "$REPO" \
      --arg branch "$BRANCH" \
      --arg root "$REPO_ROOT" \
      --argjson recentFiles "$RECENT_FILES" \
      --argjson editedFiles "$EDITED_FILES" \
      --argjson uncommittedFiles "$UNCOMMITTED" \
      --arg gitStats "$GIT_STATS" \
      '{ts: $ts, tool: $tool, file: $file, intent: $intent, repo: $repo, branch: $branch, root: $root, recentFiles: $recentFiles, editedFiles: $editedFiles, uncommittedFiles: $uncommittedFiles, gitStats: $gitStats}' \
      > "$OB.tmp" 2>/dev/null \
      && mv "$OB.tmp" "$OB" 2>/dev/null || true
  fi
} || true

# --- (a) inbound: inject deltas, deduped on inbox seq -----------------------
CONTEXT=""
{
  INBOX="$SDIR/inbox.json"

  if [ -f "$INBOX" ]; then
    INBOX_JSON=$(cat "$INBOX" 2>/dev/null || echo '{}')
    SEQ=$(printf '%s' "$INBOX_JSON" | jq -r '.seq // 0' 2>/dev/null || echo 0)
    EVENT_COUNT=$(printf '%s' "$INBOX_JSON" | jq '.events | length' 2>/dev/null || echo 0)

    HS="$SDIR/hook-state.json"
    LAST_SEQ=0
    LAST_COUNT=0
    if [ -f "$HS" ]; then
      LAST_SEQ=$(jq -r '.lastSeenSeq // 0' "$HS" 2>/dev/null || echo 0)
      LAST_COUNT=$(jq -r '.lastEventCount // 0' "$HS" 2>/dev/null || echo 0)
    fi

    # Only do work if the server's presence version advanced.
    if [ "$SEQ" != "$LAST_SEQ" ]; then
      if [ "$EVENT_COUNT" -gt "$LAST_COUNT" ] 2>/dev/null; then
        EVENTS=$(printf '%s' "$INBOX_JSON" | jq -r --argjson skip "$LAST_COUNT" '
          .events[$skip:] | .[] |
          if .type == "peer_joined" then "→ \(.peer) joined"
          elif .type == "peer_left" then "← \(.peer) left"
          elif .type == "peer_changed" then "△ \(.peer): \(.detail)"
          elif .type == "conflict" then "⚠ CONFLICT: \(.peer) also editing \(.files | join(", "))"
          elif .type == "page_updated" then "📄 \(.detail) updated by \(.peer)"
          elif .type == "attachment" then "📎 \(.peer) attached \(.detail) to your activity"
          elif .type == "mention" then "💬 \(.peer) mentioned you: \(.detail)" + (if .threadId then " [reply in thread \(.threadId)]" else "" end)
          elif .type == "thread_reply" then "💬 \(.peer) replied in a thread you follow: \(.detail // "")" + (if .threadId then " [thread \(.threadId)]" else "" end)
          elif .type == "ask" then "📨 ASK for you from \(.peer): \(.detail // "")" + (if .threadId then " [discuss in thread \(.threadId)]" else "" end)
          elif .type == "named" then "· \(.peer) named you without an @-mention (did not wake you): \(.detail // "")" + (if .threadId then " [thread \(.threadId)]" else "" end)
          else "\(.type): \(.peer)" end
        ' 2>/dev/null || true)
        [ -n "$EVENTS" ] && CONTEXT="$EVENTS"
      fi

      # Advance the baseline regardless, so we never re-inject the same events.
      mkdir -p "$SDIR" 2>/dev/null || true
      printf '{"lastSeenSeq":%s,"lastEventCount":%s}\n' "$SEQ" "$EVENT_COUNT" \
        > "$HS.tmp" 2>/dev/null && mv "$HS.tmp" "$HS" 2>/dev/null || true
    fi
  fi
} || true

if [ -n "$CONTEXT" ]; then
  ESCAPED=$(printf 'Gigabuddy — new activity:\n%s' "$CONTEXT" | jq -Rs .)
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":%s}}\n' "$ESCAPED"
fi

exit 0
