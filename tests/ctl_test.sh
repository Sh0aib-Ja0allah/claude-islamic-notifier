#!/bin/sh
# Tests for plugins/islamic-notifier/scripts/ctl.sh (docs/PLAN.md, section 10 and Appendix
# B.3) and data/adhkar.tsv. POSIX sh, no framework, on tests/lib.sh's sandbox, shims and
# asserts. Prints "pass=N fail=M skip=K" and exits non-zero if any test fails; each failure
# is explained on stderr, and each skip (a capability this host lacks) on stdout.
#
# Usage, from the repo root:
#   sh tests/ctl_test.sh
#   TEST_SHELL=dash dash tests/ctl_test.sh    ctl.sh (and the notify.sh it runs) run as
#                                             "$TEST_SHELL ctl.sh"
#
# Each test gets a plugin root of its own in the sandbox, with copies of ctl.sh, notify.sh,
# data/adhkar.tsv and plugin.json, so bundled clips are the test's. ctl.sh runs under env -i
# with HOME in the sandbox and the sandbox PATH; "sh" on that PATH is TEST_SHELL. No test
# opens a window or plays audio: open, xdg-open, explorer.exe, powershell.exe, cygpath and
# wslpath are shims. Parity with ctl.ps1 runs in tests/ctl_test.ps1, where sh and PowerShell
# both exist (Windows).

