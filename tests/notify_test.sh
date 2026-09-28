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
# `date +%s`. Tests at a limit (MIN_GAP, STALE_LOCK, FORCE_TTL, the 1 s fast failure) also
# freeze notify.sh's clock with a date shim, so a slow machine cannot move them across it;
# the others keep a margin of 20 s or more.

unset CDPATH
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

# win: fake Git Bash on Windows, with cygpath and powershell.exe shims.
win() {
  shim_out uname MINGW64_NT-10.0-26200
  shim_path cygpath
  shim powershell.exe
}

# ps_line [ARG ...]: the powershell.exe call notify.sh makes on win, then ARGs.
ps_line() {
  printf 'powershell.exe|-NoProfile|-NonInteractive|-ExecutionPolicy|Bypass|-File|%s|-Worker' \
    "$(winpath "$SB_ROOT/scripts/play.ps1")"
  for a in "$@"; do printf '|%s' "$a"; done
  printf '\n'
}

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

t_tone_is_deterministic_pcm_wav() {
  sh "$REPO/tools/make-test-tone.sh" "$SB/one.wav" || fail "make-test-tone.sh failed"
  (cd "$SB" && sh "$REPO/tools/make-test-tone.sh" two.wav) || fail "make-test-tone.sh failed"
  assert_eq "$(cksum < "$SB/one.wav")" "$(cksum < "$SB/two.wav")" "cksum of two runs"
  # Integer math only, so the bytes are the same on every awk.
  assert_eq '1805358920 88244' "$(cksum < "$SB/one.wav")" "cksum"
  size=$(wc -c < "$SB/one.wav")
  assert_eq 88244 "${size##* }" "size"
  head=$(od -An -tx1 -N44 "$SB/one.wav" | tr -d ' \n')
  # RIFF, size 88236, WAVE, "fmt ", 16, PCM 1, 1 channel, 44100 Hz, 88200 B/s, block 2,
  # 16 bits, data, size 88200.
  assert_eq 52494646ac58010057415645666d74201000000001000100\
44ac000088580100020010006461746188580100 "$head" "header bytes"
}

# --- contract: exit 0, silent, report --------------------------------------------------------

t_hook_idle_exits_0_quietly() {
  hook
  assert_eq 0 "$RC" "exit status"
}

t_hook_bad_arguments_exit_0_quietly() {
  nrun --bogus x < /dev/null
  expect_quiet_exit
  nrun --hook --force < "$SB_INPUT"
  expect_quiet_exit
}

t_hook_ignores_inherited_shell_options() {
  mac
  clip bundled subhanallah.wav
  clip bundled alhamdulillah.wav
  put "$SB_DATA/last-play" "$(ago 60)"
  put "$SB_DATA/last-file" "$SB_BUNDLED/subhanallah.wav"
  # Read by bash when it runs as sh; dash ignores it.
  hook SHELLOPTS=errexit:noclobber:noglob:nounset
  assert_calls afplay "$(afplay_line "$SB_BUNDLED/alhamdulillah.wav")"
  assert_content "$SB_DATA/last-file" "$SB_BUNDLED/alhamdulillah.wav"
}

t_hook_silences_what_it_runs() {
  win
  shim_out powershell.exe 'played something'
  shim_err powershell.exe 'a warning'
  hook
  assert_calls powershell.exe "$(ps_line)"
}

t_dryrun_keys_are_stable() {
  dry
  keys=$(awk -F= '{ printf "%s ", $1 }' "$SB/out")
  assert_eq "report os root data input force muted volume pauses sounds_mode remote \
force_local gap lock pool clip player fallback player_volume decision " "$keys" "report keys"
  assert_eq 1 "$(rget report)" report
  assert_eq "$SB_ROOT" "$(rget root)" root
  assert_eq "$SB_DATA" "$(rget data)" data
  assert_eq none "$(rget input)" "input without --hook"
  assert_eq none "$(rget remote)" remote
  assert_eq 0 "$(rget force_local)" force_local
}

t_dryrun_env_var_reports_and_hands_off_nothing() {
  win
  nrun ISLAMIC_NOTIFIER_DRY_RUN=1 --hook < "$SB_INPUT"
  assert_eq 0 "$RC" "exit status"
  assert_eq idle "$(rget input)" input
  assert_eq handoff "$(rget decision)" decision
  assert_not_called powershell.exe
}

t_dryrun_changes_no_file() {
  SB_ENV_DATA=
  win
  dry
  assert_eq "$SB_STATE/islamic-notifier" "$(rget data)" data
  assert_no_file "$SB_STATE/islamic-notifier"
  put "$SB_STATE/islamic-notifier/force-next" "$(now) subhanallah"
  marker=$(cat "$SB_STATE/islamic-notifier/force-next")
  dry ISLAMIC_NOTIFIER_DEBUG=1
  assert_content "$SB_STATE/islamic-notifier/force-next" "$marker"
  assert_eq force-next "$(cd "$SB_STATE/islamic-notifier" && echo *)" "data dir files"
  assert_not_called powershell.exe
  assert_not_called cygpath
}

t_dryrun_reports_first_skip_and_every_fact() {
  put "$SB_DATA/config" muted=1 pauses=off
  nrun SSH_TTY=/dev/pts/0 --hook --dry-run < "$FIXTURES/stop-background.json"
  assert_eq skip-muted "$(rget decision)" decision
  assert_eq paused "$(rget input)" input
  assert_eq ssh "$(rget remote)" remote
  assert_eq linux "$(rget os)" os
}

t_debug_log_only_with_debug() {
  win
  hook
  assert_no_file "$SB_DATA/debug.log"
  hook ISLAMIC_NOTIFIER_DEBUG=1
  case $(cat "$SB_DATA/debug.log") in
    *'handoff rc=0'*) ;;
    *) fail "debug.log: $(cat "$SB_DATA/debug.log")" ;;
  esac
}

t_data_falls_back_to_xdg_state_home() {
  SB_ENV_DATA=
  win
  put "$SB_STATE/islamic-notifier/force-next" "$(now) subhanallah"
  hook
  assert_calls powershell.exe "$(ps_line -Force subhanallah)"
  assert_no_file "$SB_STATE/islamic-notifier/force-next"
}

t_data_falls_back_to_home_local_state() {
  SB_ENV_DATA=
  SB_ENV_STATE=
  dry
  assert_eq "$SB_HOME/.local/state/islamic-notifier" "$(rget data)" data
  hook
  [ -d "$SB_HOME/.local/state/islamic-notifier" ] || fail "fallback data dir not created"
}

t_root_falls_back_to_script_dir() {
  SB_ENV_ROOT=
  dry
  assert_eq "$REPO/plugins/islamic-notifier" "$(rget root)" root
}

# --- section 10 bullet 1: OS detection ----------------------------------------------------

t_os_darwin_is_mac() {
  shim_out uname Darwin
  dry
  assert_eq mac "$(rget os)" os
}

t_os_linux_is_linux() {
  dry
  assert_eq linux "$(rget os)" os
  assert_calls uname 'uname|-s'
}

t_os_linux_with_wsl_distro_name_is_wsl() {
  dry WSL_DISTRO_NAME=Ubuntu
  assert_eq wsl "$(rget os)" os
}

