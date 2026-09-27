#!/bin/sh
# Tests for plugins/islamic-notifier/scripts/notify.sh (docs/PLAN.md, section 10). POSIX sh,
# no framework. Prints "pass=N fail=M" and exits non-zero if any test fails; each failure is
# explained on stderr.
#
# Usage, from the repo root:
#   sh tests/notify_test.sh
#   TEST_SHELL=dash dash tests/notify_test.sh    notify.sh runs as "$TEST_SHELL notify.sh"
#
# No test sleeps, plays audio or starts PowerShell: players, pactl, powershell.exe, cygpath,
# wslpath, uname and timeout are shims (tests/lib.sh). Ages are epochs written relative to
# `date +%s`, with a margin of a few seconds either side of each limit.

case $0 in
  */*) TESTS=${0%/*} ;;
  *) TESTS=. ;;
esac
TESTS=$(cd "$TESTS" && pwd) || exit 2
REPO=${TESTS%/*}
NOTIFY=$REPO/plugins/islamic-notifier/scripts/notify.sh
FIXTURES=$TESTS/fixtures

. "$TESTS/lib.sh"
lib_init

# --- harness ---------------------------------------------------------------------------

t_harness_sandbox_paths_have_spaces() {
  for p in "$SB_HOME" "$SB_ROOT" "$SB_DATA" "$SB_STATE" "$SB_SYS" "$TOOLBOX"; do
    case $p in *' '*) ;; *) fail "no space in $p" ;; esac
  done
}

t_harness_path_has_no_host_programs() {
  for p in afplay paplay pw-play aplay mpg123 ffplay mpv pactl powershell.exe cygpath \
    wslpath timeout sh bash dash; do
    found=$(env -i "PATH=$SB_PATH" "$TEST_SHELL_PATH" -c 'command -v "$1"' x "$p")
    assert_eq '' "$found" "$p on the sandbox PATH"
  done
  found=$(env -i "PATH=$SB_PATH" "$TEST_SHELL_PATH" -c 'command -v uname')
  assert_eq "$SB/shims/uname" "$found" "uname on the sandbox PATH"
}

t_harness_shim_logs_argv_and_obeys_config() {
  shim afplay 3 'some output'
  got=$(env -i "PATH=$SB_PATH" "$SB/shims/afplay" 'a b' '' c)
  rc=$?
  assert_eq 3 "$rc" "shim exit status"
  assert_eq 'some output' "$got" "shim stdout"
  assert_calls afplay 'afplay|a b||c'
}

t_harness_stub_hook_is_quiet() {
  hook
  assert_eq 0 "$RC" "exit status"
}

t_tone_is_deterministic_pcm_wav() {
  sh "$REPO/tools/make-test-tone.sh" "$SB/one.wav" || fail "make-test-tone.sh failed"
  sh "$REPO/tools/make-test-tone.sh" "$SB/two.wav" || fail "make-test-tone.sh failed"
  assert_eq "$(cksum < "$SB/one.wav")" "$(cksum < "$SB/two.wav")" "cksum of two runs"
  size=$(wc -c < "$SB/one.wav")
  assert_eq 88244 "${size##* }" "size"
  head=$(od -An -tx1 -N44 "$SB/one.wav" | tr -d ' \n')
  # RIFF, size 88236, WAVE, "fmt ", 16, PCM 1, 1 channel, 44100 Hz, 88200 B/s, block 2,
  # 16 bits, data, size 88200.
  assert_eq 52494646ac58010057415645666d74201000000001000100\
44ac000088580100020010006461746188580100 "$head" "header bytes"
}

t harness_sandbox_paths_have_spaces
t harness_path_has_no_host_programs
t harness_shim_logs_argv_and_obeys_config
t harness_stub_hook_is_quiet
t tone_is_deterministic_pcm_wav

lib_summary