unset CDPATH
case $0 in
  */*) TESTS=${0%/*} ;;
  *) TESTS=. ;;
esac
TESTS=$(cd "$TESTS" && pwd) || exit 2
REPO=${TESTS%/*}
PLUGIN=$REPO/plugins/islamic-notifier
FIXTURES=$TESTS/fixtures
# lib.sh's nrun runs this; ctl.sh runs it itself, from the sandbox copy.
NOTIFY=$PLUGIN/scripts/notify.sh
export NOTIFY

# For shellcheck -x, run from the repo root.
# shellcheck source=tests/lib.sh
. "$TESTS/lib.sh"
TOOLBOX_TOOLS="$TOOLBOX_TOOLS wc"
lib_init
# ctl.sh runs notify.sh as "sh notify.sh": here that sh is the shell under test.
printf '#!/bin/sh\nexec '\''%s'\'' "$@"\n' "$TEST_SHELL_PATH" > "$TOOLBOX/sh"
chmod +x "$TOOLBOX/sh"

MSG_TAIL='to sandbox.filesystem.allowWrite or approve the retry'

# setup_root: the sandbox plugin root, once per test.
setup_root() {
  [ -f "$SB_ROOT/scripts/ctl.sh" ] && return 0
  mkdir -p "$SB_ROOT/scripts" "$SB_ROOT/data" "$SB_ROOT/.claude-plugin"
  cp "$PLUGIN/scripts/ctl.sh" "$PLUGIN/scripts/notify.sh" "$SB_ROOT/scripts/"
  cp "$PLUGIN/data/adhkar.tsv" "$SB_ROOT/data/"
  cp "$PLUGIN/.claude-plugin/plugin.json" "$SB_ROOT/.claude-plugin/"
}

# The helpers below use cr_ names, so a test's own variables survive them.

# craw [NAME=value ...] [ARG ...]: ctl.sh in the sandbox, from $SB, with no --data added.
# The leading NAME=value words go into its environment, the rest are its arguments. stdout is
# in $SB/out, stderr in $SB/err, the exit status in RC.
craw() {
  setup_root
  cd "$SB" || fail "cannot cd to $SB"
  cr_edit "$TEST_SHELL_PATH" "$SB_ROOT/scripts/ctl.sh" "$@"
}

# crun [NAME=value ...] ARG ...: craw with --data "$SB_DATA" before the ARGs.
crun() {
  setup_root
  cd "$SB" || fail "cannot cd to $SB"
  cr_edit "$TEST_SHELL_PATH" "$SB_ROOT/scripts/ctl.sh" --data "$SB_DATA" "$@"
}

# cr_edit SHELL SCRIPT [OPT ...] [NAME=value ...] [ARG ...]: move the NAME=value words that
# follow the options in front of SHELL, then run it all under env -i.
cr_edit() {
  cr_n=$#
  cr_head=2
  [ "${3:-}" != --data ] || cr_head=4
  cr_k=0
  cr_i=0
  for cr_a in "$@"; do
    cr_i=$((cr_i + 1))
    [ "$cr_i" -gt "$cr_head" ] || continue
    case $cr_a in [A-Za-z_]*=*) cr_k=$((cr_k + 1)) ;; *) break ;; esac
  done
  # The env words, then SHELL SCRIPT and the options, then the other arguments.
  cr_i=0
  for cr_a in "$@"; do
    cr_i=$((cr_i + 1))
    if [ "$cr_i" -gt "$cr_head" ] && [ "$cr_i" -le $((cr_head + cr_k)) ]; then
      set -- "$@" "$cr_a"
    fi
  done
  cr_i=0
  for cr_a in "$@"; do
    cr_i=$((cr_i + 1))
    [ "$cr_i" -le "$cr_n" ] || break
    if [ "$cr_i" -le "$cr_head" ] || [ "$cr_i" -gt $((cr_head + cr_k)) ]; then
      set -- "$@" "$cr_a"
    fi
  done
  shift "$cr_n"
  env -i "HOME=$SB_HOME" "PATH=$SB_PATH" "ISLAMIC_NOTIFIER_TEST_SYSROOT=$SB_SYS" \
    "$@" > "$SB/out" 2> "$SB/err" < /dev/null
  RC=$?
}

out() { cat "$SB/out"; }
err() { cat "$SB/err"; }

# ok: exit 0, stderr empty, 1 to 8 lines on stdout.
ok() {
  [ "$RC" = 0 ] || fail "ctl.sh exited $RC: $(err)"
  [ ! -s "$SB/err" ] || fail "ctl.sh wrote to stderr: $(err)"
  lines=$(awk 'END { print NR }' "$SB/out")
  if [ "$lines" -lt 1 ] || [ "$lines" -gt 8 ]; then fail "$lines lines of output: $(out)"; fi
}

# ascii: stdout is printable ASCII.
ascii() {
  if LC_ALL=C awk '/[^ -~]/ { bad = 1 } END { exit !bad }' "$SB/out"; then
    fail "non-ASCII output: $(out)"
  fi
}

# rejected WHY: exit 2, nothing on stdout, WHY and the usage line on stderr.
rejected() {
  [ "$RC" = 2 ] || fail "exit $RC, not 2, for: $1"
  [ ! -s "$SB/out" ] || fail "stdout for a rejected call: $(out)"
  case $(err) in
    *"$1"*'usage: ctl.sh --data <dir>'*) ;;
    *) fail "stderr for a rejected call: $(err)" ;;
  esac
}

# snap: every file and dir under the sandbox's data dir and home, with checksums.
snap() {
  find "$SB_DATA" "$SB_HOME" -type d 2>/dev/null | sort
  find "$SB_DATA" "$SB_HOME" -type f -exec cksum {} + 2>/dev/null | sort
}

# bytes FILE: the file as od -c prints it, to compare bytes.
bytes() { od -An -c "$1" | tr -s ' \n' '  '; }

# wav FILE RATE DATA: a WAV header whose byte rate (offset 28) is RATE, then DATA zero bytes.
wav() {
  le4() {
    printf '\\0%03o\\0%03o\\0%03o\\0%03o' $(($1 % 256)) $(($1 / 256 % 256)) \
      $(($1 / 65536 % 256)) $(($1 / 16777216 % 256))
  }
  mkdir -p "${1%/*}"
  printf '%b' "RIFF$(le4 $((36 + $3)))WAVEfmt $(le4 16)\\0001\\0000\\0001\\0000$(le4 8000)$(le4 "$2")\\0001\\0000\\0010\\0000data$(le4 "$3")" > "$1"
  head -c "$3" /dev/zero >> "$1"
}

# tsv_field ID N: field N of ID's row in the TSV.
tsv_field() { awk -F '\t' -v id="$1" -v n="$2" '$1 == id { print $n }' "$PLUGIN/data/adhkar.tsv"; }

# win: fake Git Bash, as notify_test.sh does, with cygpath and powershell.exe shims.
win() {
  shim_out uname MINGW64_NT-10.0-26200
  shim_path cygpath
}

# ps_report [KEY=VALUE ...]: what the powershell.exe shim prints: play.ps1's report.
ps_report() {
  shim_write powershell.exe <<'EOF'
case " $* " in
  *' -DryRun '*) cat "$sb/cfg/ps.report" ;;
esac
EOF
  {
    printf '%s\n' report=1 os=win "root=C:\\root" "data=C:\\data" input=none force=none \
      muted=0 volume=70 pauses=on sounds_mode=both remote=none force_local=0 gap=ok \
      lock=free pool=2 clip=C:\\x.wav player=MediaPlayer fallback=SoundPlayer \
      player_volume=0.70 decision=play \
      'execution_policy=MachinePolicy:Undefined,UserPolicy:Undefined,Process:Bypass,CurrentUser:RemoteSigned,LocalMachine:Undefined' \
      media_player=yes
    for kv in "$@"; do printf '%s\r\n' "$kv"; done
  } > "$SB/cfg/ps.report.tmp"
  # Later KEY=VALUE lines replace the earlier ones; lines end CRLF, as powershell.exe's do.
  awk -F '=' '{ sub(/\r$/, ""); k = $1; v[k] = $0; if (!(k in seen)) { seen[k] = 1; order[++n] = k } }
    END { for (i = 1; i <= n; i++) printf "%s\r\n", v[order[i]] }' \
    "$SB/cfg/ps.report.tmp" > "$SB/cfg/ps.report"
}

# --- the TSV (Appendix A) -----------------------------------------------------------------

# appendix_a: docs/PLAN.md's Appendix A section.
appendix_a() { awk '/^## Appendix A/ { on = 1 } /^## Appendix B/ { on = 0 } on' "$REPO/docs/PLAN.md"; }

t_tsv_rows_fields_and_ids() {
  f=$PLUGIN/data/adhkar.tsv
  assert_eq 7 "$(awk 'END { print NR }' "$f")" lines
  assert_eq '4 4 4 4 4 4 4' "$(awk -F '\t' '{ printf "%s%s", sep, NF; sep = " " }' "$f")" fields
  assert_eq "$(printf 'id\tarabic\ttranslit\tmeaning')" "$(awk 'NR == 1' "$f")" header
  want=$(appendix_a | awk -F '`' '/^\| `[a-z-]+` \|/ { printf "%s%s", sep, $2; sep = " " }')
  assert_eq 'salawat subhanallah alhamdulillah la-ilaha-illallah allahu-akbar la-hawla' "$want" \
    "Appendix A ids"
  assert_eq "$want" "$(awk -F '\t' 'NR > 1 { printf "%s%s", sep, $1; sep = " " }' "$f")" ids
}

t_tsv_is_utf8_lf_no_bom_final_newline() {
  f=$PLUGIN/data/adhkar.tsv
  assert_eq 'id' "$(head -c 2 "$f")" 'first bytes (no BOM)'
  [ "$(tr -d '\r' < "$f" | wc -c)" = "$(wc -c < "$f")" ] || fail 'the TSV has a CR'
  assert_eq '\n' "$(tail -c 1 "$f" | od -An -c | tr -d ' ')" 'last byte'
}

# Each cell is Appendix A's, byte for byte: id, Arabic (display), transliteration, meaning.
t_tsv_cells_match_appendix_a() {
  awk -F '\t' 'NR > 1 { print $1 "\t" $2 "\t" $3 "\t" $4 }' "$PLUGIN/data/adhkar.tsv" > "$SB/tsv"
  appendix_a | awk -F '|' '/^\| `[a-z-]+` \|/ {
      for (i = 2; i <= 6; i++) { v = $i; gsub(/^ +| +$/, "", v); gsub(/`/, "", v); f[i] = v }
      print f[2] "\t" f[3] "\t" f[5] "\t" f[6]
    }' > "$SB/plan"
  cmp -s "$SB/tsv" "$SB/plan" || fail "TSV rows differ from Appendix A: $(diff "$SB/plan" "$SB/tsv")"
}

# --- the skills (section 4.6) ---------------------------------------------------------------

# Seven skills, one verb each, with section 4.6's frontmatter and body, by text: the two
# allowed-tools lines and the body's first line as PLAN.md has them, and both body lines with
# the skill's own verb. ASCII. CRs are dropped before matching: git has no eol rule for .md,
# so a Windows checkout (core.autocrlf=true) has CRLF skills.
t_skills_match_section_4_6() {
  skills=$PLUGIN/skills
  assert_eq 'mute pauses sounds status test unmute volume' \
    "$(cd "$skills" && for d in */; do printf '%s ' "${d%/}"; done | sed 's/ $//')" 'skill dirs'
  plan=$REPO/docs/PLAN.md
  bash_rule=$(grep -F -- '  - Bash(sh "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh" *)' "$plan")
  ps_rule=$(grep -F -- '  - PowerShell(& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" *)' "$plan")
  intro=$(grep -F 'Run exactly ONE command with the shell tool you normally use' "$plan")
  intro=${intro#> }
  bash_line=$(grep -F -- '- Bash tool: `sh "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh"' "$plan")
  bash_line=${bash_line#> }
  ps_line=$(grep -F -- '- PowerShell tool: `& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1"' "$plan")
  ps_line=${ps_line#> }
  for l in "$bash_rule" "$ps_rule" "$intro" "$bash_line" "$ps_line"; do
    [ -n "$l" ] || fail 'section 4.6 lines not found in PLAN.md'
  done
  for verb in mute pauses sounds status test unmute volume; do
    [ -f "$skills/$verb/SKILL.md" ] || fail "no $skills/$verb/SKILL.md"
    f=$SB/$verb.md
    tr -d '\r' < "$skills/$verb/SKILL.md" > "$f"
    if LC_ALL=C awk '/[^ -~]/ { bad = 1 } END { exit !bad }' "$f"; then fail "$verb: not ASCII"; fi
    assert_eq '---' "$(awk 'NR == 1' "$f")" "$verb: first line"
    assert_eq 2 "$(grep -c '^---$' "$f")" "$verb: frontmatter fences"
    grep -q '^description: [^ ]' "$f" || fail "$verb: no description"
    grep -q '^description: .*: ' "$f" && fail "$verb: a colon in the description"
    grep -qx 'disable-model-invocation: true' "$f" || fail "$verb: disable-model-invocation"
    grep -q '^argument-hint: "[^"]*"$' "$f" || fail "$verb: argument-hint not quoted"
    grep -qx 'allowed-tools:' "$f" || fail "$verb: allowed-tools"
    grep -qxF -- "$bash_rule" "$f" || fail "$verb: the Bash rule"
    grep -qxF -- "$ps_rule" "$f" || fail "$verb: the PowerShell rule"
    grep -qxF -- "$intro" "$f" || fail "$verb: the body's first line"
    grep -qxF -- "$(printf '%s\n' "$bash_line" | sed "s/<verb>/$verb/")" "$f" || fail "$verb: the Bash line"
    grep -qxF -- "$(printf '%s\n' "$ps_line" | sed "s/<verb>/$verb/")" "$f" || fail "$verb: the PowerShell line"
  done
}

# --- config writes --------------------------------------------------------------------------

t_write_creates_the_data_dir_and_config() {
  rmdir "$SB_DATA"
  crun volume 40
  ok
  assert_content "$SB_DATA/config" 'volume=40'
  assert_eq 'config' "$(ls -A "$SB_DATA")" 'data dir files'
}

t_write_replaces_first_drops_later_keeps_others() {
  put "$SB_DATA/config" 'colour=blue' 'volume=10' '' '# volume=5' 'volume=20' 'volume =30' 'muted=1'
  crun volume 40
  ok
  assert_eq 'colour=blue
volume=40

# volume=5
volume =30
muted=1' "$(cat "$SB_DATA/config")" config
  assert_eq 'config' "$(ls -A "$SB_DATA")" 'data dir files'
}

t_write_appends_a_missing_key() {
  put "$SB_DATA/config" 'volume=10'
  crun pauses off
  ok
  assert_eq 'volume=10
pauses=off' "$(cat "$SB_DATA/config")" config
}

t_write_bom_and_crlf_in_clean_out() {
  printf '\357\273\277muted=1\r\nfoo=bar\r\nvolume=5\r\npauses=off\r' > "$SB_DATA/config"
  crun unmute
  ok
  assert_eq ' m u t e d = 0 \n f o o = b a r \n v o l u m e = 5 \n p a u s e s = o f f \n ' \
    "$(bytes "$SB_DATA/config")" 'config bytes'
}

t_write_bom_line_key_is_matched() {
  printf '\357\273\277volume=5\n' > "$SB_DATA/config"
  crun volume 6
  ok
  assert_eq ' v o l u m e = 6 \n ' "$(bytes "$SB_DATA/config")" 'config bytes'
}

t_write_no_final_newline() {
  printf 'pauses=on' > "$SB_DATA/config"
  crun pauses off
  ok
  assert_eq ' p a u s e s = o f f \n ' "$(bytes "$SB_DATA/config")" 'config bytes'
}

t_write_each_verb_sets_its_key() {
  for c in 'mute:muted=1' 'unmute:muted=0' 'volume 0:volume=0' 'volume 100:volume=100' \
    'volume 7:volume=7' 'pauses off:pauses=off' 'pauses on:pauses=on' \
    'sounds mode bundled:sounds_mode=bundled' 'sounds mode custom:sounds_mode=custom' \
    'sounds mode both:sounds_mode=both'; do
    rm -f "$SB_DATA/config"
    # Unquoted on purpose: the verb and its value are two words.
    # shellcheck disable=SC2086
    crun ${c%%:*}
    ok
    assert_content "$SB_DATA/config" "${c#*:}"
  done
}

t_show_verbs_write_nothing() {
  before=$(snap)
  for v in volume pauses status 'sounds list'; do
    # Unquoted on purpose: sounds list is two words.
    # shellcheck disable=SC2086
    crun $v
    ok
  done
  # status makes the data dir exist (it already does) and removes its probe.
  assert_eq "$before" "$(snap)" 'sandbox files'
}

# --- reading config, the way notify.sh does -----------------------------------------------

t_read_defaults_config_and_env() {
  crun volume
  ok
  assert_eq 'Volume: 70 (default), on a scale of 0 to 100.' "$(out)" volume
  put "$SB_DATA/config" 'volume=abc' 'volume=045' 'volume=150' 'pauses=maybe' 'pauses=off'
  crun volume
  assert_eq 'Volume: 45 (config), on a scale of 0 to 100.' "$(out)" 'volume, last valid'
  crun pauses
  assert_eq 'Pauses: off (config): no clip when Claude stops to wait for background work.' \
    "$(out)" pauses
  put "$SB_DATA/config" 'muted=0'
  crun ISLAMIC_NOTIFIER_MUTE=1 status
  ok
  case $(out) in
    *'Settings: muted 1 (env), volume 70 (default), pauses on (default), sounds_mode both (default).'*) ;;
    *) fail "status: $(out)" ;;
  esac
}