t_os_linux_with_microsoft_proc_version_is_wsl() {
  put "$SB_SYS/proc/version" \
    'Linux version 5.15.167.4-microsoft-standard-WSL2 (root@f9c826d3017f) (gcc (GCC) 11.2.0)'
  dry
  assert_eq wsl "$(rget os)" "os, WSL2"
  put "$SB_SYS/proc/version" 'Linux version 4.4.0-19041-Microsoft (Microsoft@Microsoft.com)'
  dry
  assert_eq wsl "$(rget os)" "os, WSL1"
}

t_os_linux_with_plain_proc_version_is_linux() {
  put "$SB_SYS/proc/version" 'Linux version 6.8.0-45-generic (buildd@lcy02-amd64-075)'
  dry
  assert_eq linux "$(rget os)" os
}

t_os_mingw_is_win() {
  shim_out uname MINGW64_NT-10.0-26200
  dry
  assert_eq win "$(rget os)" os
}

t_os_msys_is_win() {
  shim_out uname MSYS_NT-10.0-26200
  dry
  assert_eq win "$(rget os)" os
}

t_os_cygwin_is_win() {
  shim_out uname CYGWIN_NT-10.0-26200
  dry
  assert_eq win "$(rget os)" os
}

t_os_unknown_is_other() {
  shim_out uname FreeBSD
  dry
  assert_eq other "$(rget os)" os
}

# --- section 10 bullet 2: remote detection ------------------------------------------------

# expect_remote REASON [NAME=value ...]: on win, the hook skips and the report says why.
expect_remote() {
  reason=$1
  shift
  win
  hook "$@"
  assert_not_called powershell.exe
  dry "$@"
  assert_eq "$reason" "$(rget remote)" remote
  assert_eq skip-remote "$(rget decision)" decision
}

t_remote_ssh_connection_skips() { expect_remote ssh 'SSH_CONNECTION=10.0.0.2 50000 10.0.0.1 22'; }
t_remote_ssh_client_skips() { expect_remote ssh 'SSH_CLIENT=10.0.0.2 50000 22'; }
t_remote_ssh_tty_skips() { expect_remote ssh SSH_TTY=/dev/pts/0; }
t_remote_codespaces_skips() { expect_remote codespaces CODESPACES=true; }
t_remote_remote_containers_skips() { expect_remote devcontainer REMOTE_CONTAINERS=true; }
t_remote_claude_code_remote_skips() { expect_remote claude-remote CLAUDE_CODE_REMOTE=true; }
t_remote_gitpod_skips() { expect_remote gitpod GITPOD_WORKSPACE_ID=abc-123; }

t_remote_dockerenv_skips() {
  : > "$SB_SYS/.dockerenv"
  expect_remote container
}

t_remote_containerenv_skips() {
  put "$SB_SYS/run/.containerenv"
  expect_remote container
}

t_remote_force_local_plays() {
  win
  : > "$SB_SYS/.dockerenv"
  hook SSH_TTY=/dev/pts/0 ISLAMIC_NOTIFIER_FORCE_LOCAL=1
  assert_calls powershell.exe "$(ps_line)"
  dry SSH_TTY=/dev/pts/0 ISLAMIC_NOTIFIER_FORCE_LOCAL=1
  assert_eq ssh "$(rget remote)" remote
  assert_eq 1 "$(rget force_local)" force_local
  assert_eq handoff "$(rget decision)" decision
}

t_remote_values_other_than_true_do_not_skip() {
  win
  hook CODESPACES=false REMOTE_CONTAINERS=1 CLAUDE_CODE_REMOTE=
  assert_calls powershell.exe "$(ps_line)"
}

t_remote_set_but_empty_counts_as_set() {
  expect_remote ssh SSH_TTY=
  expect_remote gitpod GITPOD_WORKSPACE_ID=
}

# --- section 10 bullet 3: mute, volume 0, force-next -------------------------------------

t_mute_config_skips() {
  win
  put "$SB_DATA/config" muted=1
  hook
  assert_not_called powershell.exe
  dry
  assert_eq skip-muted "$(rget decision)" decision
}

t_mute_env_skips() {
  win
  hook ISLAMIC_NOTIFIER_MUTE=1
  assert_not_called powershell.exe
}

t_mute_volume_0_skips() {
  win
  put "$SB_DATA/config" volume=0
  hook
  assert_not_called powershell.exe
  dry
  assert_eq skip-volume "$(rget decision)" decision
}

t_force_fresh_marker_plays_while_muted() {
  win
  shim_frozen_date
  put "$SB_DATA/config" muted=1
  put "$SB_DATA/force-next" "$((T - 120)) *"
  hook
  assert_calls powershell.exe "$(ps_line -Force '*')"
  assert_no_file "$SB_DATA/force-next"
}

t_force_fresh_marker_plays_while_env_muted() {
  win
  put "$SB_DATA/force-next" "$(now) subhanallah"
  hook ISLAMIC_NOTIFIER_MUTE=1
  assert_calls powershell.exe "$(ps_line -Force subhanallah)"
}

t_force_plays_even_at_volume_0() {
  mac
  shim_frozen_date
  clip bundled subhanallah.wav
  put "$SB_DATA/config" volume=0
  put "$SB_DATA/force-next" "$T *"
  hook
  assert_calls afplay "$(afplay_line "$SB_BUNDLED/subhanallah.wav" 0.00)"
}

t_force_marker_with_a_bad_epoch_is_ignored() {
  win
  shim_frozen_date
  put "$SB_DATA/config" muted=1
  for bad in "0$T" 123456789012345678901234 12a4; do
    put "$SB_DATA/force-next" "$bad *"
    dry
    assert_eq none "$(rget force)" "force for $bad"
    hook
    assert_not_called powershell.exe
    assert_eq config "$(data_files)" "data dir files after $bad"
  done
}

t_force_marker_older_than_120s_is_ignored() {
  win
  shim_frozen_date
  put "$SB_DATA/config" muted=1
  put "$SB_DATA/force-next" "$((T - 121)) *"
  dry
  assert_eq none "$(rget force)" force
  hook
  assert_not_called powershell.exe
  assert_no_file "$SB_DATA/force-next"
}

t_force_marker_from_the_future_is_ignored() {
  win
  put "$SB_DATA/config" muted=1
  put "$SB_DATA/force-next" "$(ago -300) *"
  hook
  assert_not_called powershell.exe
}

t_force_marker_with_crlf_and_no_id_means_any() {
  win
  printf '%s\r\n' "$(now)" > "$SB_DATA/force-next"
  hook
  assert_calls powershell.exe "$(ps_line -Force '*')"
}

t_force_bad_id_means_any() {
  win
  put "$SB_DATA/force-next" "$(now) -Path"
  hook
  assert_calls powershell.exe "$(ps_line -Force '*')"
  put "$SB_DATA/force-next" "$(now) sub hanallah"
  dry
  assert_eq '*' "$(rget force)" force
}

t_force_argument_plays_while_muted_and_keeps_marker() {
  win
  put "$SB_DATA/config" muted=1
  put "$SB_DATA/force-next" "$(now) subhanallah"
  marker=$(cat "$SB_DATA/force-next")
  hook --force alhamdulillah
  assert_calls powershell.exe "$(ps_line -Force alhamdulillah)"
  assert_content "$SB_DATA/force-next" "$marker"
}

