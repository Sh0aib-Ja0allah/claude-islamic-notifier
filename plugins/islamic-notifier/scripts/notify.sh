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

# bash, as sh, takes shell options from an exported SHELLOPTS; errexit, noclobber, noglob or
# nounset would break the always-exit-0 contract, the state writes or the clip glob.
set +C +e +f +u
unset CDPATH
CR=$(printf '\r')
BOM=$(printf '\357\273\277')

# is_epoch VALUE: true for 1 to 12 digits with no leading zero. Anything else in a state
# file is treated as missing, since $((...)) would read 09 as bad octal, or overflow, and
# abort the shell.
is_epoch() {
  case $1 in
    ''|0?*|*[!0-9]*) return 1 ;;
  esac
  [ ${#1} -le 12 ]
}

# ---- Step 1: arguments and locale
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

# ---- Step 2: read the Stop input
# Claude closes stdin right after writing it, so this read ends.
INPUT=
if [ "$HOOK" = 1 ] && [ ! -t 0 ]; then
  INPUT=$(head -c 262144 2>/dev/null) || INPUT=$(cat 2>/dev/null)
fi

# ---- Step 3: silence output
if [ "$DRY" = 1 ]; then
  exec 2>/dev/null
else
  exec >/dev/null 2>&1
fi

# ---- Step 4: directories
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
  # On Windows, the same dir as play.ps1: %LOCALAPPDATA%\islamic-notifier (section 4.5).
  if [ -n "${LOCALAPPDATA:-}" ]; then
    case $(uname -s) in
      MINGW*|MSYS*|CYGWIN*)
        la=$(cygpath -u "$LOCALAPPDATA") && [ -n "$la" ] || la=$LOCALAPPDATA
        DATA=$la/islamic-notifier ;;
    esac
  fi
fi
# A dry run creates nothing, not even these.
[ "$DRY" = 1 ] || mkdir -p "$ROOT" "$DATA"

NOW=$(date +%s)
is_epoch "$NOW" || NOW=0

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

# Facts that only steps 12 to 17 find; "-" until then (and on win, for good).
GAP=-
LOCK_STATE=-
POOL=-
CLIP=-
PLAYER=-
FALLBACK=-
PLAYER_VOLUME=-
report() {
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
}

# ---- Step 5: config, then environment overrides
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

# ---- Step 6: force-next
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
  is_epoch "$ts" || return 0
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

# ---- Step 7: mute
if [ "$FORCE" != 1 ]; then
  if [ "$MUTED" = 1 ]; then
    skip muted
  elif [ "$VOLUME" = 0 ]; then
    skip volume
  fi
fi

# ---- Step 8: background-work pauses
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

# ---- Step 9: operating system
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

# ---- Step 10: remote sessions
# Detected even with FORCE_LOCAL, so the report can show it. "Set" includes set but empty.
REMOTE=none
if [ -n "${SSH_CONNECTION+x}${SSH_CLIENT+x}${SSH_TTY+x}" ]; then
  REMOTE=ssh
elif [ "${CODESPACES:-}" = true ]; then
  REMOTE=codespaces
elif [ "${REMOTE_CONTAINERS:-}" = true ]; then
  REMOTE=devcontainer
elif [ "${CLAUDE_CODE_REMOTE:-}" = true ]; then
  REMOTE=claude-remote
elif [ -n "${GITPOD_WORKSPACE_ID+x}" ]; then
  REMOTE=gitpod
elif [ -e "$SYSROOT/.dockerenv" ] || [ -e "$SYSROOT/run/.containerenv" ]; then
  REMOTE=container
fi
FORCE_LOCAL=0
[ "${ISLAMIC_NOTIFIER_FORCE_LOCAL:-}" = 1 ] && FORCE_LOCAL=1
[ "$REMOTE" != none ] && [ "$FORCE_LOCAL" = 0 ] && skip remote

# ---- Step 11: Windows
# Git Bash, MSYS2 and Cygwin hand off to play.ps1, which owns the gap, the mutex, the pick
# and playback on Windows. This process is already detached, so it waits.
if [ "$OS" = win ]; then
  PLAYER=play.ps1
  [ -n "$DECISION" ] || DECISION=handoff
  if [ "$DRY" = 1 ]; then
    report
    exit 0
  fi
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