t_mute_and_unmute_messages() {
  crun mute
  ok
  ascii
  assert_eq 'Muted: no clip plays until /islamic-notifier:unmute (/islamic-notifier:test still plays one).' \
    "$(out)" mute
  crun ISLAMIC_NOTIFIER_MUTE=0 mute
  ok
  assert_eq 'Muted: no clip plays until /islamic-notifier:unmute (/islamic-notifier:test still plays one).
Note: ISLAMIC_NOTIFIER_MUTE=0 in the environment overrides this.' "$(out)" 'mute, env'
  crun unmute
  assert_eq 'Unmuted: a clip plays when this reply ends.' "$(out)" unmute
  crun volume 0
  assert_eq 'Volume set to 0: nothing plays until you raise it.' "$(out)" 'volume 0'
  crun unmute
  assert_eq 'Unmuted, but the volume is 0, so nothing plays; raise it with /islamic-notifier:volume.' \
    "$(out)" 'unmute at volume 0'
  crun mute
  crun volume 30
  assert_eq 'Volume set to 30; sounds are muted, so run /islamic-notifier:unmute to hear it.' \
    "$(out)" 'volume while muted'
}

# --- rejection: exit 2, usage, no file changed ---------------------------------------------

t_reject_bad_values_and_verbs() {
  put "$SB_DATA/config" 'volume=10'
  before=$(snap)
  for c in 'volume 101' 'volume -1' 'volume 070' 'volume abc' 'volume 1.5' 'volume +5' \
    'volume 5 6' 'pauses maybe' 'pauses on off' 'sounds mode all' 'sounds mode' 'sounds bogus' \
    'sounds list x' 'sounds open x' 'mute x' 'unmute x' 'status x' 'frob' 'test bogus' \
    'test salawat subhanallah' 'test SALAWAT'; do
    # Unquoted on purpose: each case is a verb and its words.
    # shellcheck disable=SC2086
    crun $c
    rejected ''
  done
  crun volume ''
  rejected 'volume must be a whole number from 0 to 100'
  crun test bogus
  rejected 'unknown id: bogus (ids: salawat, subhanallah, alhamdulillah, la-ilaha-illallah, allahu-akbar, la-hawla)'
  crun frob
  rejected 'unknown verb: frob'
  assert_eq "$before" "$(snap)" 'sandbox files'
}