t_force_dry_run_leaves_marker() {
  put "$SB_DATA/force-next" "$(now) subhanallah"
  marker=$(cat "$SB_DATA/force-next")
  dry
  assert_eq subhanallah "$(rget force)" force
  dry
  assert_eq subhanallah "$(rget force)" "force on a second dry run"
  assert_content "$SB_DATA/force-next" "$marker"
  assert_eq force-next "$(cd "$SB_DATA" && echo *)" "data dir files"
}

# --- section 10 bullet 4: pauses --------------------------------------------------------------

# pauses_case on|off FIXTURE plays|skips
pauses_case() {
  win
  put "$SB_DATA/config" "pauses=$1"
  SB_INPUT=$FIXTURES/$2
  hook
  if [ "$3" = plays ]; then
    assert_calls powershell.exe "$(ps_line)"
  else
    assert_not_called powershell.exe
  fi
}

t_pauses_on_idle_plays() { pauses_case on stop-idle.json plays; }
t_pauses_on_background_plays() { pauses_case on stop-background.json plays; }
t_pauses_on_crons_plays() { pauses_case on stop-crons.json plays; }
t_pauses_off_idle_plays() { pauses_case off stop-idle.json plays; }
t_pauses_off_background_skips() { pauses_case off stop-background.json skips; }
t_pauses_off_crons_skips() { pauses_case off stop-crons.json skips; }

t_pauses_default_is_on() {
  win
  SB_INPUT=$FIXTURES/stop-background.json
  hook
  assert_calls powershell.exe "$(ps_line)"
}

t_pauses_off_is_beaten_by_force() {
  win
  put "$SB_DATA/config" pauses=off
  put "$SB_DATA/force-next" "$(now) la-hawla"
  SB_INPUT=$FIXTURES/stop-crons.json
  hook
  assert_calls powershell.exe "$(ps_line -Force la-hawla)"
}

t_pauses_input_state_in_report() {
  for f in idle:stop-idle.json paused:stop-background.json paused:stop-crons.json; do
    nrun --hook --dry-run < "$FIXTURES/${f#*:}"
    assert_eq "${f%%:*}" "$(rget input)" "input for ${f#*:}"
  done
}

t_pauses_minified_and_spaced_json() {
  put "$SB_DATA/config" pauses=off
  printf '{"background_tasks":[{"id":"a"}],"session_crons":[]}' > "$SB/in.json"
  nrun --hook --dry-run < "$SB/in.json"
  assert_eq skip-paused "$(rget decision)" "minified, one task"
  printf '{ "background_tasks" : [ ],\r\n\t"session_crons" : [\n ] }' > "$SB/in.json"
  nrun --hook --dry-run < "$SB/in.json"
  assert_eq idle "$(rget input)" "spaced, empty arrays"
  printf '{"last_assistant_message":"see \\"background_tasks\\":[{ here"}' > "$SB/in.json"
  nrun --hook --dry-run < "$SB/in.json"
  assert_eq idle "$(rget input)" "the key quoted inside a string"
}

# --- section 10 bullet 8: config file ----------------------------------------------------------

t_config_defaults_without_a_file() {
  dry
  assert_eq '0 70 on both' "$(rget muted) $(rget volume) $(rget pauses) $(rget sounds_mode)" \
    "muted volume pauses sounds_mode"
}

t_config_bom_and_crlf() {
  printf '\357\273\277muted=1\r\nvolume=40\r\npauses=off\r\nsounds_mode=custom\r\n' \
    > "$SB_DATA/config"
  dry
  assert_eq '1 40 off custom' "$(rget muted) $(rget volume) $(rget pauses) $(rget sounds_mode)" \
    "muted volume pauses sounds_mode"
  win
  hook
  assert_not_called powershell.exe
}

t_config_unknown_keys_and_bad_values_are_ignored() {
  put "$SB_DATA/config" 'colour=blue' 'volume=abc' 'volume=150' 'volume=' 'volume=-5' \
    'muted=yes' 'pauses=maybe' 'sounds_mode=all' ' volume=10' 'volume =10' 'muted' \
    '# volume=20' '' 'VOLUME=30'
  dry
  assert_eq '0 70 on both' "$(rget muted) $(rget volume) $(rget pauses) $(rget sounds_mode)" \
    "muted volume pauses sounds_mode"
}

t_config_last_valid_line_wins() {
  put "$SB_DATA/config" volume=30 volume=abc volume=45 pauses=off pauses=on
  dry
  assert_eq '45 on' "$(rget volume) $(rget pauses)" "volume pauses"
}

t_config_volume_leading_zeros_are_decimal() {
  for v in 070:70 0008:8 000:0 100:100 0100:100; do
    put "$SB_DATA/config" "volume=${v%%:*}"
    dry
    assert_eq "${v#*:}" "$(rget volume)" "volume=${v%%:*}"
  done
}

t_config_last_line_without_newline() {
  printf 'pauses=off\nvolume=55' > "$SB_DATA/config"
  dry
  assert_eq '55 off' "$(rget volume) $(rget pauses)" "volume pauses"
}

t_config_beats_defaults() {
  put "$SB_DATA/config" volume=40 sounds_mode=bundled
  dry
  assert_eq '40 bundled' "$(rget volume) $(rget sounds_mode)" "volume sounds_mode"
}

t_config_env_beats_config() {
  win
  put "$SB_DATA/config" muted=1
  hook ISLAMIC_NOTIFIER_MUTE=0
  assert_calls powershell.exe "$(ps_line)"
  dry ISLAMIC_NOTIFIER_MUTE=0
  assert_eq 0 "$(rget muted)" "muted, env 0 over config 1"
  put "$SB_DATA/config" muted=0
  dry ISLAMIC_NOTIFIER_MUTE=1
  assert_eq 1 "$(rget muted)" "muted, env 1 over config 0"
  dry ISLAMIC_NOTIFIER_MUTE=yes
  assert_eq 0 "$(rget muted)" "muted, env value not 0 or 1"
}

# --- Windows hand-off (B.1 step 11) -------------------------------------------------------

t_handoff_mingw_runs_play_ps1_worker() {
  win
  shim afplay
  shim paplay
  hook
  assert_calls cygpath "cygpath|-w|$SB_ROOT/scripts/play.ps1"
  assert_calls powershell.exe "$(ps_line)"
  assert_not_called afplay
  assert_not_called paplay
  assert_no_file "$SB_DATA/play.lock"
  assert_no_file "$SB_DATA/last-play"
  assert_no_file "$SB_DATA/last-file"
}

t_handoff_msys_and_cygwin() {
  win
  shim_out uname MSYS_NT-10.0-26200
  hook
  shim_out uname CYGWIN_NT-10.0-26200
  hook
  assert_calls powershell.exe "$(ps_line)
$(ps_line)"
}

t_handoff_force_passes_id_and_consumes_marker() {
  win
  put "$SB_DATA/force-next" "$(now) subhanallah"
  hook
  assert_calls powershell.exe "$(ps_line -Force subhanallah)"
  assert_no_file "$SB_DATA/force-next"
  hook
  assert_calls powershell.exe "$(ps_line -Force subhanallah)
$(ps_line)"
}

t_handoff_force_star() {
  win
  put "$SB_DATA/force-next" "$(now) *"
  hook
  assert_calls powershell.exe "$(ps_line -Force '*')"
}

