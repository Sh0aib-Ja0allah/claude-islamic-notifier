#!/bin/sh
# islamic-notifier: play a random dhikr when Claude finishes responding.
# POSIX sh (dash, busybox ash, bash 3.2). The contract is docs/PLAN.md, Appendix B.1; the
# "Step N" comments follow its numbering.
#
# Usage: notify.sh [--hook] [--dry-run] [--force <id|*>]
#   --hook      read the Stop hook input (JSON) from stdin; hooks.json passes this
#   --dry-run   decide and print the report below, but play nothing and change no file;
#               ISLAMIC_NOTIFIER_DRY_RUN=1 does the same
#   --force     play <id>, or any clip for *, even when muted or paused; force-next is
#               left alone
# It always exits 0. Outside --dry-run it writes nothing to stdout or stderr.
#
# Dry-run report: one key=value line per fact, always all of them, in this order. play.ps1
# -DryRun (M3) and ctl status (M4) print the same keys. Values are ASCII words and numbers,
# except the paths in root, data and clip, which are printed as they are on disk. "-" means
# the fact is not checked on this path: on win, play.ps1 owns the gap, lock, pool and player.
#   report=1                  version of this key list
#   os=mac|linux|wsl|win|other
#   root=<dir>                plugin root; bundled clips are in <root>/sounds
#   data=<dir>                config and state dir
#   input=none|idle|paused    Stop input: not read (no --hook), no background work, or a
#                             non-empty background_tasks or session_crons
#   force=none|*|<id>         the force-next marker or --force that applies
#   muted=0|1                 after ISLAMIC_NOTIFIER_MUTE
#   volume=0..100
#   pauses=on|off
#   sounds_mode=both|bundled|custom
#   remote=none|ssh|codespaces|devcontainer|claude-remote|gitpod|container
#   force_local=0|1
#   gap=ok|recent|-           time since the last play, against MIN_GAP
#   lock=free|busy|stale|-    play.lock; stale means it would be broken
#   pool=<count>|-            clips that could play, after the forced id filter
#   clip=<path>|none|-        the clip this run would play (a random pick)
#   player=<name>|none|-      the first player to try
#   fallback=<name>,...|none|-   players tried next, after a fast failure
#   player_volume=<value>|none|-  the volume argument the first player gets
#   decision=play|handoff|skip-muted|skip-volume|skip-paused|skip-remote|skip-gap|skip-busy|skip-no-clip|skip-no-player
#
# Test seam: ISLAMIC_NOTIFIER_TEST_SYSROOT, when set, is put in front of /proc/version,
# /.dockerenv, /run/.containerenv and /mnt/c so that tests can fake them. Unset, it changes
# nothing.

MIN_GAP=2
MAX_PLAY=30
STALE_LOCK=$((MAX_PLAY + 5))
FORCE_TTL=120

unset CDPATH
CR=$(printf '\r')
BOM=$(printf '\357\273\277')