t_reject_bad_data() {
  before=$(snap)
  craw --data '' volume 5
  rejected '--data is empty'
  # Single quotes on purpose: the ${ is the point, an unsubstituted variable.
  # shellcheck disable=SC2016
  craw --data '${CLAUDE_PLUGIN_DATA}' volume 5
  rejected '--data still holds ${: ${CLAUDE_PLUGIN_DATA}'
  craw --data "$SB/x\${y}" volume 5
  rejected '--data still holds ${'
  craw volume 5
  rejected '--data is required'
  craw --data
  rejected '--data needs a directory'
  craw --data "$SB_DATA"
  rejected 'no verb'
  assert_eq "$before" "$(snap)" 'sandbox files'
}

# --- write failures: exit 1 and how to allow the write -----------------------------------

t_write_fails_when_data_is_a_file() {
  : > "$SB/a file"
  for c in 'mute' 'volume 5' 'pauses off' 'sounds mode custom' 'test' 'test salawat'; do
    # Unquoted on purpose: a verb and its words.
    # shellcheck disable=SC2086
    craw --data "$SB/a file" $c
    [ "$RC" = 1 ] || fail "exit $RC for $c"
    [ ! -s "$SB/out" ] || fail "stdout for $c: $(out)"
    assert_eq "config not writable (sandbox?) - add $SB/a file $MSG_TAIL" "$(err)" "stderr for $c"
    [ ! -s "$SB/a file" ] || fail "the file was written for $c"
  done
}