t_handoff_without_cygpath_keeps_the_path() {
  win
  rm -f "$SB/shims/cygpath"
  hook
  assert_calls powershell.exe "powershell.exe|-NoProfile|-NonInteractive|-ExecutionPolicy|\
Bypass|-File|$SB_ROOT/scripts/play.ps1|-Worker"
}

t_handoff_dry_run_starts_nothing() {
  win
  dry
  assert_eq 'win play.ps1 handoff' "$(rget os) $(rget player) $(rget decision)" \
    "os player decision"
  assert_eq '- - - - - -' \
    "$(rget gap) $(rget lock) $(rget pool) $(rget clip) $(rget fallback) $(rget player_volume)" \
    "gap lock pool clip fallback player_volume"
  assert_not_called powershell.exe
  assert_not_called cygpath
}

# --- playback helpers ------------------------------------------------------------------------

# mac: fake macOS with an afplay shim.
mac() {
  shim_out uname Darwin
  shim afplay
}

# played NAME: the clip (last argument) of each call of shim NAME, one per line.
played() { calls "$1" | awk -F'|' '{ print $NF }'; }

# data_files: the names in the data dir, sorted, or * when it is empty.
data_files() { (cd "$SB_DATA" && echo *); }

# afplay_line CLIP [DECIMAL]
afplay_line() { printf 'afplay|-v|%s|-t|30|%s\n' "${2:-0.70}" "$1"; }

# --- section 10 bullet 5: minimum gap, lock, stale lock -----------------------------------

t_gap_last_play_now_skips() {
  mac
  shim_frozen_date
  clip bundled subhanallah.wav
  for age in 0 1; do
    put "$SB_DATA/last-play" "$((T - age))"
    hook
    assert_not_called afplay
  done
  dry
  assert_eq 'recent skip-gap' "$(rget gap) $(rget decision)" "gap decision"
}

t_gap_last_play_3s_ago_plays() {
  mac
  shim_frozen_date
  clip bundled subhanallah.wav
  put "$SB_DATA/last-play" "$((T - 3))"
  dry
  assert_eq 'ok play' "$(rget gap) $(rget decision)" "gap decision"
  hook
  assert_calls afplay "$(afplay_line "$SB_BUNDLED/subhanallah.wav")"
  # MIN_GAP itself (2 s) is enough.
  put "$SB_DATA/last-play" "$((T - 2))"
  hook
  assert_calls afplay "$(afplay_line "$SB_BUNDLED/subhanallah.wav")
$(afplay_line "$SB_BUNDLED/subhanallah.wav")"
}

t_gap_last_play_in_the_future_does_not_block() {
  mac
  clip bundled subhanallah.wav
  put "$SB_DATA/last-play" "$(ago -100)"
  hook
  assert_calls afplay "$(afplay_line "$SB_BUNDLED/subhanallah.wav")"
}

t_gap_bad_last_play_is_ignored() {
  mac
  shim_frozen_date
  clip bundled subhanallah.wav
  for bad in 09 "0$T" 123456789012345678901234 x; do
    put "$SB_DATA/last-play" "$bad"
    rm -f "$SB/log/afplay"
    dry
    assert_eq ok "$(rget gap)" "gap with last-play $bad"
    hook
    assert_calls afplay "$(afplay_line "$SB_BUNDLED/subhanallah.wav")"
  done
}

t_lock_fresh_ts_skips_and_is_left_alone() {
  mac
  shim_frozen_date
  clip bundled subhanallah.wav
  ts=$((T - 34))
  put "$SB_DATA/play.lock/ts" "$ts"
  hook
  assert_not_called afplay
  assert_content "$SB_DATA/play.lock/ts" "$ts"
  dry
  assert_eq 'busy skip-busy' "$(rget lock) $(rget decision)" "lock decision"
}

t_lock_without_ts_skips_and_is_left_alone() {
  mac
  shim_frozen_date
  clip bundled subhanallah.wav
  mkdir -p "$SB_DATA/play.lock"
  dry
  assert_eq 'busy skip-busy' "$(rget lock) $(rget decision)" "lock decision"
  assert_no_file "$SB_DATA/play.lock/ts"
  hook
  assert_not_called afplay
  [ -d "$SB_DATA/play.lock" ] || fail "the lock was removed"
  # The hook stamps it, so a lock whose owner died before writing ts ages like any other.
  assert_content "$SB_DATA/play.lock/ts" "$T"
  shim_out date "$((T + 34))"
  hook
  assert_not_called afplay
  shim_out date "$((T + 35))"
  hook
  assert_calls afplay "$(afplay_line "$SB_BUNDLED/subhanallah.wav")"
}

t_lock_with_a_bad_ts_counts_as_missing() {
  mac
  shim_frozen_date
  clip bundled subhanallah.wav
  for bad in 09 123456789012345678901234 x; do
    put "$SB_DATA/play.lock/ts" "$bad"
    dry
    assert_eq busy "$(rget lock)" "lock with ts $bad"
    hook
    assert_not_called afplay
    assert_content "$SB_DATA/play.lock/ts" "$T"
  done
}

t_lock_far_in_the_future_is_stale() {
  mac
  shim_frozen_date
  clip bundled subhanallah.wav
  put "$SB_DATA/play.lock/ts" "$((T + 34))"
  dry
  assert_eq busy "$(rget lock)" "lock 34 s ahead"
  put "$SB_DATA/play.lock/ts" "$((T + 35))"
  dry
  assert_eq stale "$(rget lock)" "lock 35 s ahead"
  hook
  assert_calls afplay "$(afplay_line "$SB_BUNDLED/subhanallah.wav")"
}

t_lock_ts_is_restamped_before_each_player() {
  shim_clock 1
  clip bundled subhanallah.wav
  shim paplay 1
  shim aplay
  hook
  # Reads: NOW = T+1, then T+2 before paplay, T+3 after it, T+4 before aplay.
  assert_content "$SB/log/paplay.ts" "$((T + 2))"
  assert_content "$SB/log/aplay.ts" "$((T + 4))"
}

t_lock_exit_leaves_a_lock_it_no_longer_owns() {
  mac
  clip bundled subhanallah.wav
  # While afplay plays, another run takes the lock over.
  shim_write afplay <<'EOF'
printf '99999\n' > "$sb/data dir/play.lock/pid"
EOF
  hook
  assert_content "$SB_DATA/play.lock/pid" 99999
}

t_lock_released_and_exit_0_when_signalled() {
  for sig in TERM HUP INT; do
    rm -rf "$SB_DATA/play.lock" "$SB_DATA/last-play" "$SB/log"
    mkdir "$SB/log"
    clip bundled subhanallah.wav
    shim_write paplay <<EOF
kill -$sig "\$PPID"
exit 1
EOF
    shim aplay
    hook
    assert_calls paplay "paplay|--volume=58190|$SB_BUNDLED/subhanallah.wav"
    assert_not_called aplay
    assert_no_file "$SB_DATA/play.lock"
  done
}

t_lock_older_than_35s_is_broken() {
  mac
  shim_frozen_date
  clip bundled subhanallah.wav
  put "$SB_DATA/play.lock/ts" "$((T - 40))"
  dry
  assert_eq 'stale play' "$(rget lock) $(rget decision)" "lock decision"
  # STALE_LOCK itself (35 s) is stale.
  put "$SB_DATA/play.lock/ts" "$((T - 35))"
  dry
  assert_eq 'stale play' "$(rget lock) $(rget decision)" "lock decision at 35 s"
  hook
  assert_calls afplay "$(afplay_line "$SB_BUNDLED/subhanallah.wav")"
  assert_eq 'last-file last-play' "$(data_files)" "data dir files"
}