# ---- Step 12: minimum gap
# A last-play in the future (the clock went back) does not block.
GAP=ok
if [ -f "$DATA/last-play" ]; then
  lp=
  IFS= read -r lp < "$DATA/last-play"
  lp=${lp%"$CR"}
  if is_epoch "$lp"; then
    age=$((NOW - lp))
    [ "$age" -ge 0 ] && [ "$age" -lt "$MIN_GAP" ] && GAP=recent
  fi
fi
[ "$GAP" = recent ] && skip gap

# ---- Step 13: lock
# play.lock is a directory holding ts, the epoch it was last stamped, and pid, its owner. It
# is busy while ts is younger than STALE_LOCK. A missing or unreadable ts counts as fresh,
# since its owner may be between mkdir and writing ts; a hook run then stamps it, so a lock
# whose owner died right there still goes stale STALE_LOCK later. A ts that far in the
# future is stale too. The owner restamps ts before each player (step 17), so a live lock
# never looks stale, and at exit removes the lock only if it is still its own. A dry run
# only looks.
LOCK=$DATA/play.lock
lock_is_stale() {
  ts=
  [ -f "$LOCK/ts" ] && IFS= read -r ts < "$LOCK/ts"
  if ! is_epoch "$ts"; then
    [ "$DRY" = 1 ] || printf '%s\n' "$NOW" > "$LOCK/ts"
    return 1
  fi
  age=$((NOW - ts))
  [ "$age" -ge "$STALE_LOCK" ] || [ "$age" -le $((0 - STALE_LOCK)) ]
}
if [ "$DRY" = 1 ]; then
  LOCK_STATE=free
  if [ -d "$LOCK" ]; then
    if lock_is_stale; then
      LOCK_STATE=stale
    else
      LOCK_STATE=busy
      skip busy
    fi
  fi
else
  if ! mkdir "$LOCK"; then
    lock_is_stale || skip busy
    mv "$LOCK" "$LOCK.stale.$$" && rm -rf "$LOCK.stale.$$"
    mkdir "$LOCK" || skip busy
  fi
  printf '%s\n' "$$" > "$LOCK/pid"
  # The trap's own first command assigns owner; shellcheck misses assignments in a trap
  # string.
  # shellcheck disable=SC2154
  trap 'owner=; read -r owner < "$LOCK/pid"; [ "$owner" = "$$" ] && rm -rf "$LOCK"' EXIT
  trap 'exit 0' HUP INT TERM
  printf '%s\n' "$NOW" > "$LOCK/ts"
fi

# ---- Step 14: pick a clip
# The pool is every .wav and .mp3 (any case) in the dirs sounds_mode names, filtered by the
# forced id if there is one. The id is the name up to its first dot (docs/PLAN.md, section
# 6), so subhanallah matches subhanallah.female.wav but not subhanallah2.wav. Paths can hold
# spaces, so each is kept whole in its own variable (CLIP_1, CLIP_2, ...).
POOL=0
add_clips() {
  for f in "$1"/*; do
    [ -f "$f" ] || continue
    name=${f##*/}
    case $name in
      *.[Ww][Aa][Vv]|*.[Mm][Pp]3) ;;
      *) continue ;;
    esac
    if [ "$FORCE" = 1 ] && [ "$FID" != '*' ]; then
      case $name in
        "$FID".*) ;;
        *) continue ;;
      esac
    fi
    POOL=$((POOL + 1))
    eval "CLIP_$POOL=\$f"
  done
}
case $MODE in
  both|bundled) add_clips "$ROOT/sounds" ;;
esac
case $MODE in
  both|custom) [ -n "${HOME:-}" ] && add_clips "$HOME/.claude/islamic-notifier/sounds" ;;
esac

# With two or more clips, the one played last is left out and one of the rest is drawn
# with od on /dev/urandom ($RANDOM is not POSIX).
CLIP=none
if [ "$POOL" -eq 1 ]; then
  CLIP=$CLIP_1
