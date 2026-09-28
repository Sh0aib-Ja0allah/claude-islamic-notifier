#!/bin/sh
# Run the Stop hook's exact command string from hooks.json under each shell this machine has,
# the way Claude Code runs it (docs/PLAN.md, section 10, the polyglot parse matrix). POSIX sh.
#
# The plugin root is a stub whose path contains a space. Its scripts/notify.sh and
# scripts/play.ps1 only record that they ran, with their arguments and the stdin they got.
# Per run, expected (PLAN.md:597-600): exactly one branch runs, the hook exits 0, and the
# Stop input arrives; on the sh side, the hook also returns, and closes its output, without
# waiting for notify.sh (PLAN.md:259-263).
#
# Legs, by id:
#   sh, dash, bash-posix,    <shell> -c COMMAND, once with ${CLAUDE_PLUGIN_ROOT} substituted
#   bash, busybox-ash        as Claude Code does in Git Bash mode (C:/... with forward
#                            slashes), once left for the shell to expand from the environment.
#                            bash-posix is bash --posix, busybox-ash is busybox ash; plain
#                            bash is what Git Bash runs.
#   powershell.exe, pwsh     Windows only, where Claude Code runs hooks in PowerShell when it
#                            has no Git Bash: <exe> -NoProfile -NonInteractive
#                            -ExecutionPolicy Bypass -Command COMMAND, with
#                            ${CLAUDE_PLUGIN_ROOT} rewritten to ${env:CLAUDE_PLUGIN_ROOT}.
# A leg whose shell is not installed is skipped, with the reason. POLYGLOT_REQUIRE lists the
# leg ids that must run (CI sets it per job); a required leg that did not run fails.
#
# Each run prints the time the hook took. An sh-side run over 200 ms is flagged, and under
# GitHub Actions also gets a ::warning::; time never fails a run. PowerShell times are
# reported only, since PowerShell's own start-up takes longer than that.
#
# Prints one line per run and "pass=N fail=M skip=K"; exits non-zero on any failure.
#
# Usage, from the repo root: [POLYGLOT_REQUIRE='sh dash'] sh tests/polyglot_test.sh

