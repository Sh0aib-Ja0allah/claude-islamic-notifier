#!/bin/sh
# Run the Stop hook's exact command string from hooks.json under each shell this machine has,
# the way Claude Code runs it (docs/PLAN.md, section 10, the polyglot parse matrix). POSIX sh.
# The CI matrix (busybox, macOS /bin/sh, pwsh 7) is M3b.
#
# The plugin root is a stub whose path contains a space. Its scripts/notify.sh and
# scripts/play.ps1 only record that they ran, with their arguments and the stdin they got.
# Per shell, expected (PLAN.md:597-600): exactly one branch runs, the hook exits 0, and the
# Stop input arrives; on the sh side, the hook also returns, and closes its output, without
# waiting for notify.sh (PLAN.md:259-263). The time the hook itself took is printed,
# flagged when over 200 ms.
#   sh, dash, bash --posix,  <shell> -c COMMAND, once with ${CLAUDE_PLUGIN_ROOT} substituted
#   bash (Git Bash)
#                            as Claude Code does in Git Bash mode (C:/... with forward
#                            slashes), once left for the shell to expand from the environment
#   powershell.exe           -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command
#                            COMMAND, with ${CLAUDE_PLUGIN_ROOT} rewritten to
#                            ${env:CLAUDE_PLUGIN_ROOT}
# Prints one line per run and "pass=N fail=M"; exits non-zero on any failure.
#
# Usage, from the repo root: sh tests/polyglot_test.sh

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

# Milliseconds since the epoch where date has %N (GNU), else whole seconds.
ms() {
  t=$(date +%s%3N 2>/dev/null)
  case $t in
    ''|*[!0-9]*) t=$(($(date +%s) * 1000)) ;;
  esac
  printf '%s\n' "$t"
}

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

# check NAME BRANCH OTHER RC T0 T1 ARGS: judge one run.
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
  [ "$elapsed" -le 200 ] || flag=' (over 200 ms)'
  if [ -z "$problems" ]; then
    PASS=$((PASS + 1))
    printf 'ok   %-28s branch=%s rc=%s stdin=%s %s ms%s\n' "$name" "$branch" "$rc" "$stdin" "$elapsed" "$flag"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %-28s%s, %s ms%s\n' "$name" "$problems" "$elapsed" "$flag"
  fi
  rm -f "$LOG"/*
}

# The sh-family shells, with the root substituted and as a variable. Plain bash is what Git
# Bash runs. The hook's stdout and stderr go to a pipe, as under Claude Code, and the run
# ends only when that pipe closes.
for shell in sh dash 'bash --posix' bash; do
  set -- $shell
  command -v "$1" > /dev/null 2>&1 || { printf 'skip %s: not installed\n' "$shell"; continue; }
  for mode in substituted variable; do
    if [ "$mode" = substituted ]; then
      cmd=$(subst "$CMD" '${CLAUDE_PLUGIN_ROOT}' "$ROOT_M")
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
    check "$shell, $mode" sh ps "$rc" "$t0" "$t1" '--hook'
  done
done

# Windows PowerShell with Claude Code's arguments and its ${env:} rewrite. MSYS must not
# rewrite the command as if it held paths.
if command -v powershell.exe > /dev/null 2>&1; then
  cmd=$(subst "$CMD" '${CLAUDE_PLUGIN_ROOT}' '${env:CLAUDE_PLUGIN_ROOT}')
  t0=$(ms)
  out=$({
    CLAUDE_PLUGIN_ROOT=$ROOT_W MSYS2_ARG_CONV_EXCL='*' powershell.exe -NoProfile -NonInteractive \
      -ExecutionPolicy Bypass -Command "$cmd" < "$FIXTURE"
    printf 'rc=%s\n' "$?"
  } 2>&1)
  t1=$(ms)
  rc=${out##*rc=}
  check 'powershell.exe' ps sh "$rc" "$t0" "$t1" '-Hook'
else
  printf 'skip powershell.exe: not installed\n'
fi

printf 'pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
