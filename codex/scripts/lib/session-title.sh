#!/usr/bin/env bash
# Session title = room name (work_object:ZroS439dCkuV).
#
# Someone running several sessions sees "Plum Wolf" and "Jade Hawk" in the
# room but "gigabuddy-a6" and "Fix tests" on their terminal tabs, and can't
# tell which is which. The UserPromptSubmit hook prefixes the session title
# with an emoji and the agent's room name: "🐺 Plum Wolf · Fix tests".
#
# Claude Code (CLI and VS Code) applies a hook's `hookSpecificOutput.
# sessionTitle` as a rename: it becomes the session's name and, with
# terminalTitleFromRename on (the default), the terminal tab title. The hook
# input carries the current `session_title` (absent until the session has
# one), so the prefix goes in front of whatever the app or the person chose.
# The desktop app ignores sessionTitle (probed 2026-09-28); there the agent
# renames itself with the app's set_session_title tool, so we hand it a
# one-line instruction instead.
#
# Two guards, agreed with Daniel 2026-09-28:
#   - never prefix twice: an exact "<emoji> <Name> · " start means done;
#   - respect removal: each title is prefixed at most once. If the same
#     unprefixed title comes back, the person took the prefix off (or the
#     app ignored it), so it stays as they left it.
# A new name (a resumed session joins under a different one) swaps the old
# prefix for the new instead of stacking them.
#
# Pure bash apart from one jq read and write of the state file.

# The emoji for an animal in the room's name list (generateAgentNickname in
# apps/auth/src/lib/agent-profiles.ts). Same name, same emoji, every time.
# Birds without their own emoji share 🐦. No ZWJ or variation-selector
# emoji: terminals miscount their width and garble the tab.
gigabuddy_name_emoji() {
  case "${1##* }" in
    Badger) printf '🦡' ;;
    Bear) printf '🐻' ;;
    Deer | Elk) printf '🦌' ;;
    Dolphin) printf '🐬' ;;
    Eagle | Falcon | Hawk | Osprey) printf '🦅' ;;
    Fox) printf '🦊' ;;
    Frog | Toad) printf '🐸' ;;
    Gecko | Newt) printf '🦎' ;;
    Goose | Swan) printf '🦢' ;;
    Hare) printf '🐇' ;;
    Hedgehog) printf '🦔' ;;
    Horse | Colt) printf '🐴' ;;
    Lemur) printf '🐒' ;;
    Lion) printf '🦁' ;;
    Lynx) printf '🐈' ;;
    Marten | Mink | Otter | Weasel) printf '🦦' ;;
    Owl) printf '🦉' ;;
    Panda) printf '🐼' ;;
    Parrot) printf '🦜' ;;
    Penguin) printf '🐧' ;;
    Pika) printf '🐹' ;;
    Puma) printf '🐆' ;;
    Salmon | Dace) printf '🐟' ;;
    Seal) printf '🦭' ;;
    Tiger) printf '🐯' ;;
    Viper) printf '🐍' ;;
    Whale) printf '🐋' ;;
    Wolf) printf '🐺' ;;
    Yak) printf '🐂' ;;
    Zebra) printf '🦓' ;;
    Crane | Crow | Dove | Finch | Heron | Ibis | Jay | Kite | Lark | Oriole | \
      Pelican | Quail | Raven | Robin | Shrike | Skua | Sparrow | Stork | \
      Swift | Tern | Thrush | Wren) printf '🐦' ;;
    *) printf '🐾' ;;
  esac
}

# Usage: gigabuddy_session_title <name> <current title, may be ""> <session dir>
# Sets SESSION_TITLE_OUT (the title to apply, or "") and SESSION_TITLE_HINT
# (a desktop instruction for the agent, or "").
gigabuddy_session_title() {
  local name="$1" title="$2" sdir="$3"
  SESSION_TITLE_OUT=""
  SESSION_TITLE_HINT=""
  [ -n "$name" ] || return 0

  local prefix
  prefix="$(gigabuddy_name_emoji "$name") $name · "
  # Already carries this name: as the prefix, or as the whole title (we set
  # the bare name when the session had no title yet).
  case "$title" in
    "$prefix"* | "${prefix% · }") return 0 ;;
  esac

  local state="$sdir/session-title.json" old_prefix="" last_base=""
  if [ -f "$state" ]; then
    { IFS= read -r old_prefix && IFS= read -r last_base; } < <(
      jq -r '(.prefix // ""), (.base // "")' "$state" 2>/dev/null
    ) || true
  fi

  # A previous name's prefix: swap it for this one.
  local base="$title"
  if [ -n "$old_prefix" ] && [ "$old_prefix" != "$prefix" ]; then
    case "$title" in
      "$old_prefix"*) base="${title#"$old_prefix"}" ;;
      "${old_prefix% · }") base="" ;;
    esac
  # Same name, same unprefixed title as last time: they removed it. Leave it.
  elif [ -f "$state" ] && [ "$title" = "$last_base" ]; then
    return 0
  fi

  local new
  if [ -n "$base" ]; then new="$prefix$base"; else new="${prefix% · }"; fi

  mkdir -p "$sdir" 2>/dev/null || true
  jq -n --arg prefix "$prefix" --arg base "$title" '{prefix: $prefix, base: $base}' \
    > "$state.tmp" 2>/dev/null && mv "$state.tmp" "$state" 2>/dev/null || true

  if [ "${CLAUDE_CODE_ENTRYPOINT:-}" = "claude-desktop" ]; then
    SESSION_TITLE_HINT="Rename this session so its person can tell which session is you: load mcp__ccd_session_mgmt__set_session_title with tool search, then call it with session_id \"self\" and title \"$new\". Don't mention it unless it fails."
  else
    SESSION_TITLE_OUT="$new"
  fi
}
