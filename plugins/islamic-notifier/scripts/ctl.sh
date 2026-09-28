#!/bin/sh
# islamic-notifier: the settings and test CLI behind the slash commands (docs/PLAN.md,
# Appendix B.3 and section 4.6). POSIX sh (dash, busybox ash, bash 3.2, Git Bash). ctl.ps1 is
# the same CLI for PowerShell: both write byte-identical config and force-next files and
# print the same lines.
#
# Usage: ctl.sh --data <dir> <verb> [arg ...]
#   test [id]                   write force-next (id from data/adhkar.tsv, or * for any
#                               clip) and say which dhikr will play when this reply ends
#   mute | unmute               set muted=1 | muted=0
#   volume [0-100]              show or set the volume
#   pauses [on|off]             show or set whether a clip plays at background-work pauses
#   sounds [list | open | mode both|bundled|custom]
#                               show (creating it), list or open the custom folder, or set
#                               the pool
#   status                      the diagnostics, from notify.sh --dry-run (and play.ps1
#                               -DryRun on Windows, where play.ps1 plays)
# --data is ${CLAUDE_PLUGIN_DATA} as Claude substituted it. There is no fallback: an empty
# --data, or one still holding "${", is bad usage. A Windows path (C:\... or C:/...) is
# accepted under Git Bash.
#
# Output: one to eight plain-English lines on stdout, ASCII except the TSV's own text.
# Exit: 0 done; 2 bad usage (stderr: why, then the usage line; no file changed); 1 a write
# that failed (stderr: how to allow it).
#
# Config writes: the config is read with a leading BOM and each line's trailing CR
# stripped; the first line for the key is replaced, later lines for it are dropped, or it is
# appended; every other line is kept. It is written LF-ended, without a BOM, to a temp file
# in the data dir, then renamed over config. force-next is "<epoch> <id or *>" and LF,
# written the same way.

set +C +e +f +u
unset CDPATH
LC_ALL=C
export LC_ALL
CR=$(printf '\r')
BOM=$(printf '\357\273\277')
USAGE='usage: ctl.sh --data <dir> {test [id] | mute | unmute | volume [0-100] | pauses [on|off] | sounds [list | open | mode both|bundled|custom] | status}'

# usage [WHY]: bad usage; nothing was changed.
usage() {
  [ $# -eq 0 ] || printf 'ctl.sh: %s\n' "$*" >&2
  printf '%s\n' "$USAGE" >&2
  exit 2
}

# ---- Windows paths
# Under Git Bash, MSYS2 or Cygwin, Claude may pass C:\... or C:/... paths. They are turned
# into POSIX paths to work with, and paths are shown the Windows way.
IS_WIN=
case $(uname -s 2>/dev/null) in
  MINGW*|MSYS*|CYGWIN*) command -v cygpath > /dev/null 2>&1 && IS_WIN=1 ;;
esac
posix_path() {
  p=$1
  if [ -n "$IS_WIN" ]; then
    case $p in
      [A-Za-z]:*|*\\*) q=$(cygpath -u "$p" 2>/dev/null) && [ -n "$q" ] && p=$q ;;
    esac
  fi
  printf '%s\n' "$p"
}
shown_path() {
  p=$1
  if [ -n "$IS_WIN" ]; then
    q=$(cygpath -w "$p" 2>/dev/null) && [ -n "$q" ] && p=$q
  fi
  printf '%s\n' "$p"
}