# ---- Step 1: arguments and locale ------------------------------------------------------
LC_ALL=C
export LC_ALL
HOOK=0
DRY=0
FORCE_ARG=
while [ $# -gt 0 ]; do
  case $1 in
    --hook) HOOK=1 ;;
    --dry-run) DRY=1 ;;
    --force)
      [ $# -gt 1 ] || break
      shift
      FORCE_ARG=$1 ;;
  esac
  shift
done
[ "${ISLAMIC_NOTIFIER_DRY_RUN:-}" = 1 ] && DRY=1

# ---- Step 2: read the Stop input ---------------------------------------------------------
# Claude closes stdin right after writing it, so this read ends.
INPUT=
if [ "$HOOK" = 1 ] && [ ! -t 0 ]; then
  INPUT=$(head -c 262144 2>/dev/null) || INPUT=$(cat 2>/dev/null)
fi

# ---- Step 3: silence output --------------------------------------------------------------
if [ "$DRY" = 1 ]; then
  exec 2>/dev/null
else
  exec >/dev/null 2>&1
fi

# ---- Step 4: directories -----------------------------------------------------------------
SYSROOT=${ISLAMIC_NOTIFIER_TEST_SYSROOT:-}
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  ROOT=$CLAUDE_PLUGIN_ROOT
else
  case $0 in
    */*) ROOT=${0%/*} ;;
    *) ROOT=. ;;
  esac
  ROOT=$(cd "$ROOT/.." && pwd)
fi
if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then
  DATA=$CLAUDE_PLUGIN_DATA
else
  DATA=${XDG_STATE_HOME:-${HOME:-}/.local/state}/islamic-notifier
fi
# A dry run creates nothing, not even these.
[ "$DRY" = 1 ] || mkdir -p "$ROOT" "$DATA"

NOW=$(date +%s)
case $NOW in ''|*[!0-9]*) NOW=0 ;; esac

DEBUG=0
[ "${ISLAMIC_NOTIFIER_DEBUG:-}" = 1 ] && [ "$DRY" != 1 ] && DEBUG=1
dbg() {
  [ "$DEBUG" = 1 ] || return 0
  printf '%s notify[%s] %s\n' "$NOW" "$$" "$*" >> "$DATA/debug.log"
}

DECISION=
# skip REASON: stop here. A dry run records the first reason and keeps checking, so the
# report still shows every fact.
skip() {
  [ -n "$DECISION" ] || DECISION=skip-$1
  [ "$DRY" = 1 ] && return 0
  dbg "skip $1"
  exit 0
}

# ---- Step 5: config, then environment overrides --------------------------------------------
# Defaults, then whitelisted key=value lines (docs/PLAN.md, section 4.5). A value that is
# not valid for its key is ignored, and the last valid line wins.
MUTED=0
VOLUME=70
PAUSES=on
MODE=both
if [ -f "$DATA/config" ]; then
  first=1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$first" = 1 ]; then
      line=${line#"$BOM"}
      first=0
    fi
    line=${line%"$CR"}
    key=${line%%=*}
    [ "$key" != "$line" ] || continue
    val=${line#*=}
    case $key in
      muted) case $val in 0|1) MUTED=$val ;; esac ;;
      volume)
        case $val in
          ''|*[!0-9]*) ;;
          *)
            # Leading zeros would make $((...)) read the number as octal.
            while :; do
              case $val in
                0?*) val=${val#0} ;;
                *) break ;;
              esac
            done
            [ ${#val} -le 3 ] && [ "$val" -le 100 ] && VOLUME=$val ;;
        esac ;;
      pauses) case $val in on|off) PAUSES=$val ;; esac ;;
      sounds_mode) case $val in both|bundled|custom) MODE=$val ;; esac ;;
    esac
  done < "$DATA/config"
fi
case ${ISLAMIC_NOTIFIER_MUTE:-} in
  0|1) MUTED=$ISLAMIC_NOTIFIER_MUTE ;;
esac

# ---- Step 6: force-next --------------------------------------------------------------------
# The marker is "<epoch> <id or *>". A hook run claims it with mv, so two sessions stopping
# together cannot both use it, and deletes it whether it is fresh or not. A dry run only
# reads it. --force wins over the marker and leaves it in place.
FORCE=0
FID=
read_force() {
  line=
  IFS= read -r line < "$1" || [ -n "$line" ] || return 0
  line=${line%"$CR"}
  ts=${line%% *}
  case $line in
    *' '*) id=${line#* } ;;
    *) id='*' ;;
  esac
  case $ts in ''|*[!0-9]*) return 0 ;; esac
  age=$((NOW - ts))
  [ "$age" -ge 0 ] && [ "$age" -le "$FORCE_TTL" ] || return 0
  FORCE=1
  FID=$id
}
if [ -n "$FORCE_ARG" ]; then
  FORCE=1
  FID=$FORCE_ARG
elif [ -f "$DATA/force-next" ]; then
  if [ "$DRY" = 1 ]; then
    read_force "$DATA/force-next"
  elif mv -f "$DATA/force-next" "$DATA/force-next.$$"; then
    read_force "$DATA/force-next.$$"
    rm -f "$DATA/force-next.$$"
  fi
fi
# An id is a clip name up to its first dot (docs/PLAN.md, section 6). Anything else means
# any clip, so it can never reach a player or play.ps1 as an option.
if [ "$FORCE" = 1 ]; then
  case $FID in
    '*') ;;
    ''|-*|*[!A-Za-z0-9_-]*) FID='*' ;;
  esac
  dbg "force $FID"
fi

# ---- Step 7: mute ----------------------------------------------------------------------------
if [ "$FORCE" != 1 ]; then
  if [ "$MUTED" = 1 ]; then
    skip muted
  elif [ "$VOLUME" = 0 ]; then
    skip volume
  fi
fi

# ---- Step 8: background-work pauses ----------------------------------------------------------
INPUT_STATE=none
if [ "$HOOK" = 1 ]; then
  INPUT_STATE=idle
  if [ -n "$INPUT" ]; then
    compact=$(printf '%s' "$INPUT" | tr -d ' \t\r\n')
    case $compact in
      *'"background_tasks":[{'*|*'"session_crons":[{'*) INPUT_STATE=paused ;;
    esac
  fi
fi
[ "$FORCE" != 1 ] && [ "$PAUSES" = off ] && [ "$INPUT_STATE" = paused ] && skip paused

# ---- Step 9: operating system ----------------------------------------------------------------
case $(uname -s) in
  Darwin) OS=mac ;;
  Linux)
    OS=linux
    if [ -n "${WSL_DISTRO_NAME:-}" ]; then
      OS=wsl
    elif [ -r "$SYSROOT/proc/version" ]; then
      case $(cat "$SYSROOT/proc/version") in
        *[Mm][Ii][Cc][Rr][Oo][Ss][Oo][Ff][Tt]*) OS=wsl ;;
      esac
    fi ;;
  MINGW*|MSYS*|CYGWIN*) OS=win ;;
  *) OS=other ;;
esac

# ---- Step 10: remote sessions ----------------------------------------------------------------
# Detected even with FORCE_LOCAL, so the report can show it.
REMOTE=none
if [ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" ]; then
  REMOTE=ssh
elif [ "${CODESPACES:-}" = true ]; then
  REMOTE=codespaces
elif [ "${REMOTE_CONTAINERS:-}" = true ]; then
  REMOTE=devcontainer
elif [ "${CLAUDE_CODE_REMOTE:-}" = true ]; then
  REMOTE=claude-remote
elif [ -n "${GITPOD_WORKSPACE_ID:-}" ]; then
  REMOTE=gitpod
elif [ -e "$SYSROOT/.dockerenv" ] || [ -e "$SYSROOT/run/.containerenv" ]; then
  REMOTE=container
fi
FORCE_LOCAL=0
[ "${ISLAMIC_NOTIFIER_FORCE_LOCAL:-}" = 1 ] && FORCE_LOCAL=1
[ "$REMOTE" != none ] && [ "$FORCE_LOCAL" = 0 ] && skip remote

# ---- Step 11: Windows ------------------------------------------------------------------------
# Git Bash, MSYS2 and Cygwin hand off to play.ps1, which owns the gap, the mutex, the pick
# and playback on Windows. This process is already detached, so it waits.
GAP=-
LOCK_STATE=-
POOL=-
CLIP=-
PLAYER=-
FALLBACK=-
PLAYER_VOLUME=-
if [ "$OS" = win ]; then
  PLAYER=play.ps1
  [ -n "$DECISION" ] || DECISION=handoff
  if [ "$DRY" != 1 ]; then
    ps1=$ROOT/scripts/play.ps1
    w=$(cygpath -w "$ps1") && [ -n "$w" ] && ps1=$w
    if [ "$FORCE" = 1 ]; then
      powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$ps1" \
        -Worker -Force "$FID" < /dev/null
    else
      powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$ps1" \
        -Worker < /dev/null
    fi
    dbg "handoff rc=$?"
    exit 0
  fi
else
  # Steps 12 to 17 (playback on macOS, Linux and WSL) come with M2 checkpoint C.
  [ -n "$DECISION" ] || DECISION=play
  [ "$DRY" = 1 ] || exit 0
fi

# ---- Dry-run report --------------------------------------------------------------------------
force=none
[ "$FORCE" = 1 ] && force=$FID
printf '%s\n' \
  "report=1" \
  "os=$OS" \
  "root=$ROOT" \
  "data=$DATA" \
  "input=$INPUT_STATE" \
  "force=$force" \
  "muted=$MUTED" \
  "volume=$VOLUME" \
  "pauses=$PAUSES" \
  "sounds_mode=$MODE" \
  "remote=$REMOTE" \
  "force_local=$FORCE_LOCAL" \
  "gap=$GAP" \
  "lock=$LOCK_STATE" \
  "pool=$POOL" \
  "clip=$CLIP" \
  "player=$PLAYER" \
  "fallback=$FALLBACK" \
  "player_volume=$PLAYER_VOLUME" \
  "decision=$DECISION"
exit 0
