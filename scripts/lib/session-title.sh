#!/usr/bin/env bash
# Session title = room name (work_object:ZroS439dCkuV).
#
# Someone running several sessions sees "Plum Wolf" and "Jade Hawk" in the
# room but "gigabuddy-a6" and "Fix tests" on their terminal tabs, and can't
# tell which is which. The UserPromptSubmit hook prefixes the session title
# with an emoji and the agent's room name: "🐺 Plum Wolf · Fix tests".
#
# Claude Code (CLI and VS Code) applies a hook's `hookSpecificOutput.
# sessionTitle` as a rename: a custom title, which becomes the session's name
# and, with terminalTitleFromRename on (the default), the terminal tab title.
# Two titles exist side by side, and a custom one hides the other:
#   - the custom title (a person's /rename, or ours) — the hook input's
#     `session_title`, empty until one is set;
#   - Claude's own topic title, regenerated as the work moves. The hook never
#     sees it; Claude writes it to the transcript as "ai-title" lines.
# So the prefix goes in front of the person's title when they set one, and
# otherwise in front of Claude's latest topic title, updated when it changes
# ("🐦 Tide Shrike · Tide shrike status", not "🐦 Tide Shrike" alone). With
# neither yet, nothing is set: a bare name would hide every later topic title.
# The desktop app ignores sessionTitle (probed 2026-09-28); there the agent
# renames itself with the app's set_session_title tool, so we hand it a
# one-line instruction instead.
#
# Two guards, agreed with Daniel 2026-09-28:
#   - never prefix twice: an exact "<emoji> <Name> · " start means done;
#   - respect removal: if a title we prefixed comes back without the prefix,
#     the person took it off (or the app ignored it), so it stays as they
#     left it, and stops following Claude's topic.
# A new name (a resumed session joins under a different one) swaps the old
# prefix for the new instead of stacking them.
#
# Bash plus a jq read and write of the state file.

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

# Usage: gigabuddy_session_title <name> <custom title> <topic title> <session dir>
#   custom title: the hook input's session_title ("" when none)
#   topic title:  Claude's latest ai-title from the transcript ("" when none)
# Sets SESSION_TITLE_OUT (the title to apply, or "") and SESSION_TITLE_HINT
# (a desktop instruction for the agent, or "").
gigabuddy_session_title() {
  local name="$1" custom="$2" topic="$3" sdir="$4"
  SESSION_TITLE_OUT=""
  SESSION_TITLE_HINT=""
  [ -n "$name" ] || return 0

  local prefix bare
  prefix="$(gigabuddy_name_emoji "$name") $name · "
  bare="${prefix% · }"

  # What we set last time: the prefix, and the title we put after it — the
  # person's own (base) or Claude's topic (topic, with base empty).
  local state="$sdir/session-title.json" old_prefix="" last_base="" last_topic=""
  if [ -f "$state" ]; then
    { IFS= read -r old_prefix && IFS= read -r last_base && IFS= read -r last_topic; } < <(
      jq -r '(.prefix // ""), (.base // ""), (.topic // "")' "$state" 2>/dev/null
    ) || true
  fi

  local base="" use_topic=""
  case "$custom" in
    "$prefix"* | "$bare")
      # Ours already. Follow Claude's topic when that's what we put there.
      [ -z "$last_base" ] && [ -n "$topic" ] && [ "$topic" != "$last_topic" ] || return 0
      use_topic=1
      ;;
    *)
      if [ -n "$old_prefix" ] && [ "$old_prefix" != "$prefix" ] &&
        { [ "${custom#"$old_prefix"}" != "$custom" ] || [ "$custom" = "${old_prefix% · }" ]; }; then
        # A previous name's prefix: swap it, keeping what followed it.
        if [ -z "$last_base" ] && [ -n "$topic" ]; then
          use_topic=1
        else
          base="${custom#"$old_prefix"}"
          [ "$base" = "$custom" ] && base=""
        fi
      elif [ -n "$custom" ]; then
        # The person's title. If it is what we prefixed, they removed it.
        [ -f "$state" ] && { [ "$custom" = "$last_base" ] || { [ -z "$last_base" ] && [ "$custom" = "$last_topic" ]; }; } &&
          return 0
        base="$custom"
      else
        # No custom title: Claude's topic, once there is one. The same topic
        # again with nothing set means the rename didn't take — don't repeat.
        [ -n "$topic" ] || return 0
        [ -f "$state" ] && [ -z "$last_base" ] && [ "$topic" = "$last_topic" ] && return 0
        use_topic=1
      fi
      ;;
  esac

  local new
  if [ -n "$use_topic" ]; then
    base=""
    new="$prefix$topic"
  elif [ -n "$base" ]; then
    new="$prefix$base"
  else
    new="$bare"
  fi

  mkdir -p "$sdir" 2>/dev/null || true
  jq -n --arg prefix "$prefix" --arg base "$base" --arg topic "${use_topic:+$topic}" \
    '{prefix: $prefix, base: $base, topic: $topic}' \
    > "$state.tmp" 2>/dev/null && mv "$state.tmp" "$state" 2>/dev/null || true

  if [ "${CLAUDE_CODE_ENTRYPOINT:-}" = "claude-desktop" ]; then
    SESSION_TITLE_HINT="Rename this session so its person can tell which session is you: load mcp__ccd_session_mgmt__set_session_title with tool search, then call it with session_id \"self\" and title \"$new\". Don't mention it unless it fails."
  else
    SESSION_TITLE_OUT="$new"
  fi
}