t_lock_is_held_while_playing_and_gone_after() {
  mac
  clip bundled subhanallah.wav
  dry
  assert_eq free "$(rget lock)" lock
  hook
  assert_content "$SB/log/afplay.lock" held
  assert_no_file "$SB_DATA/play.lock"
}

t_lock_is_released_when_nothing_plays() {
  shim_out uname Darwin
  clip bundled subhanallah.wav
  hook
  assert_no_file "$SB_DATA/play.lock"
  mac
  rm -f "$SB_BUNDLED/subhanallah.wav"
  hook
  assert_no_file "$SB_DATA/play.lock"
  assert_not_called afplay
  assert_eq '*' "$(data_files)" "data dir files"
}

# --- section 10 bullet 6: the pool --------------------------------------------------------

t_pool_empty_calls_no_player() {
  mac
  hook
  assert_not_called afplay
  assert_eq '*' "$(data_files)" "data dir files"
  dry
  assert_eq '0 none skip-no-clip' "$(rget pool) $(rget clip) $(rget decision)" \
    "pool clip decision"
}

t_pool_of_one_plays_it_even_after_itself() {
  mac
  clip bundled subhanallah.wav
  put "$SB_DATA/last-file" "$SB_BUNDLED/subhanallah.wav"
  hook
  assert_calls afplay "$(afplay_line "$SB_BUNDLED/subhanallah.wav")"
}

t_pool_never_repeats_the_last_clip() {
  mac
  clip bundled alhamdulillah.wav
  clip bundled subhanallah.wav
  put "$SB_DATA/last-file" "$SB_BUNDLED/subhanallah.wav"
  for k in 1 2 3 4 5 6; do
    rm -f "$SB_DATA/last-play"
    hook
  done
  a=$SB_BUNDLED/alhamdulillah.wav
  s=$SB_BUNDLED/subhanallah.wav
  assert_eq "$a
$s
$a
$s
$a
$s" "$(played afplay)" "clips in play order"
}

t_pool_mode_both_uses_both_dirs() {
  mac
  clip bundled subhanallah.wav
  clip custom alhamdulillah.wav
  dry
  assert_eq 2 "$(rget pool)" pool
  put "$SB_DATA/last-file" "$SB_BUNDLED/subhanallah.wav"
  hook
  rm -f "$SB_DATA/last-play"
  hook
  assert_eq "$SB_CUSTOM/alhamdulillah.wav
$SB_BUNDLED/subhanallah.wav" "$(played afplay)" "clips in play order"
}

t_pool_mode_bundled() {
  mac
  put "$SB_DATA/config" sounds_mode=bundled
  clip bundled subhanallah.wav
  clip custom alhamdulillah.wav
  dry
  assert_eq "1 $SB_BUNDLED/subhanallah.wav" "$(rget pool) $(rget clip)" "pool clip"
  hook
  assert_eq "$SB_BUNDLED/subhanallah.wav" "$(played afplay)" "clip played"
}

t_pool_mode_custom() {
  mac
  put "$SB_DATA/config" sounds_mode=custom
  clip bundled subhanallah.wav
  clip custom alhamdulillah.wav
  dry
  assert_eq "1 $SB_CUSTOM/alhamdulillah.wav" "$(rget pool) $(rget clip)" "pool clip"
  hook
  assert_eq "$SB_CUSTOM/alhamdulillah.wav" "$(played afplay)" "clip played"
}

t_pool_extensions_match_in_any_case() {
  mac
  for n in A.WAV b.Mp3 c.ogg d.wav.txt wav .hidden.wav; do clip custom "$n"; done
  mkdir -p "$SB_CUSTOM/dir.wav"
  dry
  assert_eq 2 "$(rget pool)" pool
  put "$SB_DATA/last-file" "$SB_CUSTOM/A.WAV"
  hook
  rm -f "$SB_DATA/last-play"
  hook
  assert_eq "$SB_CUSTOM/b.Mp3
$SB_CUSTOM/A.WAV" "$(played afplay)" "clips in play order"
}

t_pool_variant_name_has_the_base_id() {
  mac
  for n in subhanallah.female.wav subhanallah2.wav alhamdulillah.wav; do clip bundled "$n"; done
  put "$SB_DATA/force-next" "$(now) subhanallah"
  dry
  assert_eq "1 $SB_BUNDLED/subhanallah.female.wav" "$(rget pool) $(rget clip)" "pool clip"
  hook
  assert_calls afplay "$(afplay_line "$SB_BUNDLED/subhanallah.female.wav")"
}

t_pool_forced_id_filters_the_pool() {
  mac
  for n in subhanallah alhamdulillah allahu-akbar la-hawla; do clip bundled "$n.wav"; done
  clip custom alhamdulillah.mp3
  for k in 1 2 3 4; do
    rm -f "$SB_DATA/last-play"
    put "$SB_DATA/force-next" "$(now) alhamdulillah"
    hook
  done
  # The first pick is random; after it the two alhamdulillah clips alternate.
  assert_eq 4 "$(played afplay | awk 'END { print NR }')" plays
  prev=
  for f in $(played afplay | awk -F/ '{ print $NF }'); do
    case $f in alhamdulillah.*) ;; *) fail "forced alhamdulillah, played $f" ;; esac
    [ "$f" != "$prev" ] || fail "played $f twice in a row"
    prev=$f
  done
}

t_pool_draw_uses_od_on_urandom() {
  mac
  for n in a b c; do clip bundled "$n.wav"; done
  for rv in '      0:a' '      1:b' '      2:c' '      4:b' '  65535:a'; do
    shim od 0 "${rv%%:*}"
    rm -f "$SB_DATA/last-play" "$SB_DATA/last-file" "$SB/log/afplay"
    hook
    assert_eq "$SB_BUNDLED/${rv#*:}.wav" "$(played afplay)" "pick for od output [${rv%%:*}]"
  done
  # With the last clip left out, the draw is over the other two.
  put "$SB_DATA/last-file" "$SB_BUNDLED/a.wav"
  shim od 0 '      3'
  rm -f "$SB_DATA/last-play" "$SB/log/afplay"
  hook
  assert_eq "$SB_BUNDLED/c.wav" "$(played afplay)" "pick without a.wav"
  case $(calls od) in
    'od|-An|-N2|-tu2|/dev/urandom'*) ;;
    *) fail "od calls: $(calls od)" ;;
  esac
}

t_pool_forced_id_without_a_clip_plays_nothing() {
  mac
  clip bundled subhanallah.wav
  put "$SB_DATA/force-next" "$(now) la-hawla"
  hook
  assert_not_called afplay
  assert_eq '*' "$(data_files)" "data dir files"
}

t_pool_name_with_spaces_plays() {
  mac
  clip custom 'my dhikr clip.wav'
  hook
  assert_calls afplay "$(afplay_line "$SB_CUSTOM/my dhikr clip.wav")"
}

# --- section 10 bullet 7: players, flags, volume ---------------------------------------------