t_write_fails_in_a_read_only_dir() {
  put "$SB_DATA/config" 'volume=10'
  chmod a-w "$SB_DATA"
  # true, not ":": a failed redirection on a special built-in exits dash and bash --posix.
  if true 2>/dev/null > "$SB_DATA/probe"; then
    rm -f "$SB_DATA/probe"
    chmod u+w "$SB_DATA"
    skip 'the harness can still write to a chmod a-w dir here (root, or Windows, where ctl_test.ps1 tests an icacls deny)'
  fi
  crun volume 40
  rc=$RC
  err2=$(err)
  crun status
  rc3=$RC
  status=$(out)
  crun test
  rc2=$RC
  chmod u+w "$SB_DATA"
  assert_eq '1 1 0' "$rc $rc2 $rc3" 'exit codes'
  assert_eq "config not writable (sandbox?) - add $SB_DATA $MSG_TAIL" "$err2" stderr
  case $status in
    *"Data dir: $SB_DATA, not writable (sandbox?) - add $SB_DATA $MSG_TAIL."*) ;;
    *) fail "status in a read-only dir: $status" ;;
  esac
  assert_content "$SB_DATA/config" 'volume=10'
  assert_eq 'config' "$(ls -A "$SB_DATA")" 'data dir files'
  crun status
  ok
  case $(out) in
    *"Data dir: $SB_DATA, writable."*) ;;
    *) fail "status after chmod u+w: $(out)" ;;
  esac
}