elif [ "$POOL" -gt 1 ]; then
  last=
  [ -f "$DATA/last-file" ] && IFS= read -r last < "$DATA/last-file"
  n=0
  i=1
  while [ "$i" -le "$POOL" ]; do
    eval "c=\$CLIP_$i"
    # The eval above assigns c; shellcheck cannot see into eval.
    # shellcheck disable=SC2154
    if [ "$c" != "$last" ]; then
      n=$((n + 1))
      eval "PICK_$n=\$c"
    fi
    i=$((i + 1))
  done
  r=$(od -An -N2 -tu2 /dev/urandom)
  r=${r#"${r%%[0-9]*}"}
  r=${r%%[!0-9]*}
  [ -n "$r" ] || r=0
  if [ "$n" -gt 0 ]; then
    eval "CLIP=\$PICK_$((r % n + 1))"
  else
    CLIP=$CLIP_1
  fi
fi
[ "$POOL" -gt 0 ] || skip no-clip

# ---- Step 15: choose the players
# Chosen once, from what command -v finds and the file type. The first one is tried first,
# the next only after a fast failure (step 17). Their flags are in player_run below.
has() { command -v "$1" >/dev/null 2>&1; }
CHAIN=
add_player() {
  if has "$1"; then CHAIN="$CHAIN $1"; fi
}
PS_EXE=
case $OS in
  mac) add_player afplay ;;
  *)
    # wsl: play.ps1 through interop first. powershell.exe is off PATH when Windows paths
    # are not appended to it (appendWindowsPath=false); its usual place is tried then.
    if [ "$OS" = wsl ]; then
      if has powershell.exe; then
        PS_EXE=powershell.exe
      elif has wslpath; then
        p=$(wslpath -u 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe')
        [ -n "$p" ] && [ -x "$p" ] && PS_EXE=$p
      fi
      [ -z "$PS_EXE" ] || CHAIN=' powershell.exe'
    fi
    # pw-play when pactl reports a PipeWire server (docs/PLAN.md, section 5), otherwise
    # paplay; pw-play also when paplay is not installed.
    pulse=paplay
    if has pw-play; then
      if ! has paplay; then
        pulse=pw-play
      elif has pactl; then
        case $(pactl info) in *PipeWire*) pulse=pw-play ;; esac
      fi
    fi
    case $CLIP in
      *.[Mm][Pp]3) for p in mpg123 ffplay mpv "$pulse"; do add_player "$p"; done ;;
      *) for p in "$pulse" aplay ffplay mpv; do add_player "$p"; done ;;
    esac ;;
esac
PLAYER=none
FALLBACK=none
for p in $CHAIN; do
  if [ "$PLAYER" = none ]; then
    PLAYER=$p
  elif [ "$FALLBACK" = none ]; then
    FALLBACK=$p
  else
    FALLBACK=$FALLBACK,$p
  fi
done
[ "$PLAYER" != none ] || skip no-player

# ---- Step 16: volume
# volume is linear amplitude, 0 to 100. afplay and pw-play take a decimal (70 is 0.70; the
# LC_ALL=C above keeps the point, which pw-cat reads per locale). paplay and mpv put what
# they get on a cubic curve, so they get the cube root. ffplay, mpg123 and play.ps1 are
# linear.
DEC=$(printf '%d.%02d' $((VOLUME / 100)) $((VOLUME % 100)))
cube_root() {
  awk -v v="$VOLUME" -v full="$1" 'BEGIN { printf "%d\n", full * (v / 100) ^ (1 / 3) + 0.5 }'
}
player_volume() {
  case $1 in
    afplay|pw-play) printf '%s\n' "$DEC" ;;
    paplay) cube_root 65536 ;;
    mpv) cube_root 100 ;;
    ffplay|powershell.exe) printf '%s\n' "$VOLUME" ;;
    mpg123) printf '%s\n' $((32768 * VOLUME / 100)) ;;
    *) printf 'none\n' ;;
  esac
}
PLAYER_VOLUME=$(player_volume "$PLAYER")

# ---- Step 17: play
[ -n "$DECISION" ] || DECISION=play
if [ "$DRY" = 1 ]; then
  report
  exit 0
fi