SELF=$(posix_path "$0")
case $SELF in
  */*) HERE=${SELF%/*} ;;
  *) HERE=. ;;
esac
ROOT=$(cd "$HERE/.." && pwd) || exit 2
TSV=$ROOT/data/adhkar.tsv

# ---- Arguments
DATA_ARG=
HAVE_DATA=
while [ $# -gt 0 ]; do
  case $1 in
    --data)
      [ $# -ge 2 ] || usage '--data needs a directory'
      DATA_ARG=$2
      HAVE_DATA=1
      shift 2 ;;
    *) break ;;
  esac
done
[ -n "$HAVE_DATA" ] || usage '--data is required'
[ -n "$DATA_ARG" ] || usage "--data is empty: \${CLAUDE_PLUGIN_DATA} was not substituted"
case $DATA_ARG in
  *'${'*) usage "--data still holds \${: $DATA_ARG" ;;
esac
[ $# -gt 0 ] || usage 'no verb'
VERB=$1
shift
DATA=$(posix_path "$DATA_ARG")
case $DATA in
  /*) ;;
  *) DATA=$(pwd)/$DATA ;;
esac
DATA_SHOWN=$(shown_path "$DATA")
CUSTOM=${HOME:-}/.claude/islamic-notifier/sounds
CUSTOM_SHOWN=$(shown_path "$CUSTOM")

# ---- Config, read the way notify.sh reads it (docs/PLAN.md, section 4.5): whitelisted
# keys, the last valid line wins, then ISLAMIC_NOTIFIER_MUTE. Each value's source is kept.
MUTED=0
MUTED_SRC=default
VOLUME=70
VOLUME_SRC=default
PAUSES=on
PAUSES_SRC=default
MODE=both
MODE_SRC=default
read_config() {
  [ -f "$DATA/config" ] || return 0
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
      muted) case $val in 0|1) MUTED=$val MUTED_SRC=config ;; esac ;;
      volume)
        case $val in
          ''|*[!0-9]*) ;;
          *)
            while :; do
              case $val in
                0?*) val=${val#0} ;;
                *) break ;;
              esac
            done
            if [ ${#val} -le 3 ] && [ "$val" -le 100 ]; then
              VOLUME=$val
              VOLUME_SRC=config
            fi ;;
        esac ;;
      pauses) case $val in on|off) PAUSES=$val PAUSES_SRC=config ;; esac ;;
      sounds_mode) case $val in both|bundled|custom) MODE=$val MODE_SRC=config ;; esac ;;
    esac
  done < "$DATA/config"
}
read_config
case ${ISLAMIC_NOTIFIER_MUTE:-} in
  0|1) MUTED=$ISLAMIC_NOTIFIER_MUTE MUTED_SRC=env ;;
esac

# ---- Writes

not_writable() {
  printf 'config not writable (sandbox?) - add %s to sandbox.filesystem.allowWrite or approve the retry\n' \
    "$DATA_SHOWN" >&2
  exit 1
}

# config_lines KEY VALUE: the new config, on stdout.
config_lines() {
  found=
  if [ -f "$DATA/config" ]; then
    first=1
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$first" = 1 ]; then
        line=${line#"$BOM"}
        first=0
      fi
      line=${line%"$CR"}
      case $line in
        "$1="*)
          [ -z "$found" ] || continue
          found=1
          line=$1=$2 ;;
      esac
      printf '%s\n' "$line"
    done < "$DATA/config"
  fi
  [ -n "$found" ] || printf '%s=%s\n' "$1" "$2"
  return 0
}

# commit TMP NAME: rename TMP over DATA/NAME, or remove it and fail.
commit() {
  if ! mv -f "$1" "$DATA/$2" 2>/dev/null; then
    rm -f "$1" 2>/dev/null
    not_writable
  fi
}

set_key() {
  [ -d "$DATA" ] || mkdir -p "$DATA" 2>/dev/null || not_writable
  tmp=$DATA/.config.$$.tmp
  if ! config_lines "$1" "$2" 2>/dev/null > "$tmp"; then
    rm -f "$tmp" 2>/dev/null
    not_writable
  fi
  commit "$tmp" config
}

write_force() {
  [ -d "$DATA" ] || mkdir -p "$DATA" 2>/dev/null || not_writable
  now=$(date +%s)
  tmp=$DATA/.force-next.$$.tmp
  if ! printf '%s %s\n' "$now" "$1" 2>/dev/null > "$tmp"; then
    rm -f "$tmp" 2>/dev/null
    not_writable
  fi
  commit "$tmp" force-next
}

# ---- The dry-run report

REPORT=
# notify_report [--force ID]: notify.sh's report.
notify_report() {
  REPORT=$(CLAUDE_PLUGIN_ROOT=$ROOT CLAUDE_PLUGIN_DATA=$DATA \
    sh "$ROOT/scripts/notify.sh" --dry-run "$@" < /dev/null 2>/dev/null)
}
# report [--force ID]: notify.sh's report, then on Windows play.ps1's, whose keys win there.
report() {
  notify_report "$@"
  if [ "$(rget os)" = win ]; then
    ps_force=
    [ "${1:-}" != --force ] || ps_force=$2
    if [ -n "$ps_force" ]; then
      set -- -Force "$ps_force"
    else
      set --
    fi
    ps_report=$(CLAUDE_PLUGIN_ROOT=$(shown_path "$ROOT") CLAUDE_PLUGIN_DATA=$DATA_SHOWN \
      MSYS2_ARG_CONV_EXCL='*' powershell.exe -NoProfile -NonInteractive -ExecutionPolicy \
      Bypass -File "$(shown_path "$ROOT/scripts/play.ps1")" -DryRun "$@" < /dev/null \
      2>/dev/null | tr -d '\r')
    REPORT="$ps_report
$REPORT"
  fi
}
# rget KEY: the value of KEY in REPORT (the first one), or <unknown>.
rget() {
  v=$(printf '%s\n' "$REPORT" | awk -v k="$1" 'index($0, k "=") == 1 {
      print substr($0, length(k) + 2); found = 1; exit
    } END { if (!found) print "<unknown>" }')
  printf '%s\n' "$v"
}

# ---- Clips: the pool rule of notify.sh (step 14), dir by dir

# scan DIR: N and NAMES (", "-joined) for its clips; IGN_N and IGN for the files the player
# skips (an unsupported extension); LONG_N and LONG for WAVs over 20 s by their header.
scan() {
  N=0 NAMES= IGN_N=0 IGN= LONG_N=0 LONG=
  [ -d "$1" ] || return 0
  for f in "$1"/*; do
    [ -f "$f" ] || continue
    name=${f##*/}
    case $name in
      *.[Ww][Aa][Vv]|*.[Mm][Pp]3)
        N=$((N + 1))
        NAMES=${NAMES:+$NAMES, }$name
        case $name in
          *.[Ww][Aa][Vv])
            if wav_over_20 "$f"; then
              LONG_N=$((LONG_N + 1))
              LONG=${LONG:+$LONG, }$name
            fi ;;
        esac ;;
      *)
        IGN_N=$((IGN_N + 1))
        IGN="${IGN:+$IGN, }$name (unsupported extension)" ;;
    esac
  done
}
# wav_over_20 FILE: true if its data runs over 20 s: (size - 44) / the byte rate at offset
# 28. Unknown (no rate) is false.
wav_over_20() {
  size=$(wc -c < "$1" 2>/dev/null)
  size=${size##* }
  b=$(od -An -tu1 -j28 -N4 "$1" 2>/dev/null)
  read -r b0 b1 b2 b3 <<EOF
$b
EOF
  case $size$b0$b1$b2$b3 in
    ''|*[!0-9]*) return 1 ;;
  esac
  rate=$((b0 + 256 * b1 + 65536 * b2 + 16777216 * b3))
  [ "$rate" -gt 0 ] || return 1
  [ $((size - 44)) -gt $((20 * rate)) ]
}