# A config that cannot be read is not rewritten, which would lose its other lines.
t_write_refuses_an_unreadable_config() {
  put "$SB_DATA/config" 'volume=10' 'foo=bar'
  chmod a-r "$SB_DATA/config"
  if cat "$SB_DATA/config" > /dev/null 2>&1; then
    chmod u+r "$SB_DATA/config"
    skip 'the harness can still read a chmod a-r file here (root, or Windows, where ctl_test.ps1 tests an icacls deny)'
  fi
  crun volume 40
  chmod u+r "$SB_DATA/config"
  [ "$RC" = 1 ] || fail "exit $RC"
  assert_eq "config not writable (sandbox?) - add $SB_DATA $MSG_TAIL" "$(err)" stderr
  assert_eq 'volume=10
foo=bar' "$(cat "$SB_DATA/config")" config
}

t_status_says_when_the_data_dir_is_not_writable() {
  : > "$SB/a file"
  craw --data "$SB/a file" status
  ok
  case $(out) in
    *"Data dir: $SB/a file, not writable (sandbox?) - add $SB/a file $MSG_TAIL."*) ;;
    *) fail "status: $(out)" ;;
  esac
}

# --- test -------------------------------------------------------------------------------

t_test_writes_force_next_and_prints_the_dhikr() {
  clip bundled salawat.wav
  before=$(date +%s)
  crun test salawat
  after=$(date +%s)
  ok
  read -r ts id < "$SB_DATA/force-next"
  assert_eq salawat "$id" 'force-next id'
  if [ "$ts" -lt "$before" ] || [ "$ts" -gt "$after" ]; then fail "epoch $ts not in $before..$after"; fi
  assert_eq "$ts salawat" "$(cat "$SB_DATA/force-next")" 'force-next line'
  [ "$(wc -l < "$SB_DATA/force-next")" -eq 1 ] || fail 'force-next is not one LF line'
  assert_eq "Next: $(tsv_field salawat 2)
$(tsv_field salawat 3) - $(tsv_field salawat 4)
It plays when this reply ends, even if muted.
If you hear nothing, run /islamic-notifier:status." "$(out)" output
  assert_eq 'force-next' "$(ls -A "$SB_DATA")" 'data dir files'
}

t_test_without_an_id_is_any_clip() {
  clip custom alhamdulillah.mp3
  put "$SB_DATA/force-next" '1 subhanallah'
  crun test
  ok
  ascii
  case $(cat "$SB_DATA/force-next") in
    *' *') ;;
    *) fail "force-next: $(cat "$SB_DATA/force-next")" ;;
  esac
  assert_eq 'Next: a random dhikr.
It plays when this reply ends, even if muted.
If you hear nothing, run /islamic-notifier:status.' "$(out)" output
}

t_test_says_when_there_is_no_clip() {
  clip bundled subhanallah.wav
  crun test salawat
  ok
  assert_eq "No clip for salawat yet: add salawat.wav or salawat.mp3 to $SB_CUSTOM" \
    "$(awk 'NR == 3' "$SB/out")" 'no clip for the id'
  rm "$SB_BUNDLED/subhanallah.wav"
  crun test
  ok
  assert_eq "Next: a random dhikr.
No clip found: add .wav or .mp3 clips to $SB_CUSTOM
If you hear nothing, run /islamic-notifier:status." "$(out)" 'no clip at all'
}

# The dry run it reads leaves the marker for the hook.
t_test_every_id_and_the_marker_stays() {
  for id in salawat subhanallah alhamdulillah la-ilaha-illallah allahu-akbar la-hawla; do
    clip custom "$id.wav"
    crun test "$id"
    ok
    assert_eq "Next: $(tsv_field "$id" 2)" "$(awk 'NR == 1' "$SB/out")" "Arabic for $id"
    case $(cat "$SB_DATA/force-next") in
      *" $id") ;;
      *) fail "force-next for $id: $(cat "$SB_DATA/force-next")" ;;
    esac
  done
}

t_test_on_windows_reads_play_ps1s_pool() {
  win
  ps_report pool=0
  crun test salawat
  ok
  case $(calls powershell.exe) in
    *'|-File|C:'*'\scripts\play.ps1|-DryRun|-Force|salawat') ;;
    *) fail "powershell.exe calls: $(calls powershell.exe)" ;;
  esac
  assert_eq "No clip for salawat yet: add salawat.wav or salawat.mp3 to $(winpath "$SB_CUSTOM")" \
    "$(awk 'NR == 3' "$SB/out")" 'pool from play.ps1'
}