t_player_mac_uses_afplay() {
  mac
  clip bundled subhanallah.wav
  shim paplay
  shim mpv
  dry
  assert_eq 'afplay none 0.70' "$(rget player) $(rget fallback) $(rget player_volume)" \
    "player fallback player_volume"
  hook
  assert_calls afplay "$(afplay_line "$SB_BUNDLED/subhanallah.wav")"
  assert_not_called paplay
  assert_not_called mpv
}

t_player_mac_plays_mp3_with_afplay() {
  mac
  clip bundled subhanallah.mp3
  shim mpg123
  hook
  assert_calls afplay "$(afplay_line "$SB_BUNDLED/subhanallah.mp3")"
  assert_not_called mpg123
}

t_player_mac_without_afplay_plays_nothing() {
  shim_out uname Darwin
  clip bundled subhanallah.wav
  shim mpv
  shim paplay
  hook
  assert_not_called mpv
  assert_not_called paplay
  assert_eq '*' "$(data_files)" "data dir files"
  dry
  assert_eq 'none none skip-no-player' \
    "$(rget player) $(rget player_volume) $(rget decision)" "player player_volume decision"
}

t_player_linux_wav_pipewire_uses_pw_play() {
  clip bundled subhanallah.wav
  shim pw-play
  shim paplay
  shim aplay
  shim pactl 0 'Server Name: PulseAudio (on PipeWire 1.0.5)'
  dry
  assert_eq 'pw-play aplay' "$(rget player) $(rget fallback)" "player fallback"
  hook
  assert_calls pw-play "pw-play|--volume=0.70|$SB_BUNDLED/subhanallah.wav"
  assert_calls pactl 'pactl|info
pactl|info'
  assert_not_called paplay
  assert_not_called aplay
}

t_player_linux_wav_pulseaudio_uses_paplay() {
  clip bundled subhanallah.wav
  shim pw-play
  shim paplay
  shim pactl 0 'Server Name: pulseaudio'
  hook
  assert_calls paplay "paplay|--volume=58190|$SB_BUNDLED/subhanallah.wav"
  assert_not_called pw-play
}

t_player_linux_wav_without_pactl_uses_paplay() {
  clip bundled subhanallah.wav
  shim pw-play
  shim paplay
  hook
  assert_calls paplay "paplay|--volume=58190|$SB_BUNDLED/subhanallah.wav"
  assert_not_called pw-play
}

t_player_linux_wav_pw_play_when_no_paplay() {
  clip bundled subhanallah.wav
  shim pw-play
  shim pactl 0 'Server Name: pulseaudio'
  hook
  assert_calls pw-play "pw-play|--volume=0.70|$SB_BUNDLED/subhanallah.wav"
  assert_not_called pactl
}

t_player_linux_wav_then_aplay_ffplay_mpv() {
  clip bundled subhanallah.wav
  for p in mpv ffplay aplay mpg123; do shim "$p"; done
  dry
  assert_eq 'aplay ffplay,mpv none' "$(rget player) $(rget fallback) $(rget player_volume)" \
    "player fallback player_volume"
  hook
  assert_calls aplay "aplay|-q|$SB_BUNDLED/subhanallah.wav"
  assert_not_called ffplay
  assert_not_called mpg123
}

t_player_linux_wav_ffplay_flags() {
  clip bundled subhanallah.wav
  shim ffplay
  shim mpv
  hook
  assert_calls ffplay "ffplay|-nodisp|-autoexit|-loglevel|quiet|-volume|70|\
$SB_BUNDLED/subhanallah.wav"
  assert_not_called mpv
}

t_player_linux_wav_mpv_flags() {
  clip bundled subhanallah.wav
  shim mpv
  hook
  assert_calls mpv "mpv|--video=no|--terminal=no|--volume=89|$SB_BUNDLED/subhanallah.wav"
}

t_player_linux_wav_never_mpg123() {
  clip bundled subhanallah.wav
  shim mpg123
  hook
  assert_not_called mpg123
  dry
  assert_eq skip-no-player "$(rget decision)" decision
}

t_player_linux_mp3_order() {
  clip bundled subhanallah.mp3
  for p in aplay paplay mpv ffplay mpg123; do shim "$p"; done
  dry
  assert_eq 'mpg123 ffplay,mpv,paplay 22937' \
    "$(rget player) $(rget fallback) $(rget player_volume)" "player fallback player_volume"
  hook
  assert_calls mpg123 "mpg123|-q|-f|22937|$SB_BUNDLED/subhanallah.mp3"
}

t_player_linux_mp3_never_aplay() {
  clip bundled subhanallah.mp3
  shim aplay
  hook
  assert_not_called aplay
}

t_player_linux_mp3_pulse_player_last() {
  clip bundled subhanallah.mp3
  shim pw-play
  shim paplay
  shim pactl 0 'Server Name: PulseAudio (on PipeWire 1.2.7)'
  shim mpv
  dry
  assert_eq 'mpv pw-play' "$(rget player) $(rget fallback)" "player fallback"
}

t_player_other_os_uses_linux_players() {
  shim_out uname FreeBSD
  clip bundled subhanallah.wav
  shim mpv
  hook
  assert_calls mpv "mpv|--video=no|--terminal=no|--volume=89|$SB_BUNDLED/subhanallah.wav"
}

# wsl: fake WSL pieces: powershell.exe, wslpath and paplay shims, one clip, and /mnt/c.
wsl() {
  shim powershell.exe
  shim_path wslpath
  shim paplay
  clip bundled subhanallah.wav
  mkdir -p "$SB_SYS/mnt/c"
}

# wsl_line [VOLUME]: the powershell.exe call notify.sh makes on wsl.
wsl_line() {
  printf 'powershell.exe|-NoProfile|-NonInteractive|-ExecutionPolicy|Bypass|-File|%s|-Worker' \
    "$(winpath "$SB_ROOT/scripts/play.ps1")"
  printf '|%s|%s|%s|%s\n' -Path "$(winpath "$SB_BUNDLED/subhanallah.wav")" -Volume "${1:-70}"
}

t_player_wsl_runs_play_ps1_from_mnt_c() {
  wsl
  dry WSL_DISTRO_NAME=Ubuntu
  assert_eq 'powershell.exe paplay 70' "$(rget player) $(rget fallback) $(rget player_volume)" \
    "player fallback player_volume"
  hook WSL_DISTRO_NAME=Ubuntu
  assert_calls powershell.exe "$(wsl_line)"
  assert_eq "$(cd "$SB_SYS/mnt/c" && pwd -P)" "$(cat "$SB/log/powershell.exe.cwd")" cwd
  assert_not_called paplay
}

t_player_wsl_exit_4_falls_back_to_linux() {
  wsl
  shim_rc powershell.exe 4
  hook WSL_DISTRO_NAME=Ubuntu
  assert_calls powershell.exe "$(wsl_line)"
  assert_calls paplay "paplay|--volume=58190|$SB_BUNDLED/subhanallah.wav"
}

t_player_wsl_exit_4_falls_back_even_when_slow() {
  wsl
  shim_clock 10
  shim_rc powershell.exe 4
  hook WSL_DISTRO_NAME=Ubuntu
  assert_calls paplay "paplay|--volume=58190|$SB_BUNDLED/subhanallah.wav"
}

t_player_wsl_success_busy_and_kills_do_not_fall_back() {
  wsl
  shim_frozen_date
  for rc in 0 3 124 137 143; do
    shim_rc powershell.exe "$rc"
    rm -f "$SB_DATA/last-play"
    hook WSL_DISTRO_NAME=Ubuntu
    assert_not_called paplay
  done
}

