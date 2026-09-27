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
  assert_eq wsl "$(rget os)" os
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
  hook CODESPACES=false REMOTE_CONTAINERS=1 CLAUDE_CODE_REMOTE= SSH_TTY=
  assert_calls powershell.exe "$(ps_line)"
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
  put "$SB_DATA/config" muted=1
  put "$SB_DATA/force-next" "$(ago 100) *"
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

t_force_marker_older_than_120s_is_ignored() {
  win
  put "$SB_DATA/config" muted=1
  put "$SB_DATA/force-next" "$(ago 130) *"
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
  assert_eq play "$(rget decision)" "spaced, empty arrays"
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

# --- run -------------------------------------------------------------------------------

# harness
t harness_sandbox_paths_have_spaces
t harness_path_has_no_host_programs
t harness_shim_logs_argv_and_obeys_config
t tone_is_deterministic_pcm_wav

# contract: exit 0, silence, the dry-run report, debug log, directories
t hook_idle_exits_0_quietly
t hook_bad_arguments_exit_0_quietly
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

# section 10 bullet 3: mute, volume 0, force-next
t mute_config_skips
t mute_env_skips
t mute_volume_0_skips
t force_fresh_marker_plays_while_muted
t force_fresh_marker_plays_while_env_muted
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

lib_summary