# --- status -----------------------------------------------------------------------------

t_status_lines() {
  clip bundled a.wav
  clip bundled b.MP3
  clip bundled notes.txt
  clip custom c.wav
  put "$SB_DATA/config" 'volume=40' 'sounds_mode=custom'
  put "$SB_DATA/last-file" "$SB_CUSTOM/c.wav"
  shim afplay
  shim_out uname Darwin
  crun status
  ok
  ascii
  assert_eq "islamic-notifier 0.1.0 on mac; hooks run in /bin/sh.
Next reply end: play; player afplay at volume 0.40; remote session: none.
Settings: muted 0 (default), volume 40 (config), pauses on (default), sounds_mode custom (config).
Clips: 2 bundled, 1 custom; last played: $SB_CUSTOM/c.wav.
Data dir: $SB_DATA, writable." "$(out)" status
}

t_status_remote_and_no_player() {
  crun SSH_TTY=/dev/pts/0 status
  ok
  assert_eq 'Next reply end: skip-remote; player none at volume none; remote session: ssh.' \
    "$(awk 'NR == 2' "$SB/out")" 'line 2'
  assert_eq 'Clips: 0 bundled, 0 custom; last played: none.' "$(awk 'NR == 4' "$SB/out")" 'line 4'
}

t_status_creates_a_missing_data_dir_and_leaves_no_probe() {
  rmdir "$SB_DATA"
  crun status
  ok
  [ -d "$SB_DATA" ] || fail 'no data dir'
  assert_eq '' "$(ls -A "$SB_DATA")" 'data dir files'
}

t_status_on_windows() {
  win
  ps_report
  crun status
  ok
  assert_eq "islamic-notifier 0.1.0 on win; hooks run in Git Bash.
Next reply end: play; player MediaPlayer at volume 0.70; remote session: none.
Settings: muted 0 (default), volume 70 (default), pauses on (default), sounds_mode both (default).
Clips: 0 bundled, 0 custom; last played: none.
Data dir: $(winpath "$SB_DATA"), writable.
Windows: execution policy MachinePolicy:Undefined,UserPolicy:Undefined,Process:Bypass,CurrentUser:RemoteSigned,LocalMachine:Undefined; MediaPlayer yes." \
    "$(out)" status
  case $(calls powershell.exe) in
    *'|-File|C:'*'\scripts\play.ps1|-DryRun') ;;
    *) fail "powershell.exe calls: $(calls powershell.exe)" ;;
  esac
}

# --- sounds -------------------------------------------------------------------------------

t_sounds_shows_and_creates_the_folder() {
  crun sounds
  ok
  ascii
  [ -d "$SB_CUSTOM" ] || fail 'no custom folder'
  assert_eq "Custom sounds folder: $SB_CUSTOM
Mode: both (default), bundled and custom clips. Add .wav or .mp3 clips under 20 s; /islamic-notifier:sounds list shows them." \
    "$(out)" output
}

t_sounds_folder_that_cannot_be_made() {
  mkdir -p "$SB_HOME/.claude"
  : > "$SB_HOME/.claude/islamic-notifier"
  crun sounds
  [ "$RC" = 1 ] || fail "exit $RC"
  assert_eq "could not create $SB_CUSTOM (sandbox?) - add it $MSG_TAIL" "$(err)" stderr
}

t_sounds_list() {
  clip bundled subhanallah.wav
  clip bundled alhamdulillah.WAV
  clip bundled readme.txt
  clip custom la-hawla.Mp3
  clip custom .hidden.wav
  clip custom song.ogg
  mkdir -p "$SB_CUSTOM/dir.wav"
  wav "$SB_CUSTOM/long.wav" 1000 20001
  wav "$SB_CUSTOM/twenty.wav" 1000 20000
  crun sounds list
  ok
  ascii
  assert_eq "Bundled (2): alhamdulillah.WAV, subhanallah.wav
Custom (3): la-hawla.Mp3, long.wav, twenty.wav
Ignored (2): readme.txt (unsupported extension), song.ogg (unsupported extension)
Over 20 s, still played but cut at 30 s (1): long.wav
Mode: both (default), bundled and custom clips; custom folder: $SB_CUSTOM" "$(out)" output
  [ ! -e "$SB_HOME/.claude/islamic-notifier/sounds/probe" ] || fail 'list wrote'
}

t_sounds_list_empty_does_not_create_the_folder() {
  crun sounds list
  ok
  assert_eq "Bundled (0): none
Custom (0): none
Mode: both (default), bundled and custom clips; custom folder: $SB_CUSTOM" "$(out)" output
  [ ! -e "$SB_CUSTOM" ] || fail 'list created the custom folder'
}