t_player_wsl_other_fast_failure_falls_back() {
  wsl
  shim_frozen_date
  shim_rc powershell.exe 126
  hook WSL_DISTRO_NAME=Ubuntu
  assert_calls paplay "paplay|--volume=58190|$SB_BUNDLED/subhanallah.wav"
}

t_player_wsl_other_slow_failure_does_not_fall_back() {
  wsl
  shim_clock 2
  shim_rc powershell.exe 1
  hook WSL_DISTRO_NAME=Ubuntu
  assert_not_called paplay
}

t_player_wsl_without_powershell_uses_linux() {
  wsl
  rm -f "$SB/shims/powershell.exe"
  hook WSL_DISTRO_NAME=Ubuntu
  assert_calls paplay "paplay|--volume=58190|$SB_BUNDLED/subhanallah.wav"
  case $(calls wslpath) in
    'wslpath|-u|C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe') ;;
    *) fail "wslpath calls: $(calls wslpath)" ;;
  esac
}

t_player_wsl_finds_powershell_through_wslpath() {
  wsl
  mkdir -p "$SB/win dir"
  mv "$SB/shims/powershell.exe" "$SB/win dir/powershell.exe"
  printf '%s\n' "$SB/win dir/powershell.exe" > "$SB/cfg/wslpath.u"
  hook WSL_DISTRO_NAME=Ubuntu
  assert_calls powershell.exe "$(wsl_line)"
  assert_not_called paplay
}

t_player_wsl_runs_even_if_cd_fails() {
  wsl
  rmdir "$SB_SYS/mnt/c"
  hook WSL_DISTRO_NAME=Ubuntu
  assert_calls powershell.exe "$(wsl_line)"
  assert_eq "$(cd "$SB" && pwd -P)" "$(cat "$SB/log/powershell.exe.cwd")" cwd
}

# vol_case SHIM CLIP VOLUME:EXPECTED... : for each VOLUME, SHIM's volume argument is EXPECTED.
vol_case() {
  shim "$1"
  clip bundled "$2"
  vc_player=$1
  vc_clip=$2
  shift 2
  for vv in "$@"; do
    put "$SB_DATA/config" "volume=${vv%%:*}"
    rm -f "$SB_DATA/last-play" "$SB/log/$vc_player"
    hook
    case $vc_player in
      afplay) want="afplay|-v|${vv#*:}|-t|30" ;;
      pw-play) want="pw-play|--volume=${vv#*:}" ;;
      paplay) want="paplay|--volume=${vv#*:}" ;;
      mpv) want="mpv|--video=no|--terminal=no|--volume=${vv#*:}" ;;
      ffplay) want="ffplay|-nodisp|-autoexit|-loglevel|quiet|-volume|${vv#*:}" ;;
      mpg123) want="mpg123|-q|-f|${vv#*:}" ;;
    esac
    assert_calls "$vc_player" "$want|$SB_BUNDLED/$vc_clip"
  done
}

t_volume_decimal_for_afplay() {
  shim_out uname Darwin
  vol_case afplay subhanallah.wav 70:0.70 100:1.00 5:0.05 1:0.01 50:0.50
}
t_volume_decimal_for_pw_play() { vol_case pw-play subhanallah.wav 70:0.70 5:0.05; }
t_volume_cubic_for_paplay() { vol_case paplay subhanallah.wav 70:58190 5:24144 100:65536; }
t_volume_cubic_for_mpv() { vol_case mpv subhanallah.wav 70:89 5:37 100:100; }
t_volume_linear_for_ffplay() { vol_case ffplay subhanallah.wav 70:70 5:5; }
t_volume_linear_for_mpg123() { vol_case mpg123 subhanallah.mp3 70:22937 5:1638 100:32768; }

t_volume_wsl_passes_the_integer() {
  wsl
  put "$SB_DATA/config" volume=5
  hook WSL_DISTRO_NAME=Ubuntu
  assert_calls powershell.exe "$(wsl_line 5)"
}

# fall_case RC: paplay fails with RC at once, aplay is next. The clock is frozen unless the
# test brought its own, so "at once" does not depend on how busy the machine is.
fall_case() {
  [ -e "$SB/shims/date" ] || shim_frozen_date
  clip bundled subhanallah.wav
  shim paplay "$1"
  shim aplay
  hook
  assert_calls paplay "paplay|--volume=58190|$SB_BUNDLED/subhanallah.wav"
}

t_fall_fast_failure_tries_the_next_player() {
  fall_case 1
  assert_calls aplay "aplay|-q|$SB_BUNDLED/subhanallah.wav"
}

t_fall_through_more_than_one_player() {
  shim ffplay
  shim_rc aplay 2
  fall_case 1
  assert_calls aplay "aplay|-q|$SB_BUNDLED/subhanallah.wav"
  assert_calls ffplay "ffplay|-nodisp|-autoexit|-loglevel|quiet|-volume|70|\
$SB_BUNDLED/subhanallah.wav"
}

t_fall_success_stops() {
  fall_case 0
  assert_not_called aplay
}

t_fall_timeout_124_stops() {
  fall_case 124
  assert_not_called aplay
}

t_fall_kill_137_stops() {
  fall_case 137
  assert_not_called aplay
}

t_fall_term_143_stops() {
  fall_case 143
  assert_not_called aplay
}

t_fall_failure_taking_1s_is_fast() {
  shim_clock 1
  fall_case 1
  assert_calls aplay "aplay|-q|$SB_BUNDLED/subhanallah.wav"
}

t_fall_slow_failure_stops() {
  shim_clock 2
  fall_case 1
  assert_not_called aplay
}

t_fall_timeout_wraps_every_player() {
  shim_timeout
  fall_case 1
  assert_calls timeout "timeout|-k|2|30|paplay|--volume=58190|$SB_BUNDLED/subhanallah.wav
timeout|-k|2|30|aplay|-q|$SB_BUNDLED/subhanallah.wav"
}

t_fall_timeout_wraps_afplay() {
  mac
  shim_timeout
  clip bundled subhanallah.wav
  hook
  assert_calls timeout "timeout|-k|2|30|$(afplay_line "$SB_BUNDLED/subhanallah.wav")"
  assert_calls afplay "$(afplay_line "$SB_BUNDLED/subhanallah.wav")"
}

# --- state files ---------------------------------------------------------------------------

t_state_written_after_a_play() {
  mac
  clip bundled subhanallah.wav
  before=$(now)
  hook
  after=$(now)
  lp=$(cat "$SB_DATA/last-play")
  [ "$lp" -ge "$before" ] && [ "$lp" -le "$after" ] ||
    fail "last-play $lp is not between $before and $after"
  assert_content "$SB_DATA/last-file" "$SB_BUNDLED/subhanallah.wav"
  assert_eq 'last-file last-play' "$(data_files)" "data dir files"
}

t_state_not_written_when_skipped() {
  mac
  clip bundled subhanallah.wav
  put "$SB_DATA/config" muted=1
  hook
  assert_not_called afplay
  assert_eq config "$(data_files)" "data dir files"
}

