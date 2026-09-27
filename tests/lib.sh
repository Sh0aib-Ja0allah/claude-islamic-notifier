# tests/lib.sh: sandbox, shims and asserts for tests/notify_test.sh. POSIX sh, no framework.
# Sourced, not run.
#
# Every test gets a fresh sandbox under one mktemp dir, and every sandbox path contains a
# space. notify.sh runs under `env -i`, so no host variable (SSH_*, WSL_DISTRO_NAME, ...)
# leaks in, with only:
#   HOME, CLAUDE_PLUGIN_ROOT, CLAUDE_PLUGIN_DATA, XDG_STATE_HOME   sandbox dirs
#   ISLAMIC_NOTIFIER_TEST_SYSROOT   sandbox dir that stands in for /proc/version,
#                                   /.dockerenv, /run/.containerenv and /mnt/c
#   PATH   the sandbox shim dir, then a toolbox of wrappers around a few core tools
# The host's /usr/bin is never on that PATH, so no real player, pactl or PowerShell can run.
# Each shim appends one line per call to $SB/log/<name>: name|arg1|arg2...

# Core tools that notify.sh and the shims may run. Players, uname, pactl, powershell.exe,
# cygpath, wslpath and timeout are never here: a test adds a shim when it wants one.
TOOLBOX_TOOLS='awk cat date head mkdir mv od rm tr'

lib_init() {
  TEST_SHELL=${TEST_SHELL:-sh}
  TEST_SHELL_PATH=$(command -v "$TEST_SHELL")
  case $TEST_SHELL_PATH in
    /*) ;;
    *) printf 'notify_test: TEST_SHELL=%s is not a program\n' "$TEST_SHELL" >&2; exit 2 ;;
  esac
  RUN_DIR=$(mktemp -d) || exit 2
  trap 'rm -rf "$RUN_DIR"' EXIT
  trap 'exit 2' HUP INT TERM
  TOOLBOX="$RUN_DIR/tool box"
  mkdir "$TOOLBOX" || exit 2
  for t in $TOOLBOX_TOOLS; do
    p=$(command -v "$t")
    case $p in
      /*) ;;
      *) printf 'notify_test: %s not found\n' "$t" >&2; exit 2 ;;
    esac
    printf '#!/bin/sh\nexec '\''%s'\'' "$@"\n' "$p" > "$TOOLBOX/$t"
    chmod +x "$TOOLBOX/$t"
  done
  PASS=0
  FAIL=0
  N=0
}

# t NAME: run test function t_NAME in a subshell with a fresh sandbox, then delete it.
t() {
  N=$((N + 1))
  TEST=$1
  new_sandbox
  if ("t_$1"; exit 0); then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$RUN_DIR/t$N"
}

lib_summary() {
  printf 'pass=%s fail=%s\n' "$PASS" "$FAIL"
  [ "$FAIL" = 0 ]
}

new_sandbox() {
  SB="$RUN_DIR/t$N/sand box"
  SB_HOME="$SB/home dir"
  SB_ROOT="$SB/plugin root"
  SB_DATA="$SB/data dir"
  SB_STATE="$SB/state dir"
  SB_SYS="$SB/sys root"
  SB_BUNDLED=$SB_ROOT/sounds
  SB_CUSTOM=$SB_HOME/.claude/islamic-notifier/sounds
  SB_PATH=$SB/shims:$TOOLBOX
  SB_INPUT=$FIXTURES/stop-idle.json
  # Set to empty to leave that variable out of notify.sh's environment.
  SB_ENV_ROOT=1
  SB_ENV_DATA=1
  SB_ENV_STATE=1
  mkdir -p "$SB/shims" "$SB/log" "$SB/cfg" "$SB_HOME" "$SB_ROOT" "$SB_DATA" \
    "$SB_STATE" "$SB_SYS"
  # Without a uname shim, notify.sh would find no uname at all; Linux is the safe default.
  shim uname 0 Linux
}

# nrun [NAME=value ...] [ARG ...]: run notify.sh in the sandbox. NAME=value words go into
# its environment, the other words are its arguments. stdin comes from the caller. stdout
# goes to $SB/out, stderr to $SB/err, and the exit status to RC.
nrun() {
  c=$#
  for a in "$@"; do
    case $a in [A-Za-z_]*=*) set -- "$@" "$a" ;; esac
  done
  set -- "$@" "$TEST_SHELL_PATH" "$NOTIFY"
  i=0
  for a in "$@"; do
    i=$((i + 1))
    [ "$i" -le "$c" ] || break
    case $a in [A-Za-z_]*=*) ;; *) set -- "$@" "$a" ;; esac
  done
  shift "$c"
  env -i "HOME=$SB_HOME" "PATH=$SB_PATH" \
    ${SB_ENV_ROOT:+"CLAUDE_PLUGIN_ROOT=$SB_ROOT"} \
    ${SB_ENV_DATA:+"CLAUDE_PLUGIN_DATA=$SB_DATA"} \
    ${SB_ENV_STATE:+"XDG_STATE_HOME=$SB_STATE"} \
    "ISLAMIC_NOTIFIER_TEST_SYSROOT=$SB_SYS" \
    "$@" > "$SB/out" 2> "$SB/err"
  RC=$?
}

# hook [NAME=value ...] [ARG ...]: notify.sh --hook with $SB_INPUT on stdin. It must exit 0
# and print nothing.
hook() {
  nrun "$@" --hook < "$SB_INPUT"
  expect_quiet_exit
}

expect_quiet_exit() {
  [ "$RC" = 0 ] || fail "notify.sh exited $RC"
  [ ! -s "$SB/out" ] || fail "notify.sh wrote to stdout: $(cat "$SB/out")"
  [ ! -s "$SB/err" ] || fail "notify.sh wrote to stderr: $(cat "$SB/err")"
}

# dry [NAME=value ...] [ARG ...]: notify.sh --dry-run with no stdin. It must exit 0 and keep
# stderr empty; the report is in $SB/out.
dry() {
  nrun "$@" --dry-run < /dev/null
  [ "$RC" = 0 ] || fail "notify.sh --dry-run exited $RC"
  [ ! -s "$SB/err" ] || fail "notify.sh --dry-run wrote to stderr: $(cat "$SB/err")"
}

# rget KEY: the value of KEY in the last report, or <missing>.
rget() {
  while IFS= read -r l; do
    case $l in "$1="*) printf '%s\n' "${l#*=}"; return 0 ;; esac
  done < "$SB/out"
  printf '<missing>\n'
}

# Shims. Each one logs its call to $SB/log/<name>, its cwd to $SB/log/<name>.cwd, and
# whether $SB_DATA/play.lock existed during the call to $SB/log/<name>.lock.

# shim_write NAME: write shim NAME; its body comes from stdin, after the logging preamble.
shim_write() {
  {
    printf '#!/bin/sh\n'
    printf "sb='%s'\n" "$SB"
    printf "tb='%s'\n" "$TOOLBOX"
    cat <<'EOF'
n=${0##*/}
{ printf '%s' "$n"; for a in "$@"; do printf '|%s' "$a"; done; printf '\n'; } >> "$sb/log/$n"
pwd -P >> "$sb/log/$n.cwd"
if [ -d "$sb/data dir/play.lock" ]; then echo held; else echo free; fi >> "$sb/log/$n.lock"
EOF
    cat
  } > "$SB/shims/$1"
  chmod +x "$SB/shims/$1"
}