t_sounds_mode() {
  crun sounds mode custom
  ok
  assert_eq 'Sounds mode set to custom: custom clips only.' "$(out)" output
  assert_content "$SB_DATA/config" 'sounds_mode=custom'
}

t_sounds_open_per_os() {
  shim open
  shim xdg-open
  shim explorer.exe
  shim_path wslpath
  crun sounds open
  ok
  assert_calls xdg-open "xdg-open|$SB_CUSTOM"
  assert_eq "Opened $SB_CUSTOM" "$(out)" 'linux output'
  shim_out uname Darwin
  crun sounds open
  assert_calls open "open|$SB_CUSTOM"
  shim_out uname Linux
  crun WSL_DISTRO_NAME=Ubuntu sounds open
  assert_calls explorer.exe "explorer.exe|$(winpath "$SB_CUSTOM")"
  win
  rm -f "$SB/log/explorer.exe"
  crun sounds open
  assert_calls explorer.exe "explorer.exe|$(winpath "$SB_CUSTOM")"
  assert_eq "Opened $(winpath "$SB_CUSTOM")" "$(out)" 'win output'
  [ -d "$SB_CUSTOM" ] || fail 'open did not create the folder'
}

t_sounds_open_without_an_opener() {
  crun sounds open
  ok
  assert_eq "Cannot open folders here; the custom sounds folder is $SB_CUSTOM" "$(out)" output
}

# --- Windows paths ----------------------------------------------------------------------

# Fake Git Bash: a C:\ --data is turned into a POSIX path with cygpath -u.
t_windows_data_path_through_cygpath() {
  win
  printf '%s\n' "$SB_DATA" > "$SB/cfg/cygpath.u"
  craw --data 'C:\Users\me\.claude\plugins\data\islamic-notifier' volume 40
  ok
  assert_content "$SB_DATA/config" 'volume=40'
}

# Real Git Bash: Claude's Bash tool may pass C:\... or C:/... for the script and for --data.
t_windows_paths_in_real_git_bash() {
  case $(uname -s) in
    MINGW*|MSYS*|CYGWIN*) command -v cygpath > /dev/null 2>&1 || skip 'no cygpath' ;;
    *) skip 'not Git Bash, MSYS2 or Cygwin' ;;
  esac
  setup_root
  # From the sandbox: a path ctl.sh failed to convert would land under the cwd.
  cd "$SB" || fail "cannot cd to $SB"
  script_w=$(cygpath -w "$SB_ROOT/scripts/ctl.sh")
  script_m=$(cygpath -m "$SB_ROOT/scripts/ctl.sh")
  HOME=$SB_HOME "$TEST_SHELL_PATH" "$script_w" --data "$(cygpath -w "$SB_DATA")" volume 40 \
    > "$SB/out" 2> "$SB/err"
  RC=$?
  ok
  assert_content "$SB_DATA/config" 'volume=40'
  HOME=$SB_HOME "$TEST_SHELL_PATH" "$script_m" --data "$(cygpath -m "$SB_DATA")" pauses off \
    > "$SB/out" 2> "$SB/err"
  RC=$?
  ok
  assert_eq 'volume=40
pauses=off' "$(cat "$SB_DATA/config")" config
}

# --- run ------------------------------------------------------------------------------------

t tsv_rows_fields_and_ids
t tsv_is_utf8_lf_no_bom_final_newline
t tsv_cells_match_appendix_a
t skills_match_section_4_6
t write_creates_the_data_dir_and_config
t write_replaces_first_drops_later_keeps_others
t write_appends_a_missing_key
t write_bom_and_crlf_in_clean_out
t write_bom_line_key_is_matched
t write_no_final_newline
t write_each_verb_sets_its_key
t show_verbs_write_nothing
t read_defaults_config_and_env
t mute_and_unmute_messages
t reject_bad_values_and_verbs
t reject_bad_data
t write_fails_when_data_is_a_file
t write_fails_in_a_read_only_dir
t write_refuses_an_unreadable_config
t status_says_when_the_data_dir_is_not_writable
t test_writes_force_next_and_prints_the_dhikr
t test_without_an_id_is_any_clip
t test_says_when_there_is_no_clip
t test_every_id_and_the_marker_stays
t test_on_windows_reads_play_ps1s_pool
t status_lines
t status_remote_and_no_player
t status_creates_a_missing_data_dir_and_leaves_no_probe
t status_on_windows
t sounds_shows_and_creates_the_folder
t sounds_folder_that_cannot_be_made
t sounds_list
t sounds_list_empty_does_not_create_the_folder
t sounds_mode
t sounds_open_per_os
t sounds_open_without_an_opener
t windows_data_path_through_cygpath
t windows_paths_in_real_git_bash

printf 'note parity with ctl.ps1 runs in tests/ctl_test.ps1, where sh and PowerShell both exist\n'
lib_summary