TIMEOUT=
has timeout && TIMEOUT=1
# run CMD [ARG ...]: run a player with no stdin, under timeout where it exists (GNU
# coreutils timeout: -k 2 sends KILL 2 s after the TERM it sends at 30 s). Without timeout,
# macOS relies on afplay -t 30.
run() {
  if [ -n "$TIMEOUT" ]; then
    timeout -k 2 "$MAX_PLAY" "$@" < /dev/null
  else
    "$@" < /dev/null
  fi
}
# player_run NAME: play $CLIP with player NAME. Each flag names its source; none is checked
# on real hardware yet (M6).
player_run() {
  v=$(player_volume "$1")
  case $1 in
    # afplay -h (ss64.com/mac/afplay.html): -v VOLUME sets the volume, -t TIME plays for
    # TIME seconds.
    afplay) run afplay -v "$v" -t "$MAX_PLAY" "$CLIP" ;;
    # pw-cat(1), which pw-play runs as (docs.pipewire.org/page_man_pw-cat_1.html):
    # --volume=VALUE, the stream volume, default 1.000.
    pw-play) run pw-play --volume="$v" "$CLIP" ;;
    # paplay(1): --volume=VOLUME, from 0 (silent) to 65536 (100% volume).
    paplay) run paplay --volume="$v" "$CLIP" ;;
    # aplay(1): -q is quiet. aplay has no volume option.
    aplay) run aplay -q "$CLIP" ;;
    # ffplay(1) (ffmpeg.org/ffplay.html): -nodisp no window, -autoexit exit at the end,
    # -loglevel quiet, -volume 0 to 100.
    ffplay) run ffplay -nodisp -autoexit -loglevel quiet -volume "$v" "$CLIP" ;;
    # mpv(1) (mpv.io/manual/stable): --video=no, --terminal=no (no terminal, stdin or
    # output), --volume=<value> 0 to 100, which mpv cubes (player/audio.c).
    mpv) run mpv --video=no --terminal=no --volume="$v" "$CLIP" ;;
    # mpg123(1): -q is quiet, -f factor is the scale factor (default 32768).
    mpg123) run mpg123 -q -f "$v" "$CLIP" ;;
    # WSL interop: play.ps1 -Worker -Path plays the given file (docs/PLAN.md, Appendix
    # B.2). It starts from /mnt/c, since Windows cannot use a Linux cwd; if that cd fails,
    # it still runs. The subshell execs, so no extra shell sits between this script and
    # the player, as with the other players.
    powershell.exe)
      ps1=$ROOT/scripts/play.ps1
      w=$(wslpath -w "$ps1") && [ -n "$w" ] && ps1=$w
      wclip=$(wslpath -w "$CLIP") && [ -n "$wclip" ] || wclip=$CLIP
      (
        cd "$SYSROOT/mnt/c" || true
        set -- "$PS_EXE" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$ps1" \
          -Worker -Path "$wclip" -Volume "$v"
        [ -z "$TIMEOUT" ] || set -- timeout -k 2 "$MAX_PLAY" "$@"
        exec "$@" < /dev/null
      ) ;;
  esac
}
epoch() {
  e=$(date +%s)
  is_epoch "$e" || e=0
}

printf '%s\n' "$NOW" > "$DATA/last-play"
printf '%s\n' "$CLIP" > "$DATA/last-file"
dbg "play $CLIP with$CHAIN"
# The next player is tried only after a fast failure. date +%s counts whole seconds, so
# fast means at most 1 s by that clock. A timeout (124) or a kill (137, 143) never falls
# through, since part of the clip may have played. play.ps1 exits 4 when it played nothing,
# which falls through however long it took, and 3 when a Windows-side clip is playing,
# which never does. ts is restamped before each player, so the lock stays fresh.
for p in $CHAIN; do
  epoch
  t0=$e
  printf '%s\n' "$t0" > "$LOCK/ts"
  player_run "$p"
  rc=$?
  epoch
  dbg "$p exited $rc"
  case $rc in 0|124|137|143) break ;; esac
  if [ "$p" = powershell.exe ]; then
    [ "$rc" != 3 ] || break
    [ "$rc" != 4 ] || continue
  fi
  [ $((e - t0)) -le 1 ] || break
done
exit 0
