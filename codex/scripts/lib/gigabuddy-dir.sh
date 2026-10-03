#!/usr/bin/env bash
# Shared resolution of the Gigabuddy scratch dir.
#
# MUST stay in lockstep with resolveScratchDir()/findRepoRoot() in the agent
# server's scratch module — the server uses the TS one, these hooks use this
# one, and the whole point is that both land on the SAME dir. Change one,
# re-mirror the other (the server's scratch spec pins the cases).
#
# Resolves to the REPOSITORY ROOT so a main checkout and all of its git
# worktrees share one location. Anchoring on the current directory instead is
# what used to split state: hooks re-resolve per invocation while the server
# captured cwd at startup, so a mid-session worktree switch left each side
# writing somewhere the other never looked.
#
# Pure bash — no forks (no git, dirname, or cut). This runs on every hook
# invocation and on every statusline render.

# Usage: GB_DIR="$(gigabuddy_dir)"
gigabuddy_dir() {
  if [ -n "${GIGABUDDY_SCRATCH_DIR:-}" ]; then
    printf '%s' "$GIGABUDDY_SCRATCH_DIR"
    return 0
  fi

  local start="${CLAUDE_PROJECT_DIR:-$PWD}"
  local d="$start"
  local gitdir marker

  while :; do
    # Main checkout: `.git` is a directory.
    if [ -d "$d/.git" ]; then
      printf '%s/.gigabuddy' "$d"
      return 0
    fi
    # Linked worktree: `.git` is a FILE holding `gitdir: <main>/.git/worktrees/<name>`,
    # which is how a worktree finds its way back to the checkout that owns it.
    if [ -f "$d/.git" ]; then
      read -r _ gitdir <"$d/.git" 2>/dev/null || gitdir=""
      marker="/.git/worktrees/"
      case "$gitdir" in
        *"$marker"*)
          printf '%s/.gigabuddy' "${gitdir%%/.git/worktrees/*}"
          return 0
          ;;
      esac
      # Unrecognised form (submodule, custom layout) — treat this dir as the root.
      printf '%s/.gigabuddy' "$d"
      return 0
    fi
    [ "$d" = "/" ] && break
    d="${d%/*}"
    [ -z "$d" ] && d="/"
  done

  # Not in a repo: the historical behaviour.
  printf '%s/.gigabuddy' "$start"
}