# ---- Verbs

say() { printf '%s\n' "$@"; }

mute_note() {
  case ${ISLAMIC_NOTIFIER_MUTE:-} in
    0|1) say "Note: ISLAMIC_NOTIFIER_MUTE=$ISLAMIC_NOTIFIER_MUTE in the environment overrides this." ;;
  esac
}

pauses_text() {
  if [ "$1" = on ]; then
    printf 'a clip plays when Claude stops to wait for background work'
  else
    printf 'no clip when Claude stops to wait for background work'
  fi
}

mode_text() {
  case $1 in
    both) printf 'bundled and custom clips' ;;
    bundled) printf 'bundled clips only' ;;
    custom) printf 'custom clips only' ;;
  esac
}

v_mute() {
  [ $# -eq 0 ] || usage 'mute takes no argument'
  set_key muted 1
  say 'Muted: no clip plays until /islamic-notifier:unmute (/islamic-notifier:test still plays one).'
  mute_note
}

v_unmute() {
  [ $# -eq 0 ] || usage 'unmute takes no argument'
  set_key muted 0
  if [ "$VOLUME" = 0 ]; then
    say 'Unmuted, but the volume is 0, so nothing plays; raise it with /islamic-notifier:volume.'
  else
    say 'Unmuted: a clip plays when this reply ends.'
  fi
  mute_note
}

v_volume() {
  [ $# -le 1 ] || usage 'volume takes at most one value'
  if [ $# -eq 0 ]; then
    say "Volume: $VOLUME ($VOLUME_SRC), on a scale of 0 to 100."
    return
  fi
  case $1 in
    0|[1-9]|[1-9][0-9]|100) ;;
    *) usage "volume must be a whole number from 0 to 100, not: $1" ;;
  esac
  set_key volume "$1"
  if [ "$1" = 0 ]; then
    say 'Volume set to 0: nothing plays until you raise it.'
  elif [ "$MUTED" = 1 ]; then
    say "Volume set to $1; sounds are muted, so run /islamic-notifier:unmute to hear it."
  else
    say "Volume set to $1; a clip plays at this volume when this reply ends."
  fi
}

v_pauses() {
  [ $# -le 1 ] || usage 'pauses takes at most one value'
  if [ $# -eq 0 ]; then
    say "Pauses: $PAUSES ($PAUSES_SRC): $(pauses_text "$PAUSES")."
    return
  fi
  case $1 in
    on|off) ;;
    *) usage "pauses must be on or off, not: $1" ;;
  esac
  set_key pauses "$1"
  say "Pauses set to $1: $(pauses_text "$1")."
}

make_custom() {
  [ -d "$CUSTOM" ] && return 0
  if ! mkdir -p "$CUSTOM" 2>/dev/null; then
    printf 'could not create %s (sandbox?) - add it to sandbox.filesystem.allowWrite or approve the retry\n' \
      "$CUSTOM_SHOWN" >&2
    exit 1
  fi
}

v_sounds() {
  case ${1:-} in
    '')
      make_custom
      say "Custom sounds folder: $CUSTOM_SHOWN" \
        "Mode: $MODE ($MODE_SRC), $(mode_text "$MODE"). Add .wav or .mp3 clips under 20 s; /islamic-notifier:sounds list shows them." ;;
    list)
      [ $# -eq 1 ] || usage 'sounds list takes no argument'
      scan "$ROOT/sounds"
      b_n=$N b_names=${NAMES:-none} ign_n=$IGN_N ign=$IGN long_n=$LONG_N long=$LONG
      scan "$CUSTOM"
      say "Bundled ($b_n): $b_names" "Custom ($N): ${NAMES:-none}"
      ign_n=$((ign_n + IGN_N))
      ign=$ign${ign:+${IGN:+, }}$IGN
      long_n=$((long_n + LONG_N))
      long=$long${long:+${LONG:+, }}$LONG
      [ "$ign_n" = 0 ] || say "Ignored ($ign_n): $ign"
      [ "$long_n" = 0 ] || say "Over 20 s, still played but cut at 30 s ($long_n): $long"
      say "Mode: $MODE ($MODE_SRC), $(mode_text "$MODE"); custom folder: $CUSTOM_SHOWN" ;;
    open)
      [ $# -eq 1 ] || usage 'sounds open takes no argument'
      make_custom
      notify_report
      opener=
      target=$CUSTOM
      case $(rget os) in
        mac) opener=open ;;
        win) opener=explorer.exe target=$CUSTOM_SHOWN ;;
        wsl)
          if command -v wslpath > /dev/null 2>&1; then
            w=$(wslpath -w "$CUSTOM" 2>/dev/null) && [ -n "$w" ] && opener=explorer.exe target=$w
          fi ;;
        *) opener=xdg-open ;;
      esac
      if [ -n "$opener" ] && command -v "$opener" > /dev/null 2>&1; then
        # explorer.exe exits 1 even when it opened the folder, so no status is trusted.
        MSYS2_ARG_CONV_EXCL='*' "$opener" "$target" < /dev/null > /dev/null 2>&1
        say "Opened $CUSTOM_SHOWN"
      else
        say "Cannot open folders here; the custom sounds folder is $CUSTOM_SHOWN"
      fi ;;
    mode)
      [ $# -eq 2 ] || usage 'sounds mode takes one of both, bundled, custom'
      case $2 in
        both|bundled|custom) ;;
        *) usage "sounds mode must be both, bundled or custom, not: $2" ;;
      esac
      set_key sounds_mode "$2"
      say "Sounds mode set to $2: $(mode_text "$2")." ;;
    *) usage "unknown sounds argument: $1" ;;
  esac
}