t_state_dry_run_writes_nothing() {
  mac
  clip bundled subhanallah.wav
  clip bundled alhamdulillah.wav
  lp=$(ago 10)
  put "$SB_DATA/last-play" "$lp"
  put "$SB_DATA/last-file" "$SB_BUNDLED/subhanallah.wav"
  dry
  assert_eq "2 $SB_BUNDLED/alhamdulillah.wav afplay play" \
    "$(rget pool) $(rget clip) $(rget player) $(rget decision)" "pool clip player decision"
  assert_content "$SB_DATA/last-play" "$lp"
  assert_content "$SB_DATA/last-file" "$SB_BUNDLED/subhanallah.wav"
  assert_eq 'last-file last-play' "$(data_files)" "data dir files"
  assert_not_called afplay
}

t_state_debug_log_records_the_player() {
  mac
  clip bundled subhanallah.wav
  hook ISLAMIC_NOTIFIER_DEBUG=1
  case $(cat "$SB_DATA/debug.log") in
    *'afplay exited 0'*) ;;
    *) fail "debug.log: $(cat "$SB_DATA/debug.log")" ;;
  esac
}

# --- run -------------------------------------------------------------------------------

# harness
t harness_sandbox_paths_have_spaces
t harness_path_has_no_host_programs
t harness_shim_logs_argv_and_obeys_config
t tone_is_deterministic_pcm_wav

# contract: exit 0, silence, the dry-run report, debug log, directories
t hook_idle_exits_0_quietly
t hook_bad_arguments_exit_0_quietly
t hook_ignores_inherited_shell_options
t hook_silences_what_it_runs
t dryrun_keys_are_stable
t dryrun_env_var_reports_and_hands_off_nothing
t dryrun_changes_no_file
t dryrun_reports_first_skip_and_every_fact
t debug_log_only_with_debug
t data_falls_back_to_xdg_state_home
t data_falls_back_to_home_local_state
t root_falls_back_to_script_dir

# section 10 bullet 1: OS detection
t os_darwin_is_mac
t os_linux_is_linux
t os_linux_with_wsl_distro_name_is_wsl
t os_linux_with_microsoft_proc_version_is_wsl
t os_linux_with_plain_proc_version_is_linux
t os_mingw_is_win
t os_msys_is_win
t os_cygwin_is_win
t os_unknown_is_other

# section 10 bullet 2: remote detection
t remote_ssh_connection_skips
t remote_ssh_client_skips
t remote_ssh_tty_skips
t remote_codespaces_skips
t remote_remote_containers_skips
t remote_claude_code_remote_skips
t remote_gitpod_skips
t remote_dockerenv_skips
t remote_containerenv_skips
t remote_force_local_plays
t remote_values_other_than_true_do_not_skip
t remote_set_but_empty_counts_as_set

# section 10 bullet 3: mute, volume 0, force-next
t mute_config_skips
t mute_env_skips
t mute_volume_0_skips
t force_fresh_marker_plays_while_muted
t force_fresh_marker_plays_while_env_muted
t force_plays_even_at_volume_0
t force_marker_with_a_bad_epoch_is_ignored
t force_marker_older_than_120s_is_ignored
t force_marker_from_the_future_is_ignored
t force_marker_with_crlf_and_no_id_means_any
t force_bad_id_means_any
t force_argument_plays_while_muted_and_keeps_marker
t force_dry_run_leaves_marker

# section 10 bullet 4: pauses
t pauses_on_idle_plays
t pauses_on_background_plays
t pauses_on_crons_plays
t pauses_off_idle_plays
t pauses_off_background_skips
t pauses_off_crons_skips
t pauses_default_is_on
t pauses_off_is_beaten_by_force
t pauses_input_state_in_report
t pauses_minified_and_spaced_json

# section 10 bullet 8: config file
t config_defaults_without_a_file
t config_bom_and_crlf
t config_unknown_keys_and_bad_values_are_ignored
t config_last_valid_line_wins
t config_volume_leading_zeros_are_decimal
t config_last_line_without_newline
t config_beats_defaults
t config_env_beats_config

# Windows hand-off
t handoff_mingw_runs_play_ps1_worker
t handoff_msys_and_cygwin
t handoff_force_passes_id_and_consumes_marker
t handoff_force_star
t handoff_without_cygpath_keeps_the_path
t handoff_dry_run_starts_nothing

# section 10 bullet 5: minimum gap, lock, stale lock
t gap_last_play_now_skips
t gap_last_play_3s_ago_plays
t gap_last_play_in_the_future_does_not_block
t gap_bad_last_play_is_ignored
t lock_fresh_ts_skips_and_is_left_alone
t lock_without_ts_skips_and_is_left_alone
t lock_with_a_bad_ts_counts_as_missing
t lock_older_than_35s_is_broken
t lock_far_in_the_future_is_stale
t lock_is_held_while_playing_and_gone_after
t lock_is_released_when_nothing_plays
t lock_ts_is_restamped_before_each_player
t lock_exit_leaves_a_lock_it_no_longer_owns
t lock_released_and_exit_0_when_signalled

# section 10 bullet 6: the pool
t pool_empty_calls_no_player
t pool_of_one_plays_it_even_after_itself
t pool_never_repeats_the_last_clip
t pool_mode_both_uses_both_dirs
t pool_mode_bundled
t pool_mode_custom
t pool_extensions_match_in_any_case
t pool_variant_name_has_the_base_id
t pool_forced_id_filters_the_pool
t pool_draw_uses_od_on_urandom
t pool_forced_id_without_a_clip_plays_nothing
t pool_name_with_spaces_plays

# section 10 bullet 7: players, flags, volume, fall-through
t player_mac_uses_afplay
t player_mac_plays_mp3_with_afplay
t player_mac_without_afplay_plays_nothing
t player_linux_wav_pipewire_uses_pw_play
t player_linux_wav_pulseaudio_uses_paplay
t player_linux_wav_without_pactl_uses_paplay
t player_linux_wav_pw_play_when_no_paplay
t player_linux_wav_then_aplay_ffplay_mpv
t player_linux_wav_ffplay_flags
t player_linux_wav_mpv_flags
t player_linux_wav_never_mpg123
t player_linux_mp3_order
t player_linux_mp3_never_aplay
t player_linux_mp3_pulse_player_last
t player_other_os_uses_linux_players
t player_wsl_runs_play_ps1_from_mnt_c
t player_wsl_exit_4_falls_back_to_linux
t player_wsl_exit_4_falls_back_even_when_slow
t player_wsl_success_busy_and_kills_do_not_fall_back
t player_wsl_other_fast_failure_falls_back
t player_wsl_other_slow_failure_does_not_fall_back
t player_wsl_without_powershell_uses_linux
t player_wsl_finds_powershell_through_wslpath
t player_wsl_runs_even_if_cd_fails
t volume_decimal_for_afplay
t volume_decimal_for_pw_play
t volume_cubic_for_paplay
t volume_cubic_for_mpv
t volume_linear_for_ffplay
t volume_linear_for_mpg123
t volume_wsl_passes_the_integer
t fall_fast_failure_tries_the_next_player
t fall_failure_taking_1s_is_fast
t fall_through_more_than_one_player
t fall_success_stops
t fall_timeout_124_stops
t fall_kill_137_stops
t fall_term_143_stops
t fall_slow_failure_stops
t fall_timeout_wraps_every_player
t fall_timeout_wraps_afplay

# state files (B.1 step 17)
t state_written_after_a_play
t state_not_written_when_skipped
t state_dry_run_writes_nothing
t state_debug_log_records_the_player

lib_summary