# shim NAME [RC [STDOUT]]: a fake program that prints STDOUT and exits RC (default 0).
# Change them later with shim_rc and shim_out; shim_err gives it something for stderr.
shim() {
  shim_write "$1" <<'EOF'
[ -f "$sb/cfg/$n.out" ] && cat "$sb/cfg/$n.out"
[ -f "$sb/cfg/$n.err" ] && cat "$sb/cfg/$n.err" >&2
rc=0
[ -f "$sb/cfg/$n.rc" ] && read -r rc < "$sb/cfg/$n.rc"
exit "$rc"
EOF
  [ $# -lt 2 ] || shim_rc "$1" "$2"
  [ $# -lt 3 ] || shim_out "$1" "$3"
}
shim_rc() { printf '%s\n' "$2" > "$SB/cfg/$1.rc"; }
shim_out() { printf '%s\n' "$2" > "$SB/cfg/$1.out"; }
shim_err() { printf '%s\n' "$2" > "$SB/cfg/$1.err"; }

# shim_path NAME: a fake cygpath or wslpath. "-w P" prints C: then P with / turned into \.
# "-u P" prints $SB/cfg/NAME.u if it exists, else fails.
shim_path() {
  shim_write "$1" <<'EOF'
if [ "$1" = -u ]; then
  [ -f "$sb/cfg/$n.u" ] || exit 1
  cat "$sb/cfg/$n.u"
  exit 0
fi
printf 'C:'
printf '%s\n' "$2" | tr / '\\'
EOF
}

# winpath P: what shim_path prints for "-w P".
winpath() { printf 'C:'; printf '%s\n' "$1" | tr / '\\'; }

# shim_timeout: a fake timeout that logs its call, drops "-k 2 30" and runs the rest.
shim_timeout() {
  shim_write timeout <<'EOF'
shift 3
exec "$@"
EOF
}

# shim_clock: a fake date whose clock jumps 10 s forward on every call.
shim_clock() {
  shim_write date <<'EOF'
k=0
[ -f "$sb/cfg/clock" ] && read -r k < "$sb/cfg/clock"
k=$((k + 1))
printf '%s\n' "$k" > "$sb/cfg/clock"
now=$("$tb/date" +%s)
printf '%s\n' "$((now + 10 * k))"
EOF
}

calls() { cat "$SB/log/$1" 2>/dev/null; }

# Fixtures.
now() { date +%s; }
ago() { printf '%s\n' "$(($(date +%s) - $1))"; }

# put FILE [LINE ...]: write FILE with one LF-ended line per LINE, making its directory.
put() {
  f=$1
  shift
  mkdir -p "${f%/*}"
  : > "$f"
  for l in "$@"; do printf '%s\n' "$l" >> "$f"; done
}

# clip bundled|custom NAME: add an (empty) clip to the bundled or custom sounds dir.
clip() {
  if [ "$1" = bundled ]; then d=$SB_BUNDLED; else d=$SB_CUSTOM; fi
  mkdir -p "$d"
  : > "$d/$2"
}

# Asserts. A failed assert ends the test.
fail() {
  printf 'FAIL %s: %s\n' "$TEST" "$*" >&2
  exit 1
}
assert_eq() { [ "$1" = "$2" ] || fail "$3: expected [$1], got [$2]"; }
assert_calls() { assert_eq "$2" "$(calls "$1")" "calls of $1"; }
assert_not_called() { [ ! -e "$SB/log/$1" ] || fail "$1 was called: $(calls "$1")"; }
assert_file() { [ -e "$1" ] || fail "missing: $1"; }
assert_no_file() { [ ! -e "$1" ] || fail "should not exist: $1"; }
assert_content() { assert_eq "$2" "$(cat "$1" 2>/dev/null)" "content of ${1##*/}"; }