v_test() {
  [ $# -le 1 ] || usage 'test takes at most one id'
  id='*'
  row=
  if [ $# -eq 1 ]; then
    row=$(awk -F '\t' -v id="$1" 'NR > 1 && $1 == id { print $2 "\t" $3 "\t" $4; exit }' \
      "$TSV" 2>/dev/null)
    if [ -z "$row" ]; then
      ids=$(awk -F '\t' 'NR > 1 { printf "%s%s", sep, $1; sep = ", " }' "$TSV" 2>/dev/null)
      usage "unknown id: $1 (ids: $ids)"
    fi
    id=$1
  fi
  write_force "$id"
  report --force "$id"
  pool=$(rget pool)
  if [ -n "$row" ]; then
    tab=$(printf '\t')
    arabic=${row%%"$tab"*}
    rest=${row#*"$tab"}
    say "Next: $arabic" "${rest%%"$tab"*} - ${rest#*"$tab"}"
  else
    say 'Next: a random dhikr.'
  fi
  if [ "$pool" = 0 ]; then
    if [ "$id" = '*' ]; then
      say "No clip found: add .wav or .mp3 clips to $CUSTOM_SHOWN"
    else
      say "No clip for $id yet: add $id.wav or $id.mp3 to $CUSTOM_SHOWN"
    fi
  else
    say 'It plays when this reply ends, even if muted.'
  fi
  say 'If you hear nothing, run /islamic-notifier:status.'
}

v_status() {
  [ $# -eq 0 ] || usage 'status takes no argument'
  report
  os=$(rget os)
  version=$(awk -F '"' '/"version"[ \t]*:/ { print $4; exit }' \
    "$ROOT/.claude-plugin/plugin.json" 2>/dev/null)
  shell='/bin/sh'
  [ "$os" != win ] || shell='Git Bash'
  scan "$ROOT/sounds"
  b_n=$N
  scan "$CUSTOM"
  last=none
  if [ -f "$DATA/last-file" ]; then
    IFS= read -r last < "$DATA/last-file" || [ -n "$last" ] || last=none
    last=${last%"$CR"}
    [ -n "$last" ] || last=none
  fi
  probe=$DATA/.writable.$$
  if { [ -d "$DATA" ] || mkdir -p "$DATA"; } 2>/dev/null && : 2>/dev/null > "$probe"; then
    rm -f "$probe"
    writable='writable'
  else
    writable="not writable (sandbox?) - add $DATA_SHOWN to sandbox.filesystem.allowWrite or approve the retry"
  fi
  say "islamic-notifier ${version:-<unknown>} on $os; hooks run in $shell." \
    "Next reply end: $(rget decision); player $(rget player) at volume $(rget player_volume); remote session: $(rget remote)." \
    "Settings: muted $MUTED ($MUTED_SRC), volume $VOLUME ($VOLUME_SRC), pauses $PAUSES ($PAUSES_SRC), sounds_mode $MODE ($MODE_SRC)." \
    "Clips: $b_n bundled, $N custom; last played: $last." \
    "Data dir: $DATA_SHOWN, $writable."
  if [ "$os" = win ]; then
    say "Windows: execution policy $(rget execution_policy); MediaPlayer $(rget media_player)."
  fi
}

case $VERB in
  test) v_test "$@" ;;
  mute) v_mute "$@" ;;
  unmute) v_unmute "$@" ;;
  volume) v_volume "$@" ;;
  pauses) v_pauses "$@" ;;
  sounds) v_sounds "$@" ;;
  status) v_status "$@" ;;
  *) usage "unknown verb: $VERB" ;;
esac
exit 0