unset CDPATH
case $0 in
  */*) TESTS=${0%/*} ;;
  *) TESTS=. ;;
esac
TESTS=$(cd "$TESTS" && pwd) || exit 2
REPO=${TESTS%/*}
HOOKS=$REPO/plugins/islamic-notifier/hooks/hooks.json
FIXTURE=$TESTS/fixtures/stop-idle.json
PASS=0
FAIL=0
SKIP=0
RAN=' '
ROOT_VAR="\${CLAUDE_PLUGIN_ROOT}"
ROOT_ENV_VAR="\${env:CLAUDE_PLUGIN_ROOT}"

# The "command" value of hooks.json, JSON escapes undone.
CMD=$(awk '/"command"[ \t]*:/ {
    s = $0
    sub(/^[^:]*:[ \t]*"/, "", s)
    sub(/"[ \t]*,?[ \t]*$/, "", s)
    out = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (c == "\\") {
        i++
        c = substr(s, i, 1)
        if (c == "n") c = "\n"
        else if (c == "t") c = "\t"
      }
      out = out c
    }
    print out
    exit
  }' "$HOOKS")
[ -n "$CMD" ] || { printf 'polyglot_test: no command in %s\n' "$HOOKS" >&2; exit 2; }

# subst TEXT FROM TO: TEXT with every FROM replaced by TO, literally.
subst() {
  awk -v s="$1" -v from="$2" -v to="$3" 'BEGIN {
    out = ""
    while ((i = index(s, from)) > 0) {
      out = out substr(s, 1, i - 1) to
      s = substr(s, i + length(from))
    }
    printf "%s", out s
  }'
}

# The clock, in milliseconds. Only differences within one run count, so any steady clock
# will do: GNU date's %N, else /proc/uptime (busybox), else perl (macOS, whose date has no
# %N), else whole seconds.
is_ms() {
  case $1 in
    [1-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) return 0 ;;
  esac
  return 1
}
if is_ms "$(date +%s%3N 2>/dev/null)"; then
  CLOCK=date
elif [ -r /proc/uptime ]; then
  CLOCK=uptime
elif command -v perl > /dev/null 2>&1; then
  CLOCK=perl
else
  CLOCK=seconds
fi
ms() {
  case $CLOCK in
    date) date +%s%3N ;;
    uptime) awk '{ printf "%d\n", $1 * 1000 }' /proc/uptime ;;
    perl) perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000' ;;
    *) printf '%s\n' "$(($(date +%s) * 1000))" ;;
  esac
}

case $(uname -s) in
  MINGW*|MSYS*|CYGWIN*) WINDOWS=1 ;;
  *) WINDOWS= ;;
esac

RUN_DIR=$(mktemp -d) || exit 2
trap 'rm -rf "$RUN_DIR"' EXIT
trap 'exit 2' HUP INT TERM
ROOT="$RUN_DIR/plug in root"
LOG="$RUN_DIR/log"
mkdir -p "$ROOT/scripts" "$LOG" || exit 2
if command -v cygpath > /dev/null 2>&1; then
  ROOT_M=$(cygpath -m "$ROOT")
  ROOT_W=$(cygpath -w "$ROOT")
  LOG_W=$(cygpath -w "$LOG")
else
  ROOT_M=$ROOT
  ROOT_W=$ROOT
  LOG_W=$LOG
fi
printf 'clock=%s windows=%s require=[%s]\n' "$CLOCK" "${WINDOWS:-0}" "${POLYGLOT_REQUIRE:-}"

# The stubs. Each writes <branch>.args, <branch>.stdin, then <branch>.done. notify.sh
# first waits 2 s, so a hook that waits for it (not backgrounded, or holding the output
# pipe) shows as sh.done existing when the hook returns.
{
  printf '#!/bin/sh\n'
  printf "log='%s'\n" "$LOG"
  cat <<'EOF'
sleep 2
printf '%s\n' "$*" > "$log/sh.args"
cat > "$log/sh.stdin"
: > "$log/sh.done"
EOF
} > "$ROOT/scripts/notify.sh"
{
  printf "\$log = '%s'\n" "$LOG_W"
  cat <<'EOF'
$in = ''
if ([Console]::IsInputRedirected) { $in = [Console]::In.ReadToEnd() }
[IO.File]::WriteAllText("$log\ps.args", ($args -join ' '))
[IO.File]::WriteAllText("$log\ps.stdin", $in)
[IO.File]::WriteAllText("$log\ps.done", '')
EOF
} > "$ROOT/scripts/play.ps1"

# check NAME BRANCH OTHER RC T0 T1 ARGS: judge one run. BRANCH sh is an sh-side run.
check() {
  name=$1 branch=$2 other=$3 rc=$4 elapsed=$(($6 - $5)) want_args=$7
  problems=
  if [ "$branch" = sh ] && [ -e "$LOG/sh.done" ]; then
    problems=' hook-waited-for-notify.sh'
  fi
  # The backgrounded notify.sh is still running: give it up to 10 s to finish.
  i=0
  while [ ! -e "$LOG/$branch.done" ] && [ "$i" -lt 100 ]; do
    sleep 0.1 2>/dev/null || sleep 1
    i=$((i + 1))
  done
  [ "$rc" = 0 ] || problems="$problems rc=$rc"
  [ -e "$LOG/$branch.done" ] || problems="$problems no-$branch-branch"
  [ ! -e "$LOG/$other.done" ] || problems="$problems $other-branch-also-ran"
  if [ -e "$LOG/$branch.stdin" ] && cmp -s "$LOG/$branch.stdin" "$FIXTURE"; then
    stdin=ok
  else
    stdin=missing
    problems="$problems stdin-not-received"
  fi
  got_args=$(cat "$LOG/$branch.args" 2>/dev/null)
  [ "$got_args" = "$want_args" ] || problems="$problems args=[$got_args]"
  flag=
  if [ "$branch" = sh ] && [ "$elapsed" -gt 200 ]; then
    flag=' (over 200 ms)'
    if [ "${GITHUB_ACTIONS:-}" = true ]; then
      printf '::warning title=polyglot timing::%s took %s ms, over 200 ms\n' "$name" "$elapsed"
    fi
  fi
  if [ -z "$problems" ]; then
    PASS=$((PASS + 1))
    printf 'ok   %-28s branch=%s rc=%s stdin=%s %s ms%s\n' "$name" "$branch" "$rc" "$stdin" "$elapsed" "$flag"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %-28s%s, %s ms%s\n' "$name" "$problems" "$elapsed" "$flag"
  fi
  rm -f "$LOG"/*
}

# found ID PROGRAM: true if PROGRAM is installed; if not, leg ID is skipped.
found() {
  if p=$(command -v "$2" 2> /dev/null); then
    printf 'leg  %-28s %s\n' "$1" "$p"
    RAN="$RAN$1 "
    return 0
  fi
  printf 'skip %-28s %s is not installed\n' "$1" "$2"
  SKIP=$((SKIP + 1))
  return 1
}

# sh_leg ID SHELL [FLAG]: the hook under SHELL -c, with the root substituted and as a
# variable. Its stdout and stderr go to a pipe, as under Claude Code, and the run ends only
# when that pipe closes.
sh_leg() {
  id=$1
  shift
  found "$id" "$1" || return 0
  for mode in substituted variable; do
    if [ "$mode" = substituted ]; then
      cmd=$(subst "$CMD" "$ROOT_VAR" "$ROOT_M")
    else
      cmd=$CMD
    fi
    t0=$(ms)
    out=$({
      CLAUDE_PLUGIN_ROOT=$ROOT_M "$@" -c "$cmd" < "$FIXTURE"
      printf 'rc=%s\n' "$?"
    } 2>&1)
    t1=$(ms)
    rc=${out##*rc=}
    check "$id, $mode" sh ps "$rc" "$t0" "$t1" '--hook'
  done
}

# ps_leg EXE: the hook under PowerShell with Claude Code's arguments and its ${env:}
# rewrite. MSYS must not rewrite the command as if it held paths.
ps_leg() {
  found "$1" "$1" || return 0
  cmd=$(subst "$CMD" "$ROOT_VAR" "$ROOT_ENV_VAR")
  t0=$(ms)
  out=$({
    CLAUDE_PLUGIN_ROOT=$ROOT_W MSYS2_ARG_CONV_EXCL='*' "$1" -NoProfile -NonInteractive \
      -ExecutionPolicy Bypass -Command "$cmd" < "$FIXTURE"
    printf 'rc=%s\n' "$?"
  } 2>&1)
  t1=$(ms)
  rc=${out##*rc=}
  check "$1" ps sh "$rc" "$t0" "$t1" '-Hook'
}

sh_leg sh sh
sh_leg dash dash
sh_leg bash-posix bash --posix
sh_leg bash bash
sh_leg busybox-ash busybox ash
if [ -n "$WINDOWS" ]; then
  ps_leg powershell.exe
  ps_leg pwsh
else
  printf 'note no PowerShell legs: Claude Code runs hooks in PowerShell only on Windows\n'
fi

for id in ${POLYGLOT_REQUIRE:-}; do
  case $RAN in
    *" $id "*) ;;
    *)
      FAIL=$((FAIL + 1))
      printf 'FAIL required leg %s did not run\n' "$id"
      ;;
  esac
done

printf 'pass=%s fail=%s skip=%s\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ]
