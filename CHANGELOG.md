# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Added

- M1 repository skeleton: marketplace manifest, plugin manifest, and an async `Stop` hook wired to no-op stub scripts (`notify.sh`, `play.ps1`).
- Line-ending rules (`.gitattributes`) and ignore list (`.gitignore`).
- MIT licenses for the repository and the plugin folder, and stub READMEs.
- M2 POSIX playback: `notify.sh` decides (force-next, mute, pauses, remote, hand-off to `play.ps1` on Windows), then keeps a minimum gap and a lock, picks a clip and plays it on macOS, Linux and WSL; `--dry-run` prints the decision; `tools/make-test-tone.sh` writes a test tone; `tests/notify_test.sh` covers it all in POSIX sh.
- M3 Windows playback: `play.ps1 -Hook` makes the same decisions and starts a hidden, detached worker; `-Worker` takes a mutex, keeps the gap, picks a clip and plays it with MediaPlayer, falling back to SoundPlayer for WAV; `-DryRun` prints notify.sh's report; `notify.sh` uses the same `%LOCALAPPDATA%` data dir on Windows; `tests/play_test.ps1` and `tests/polyglot_test.sh` cover them.
- M3 CI: `.github/workflows/ci.yml` runs shellcheck, the `notify.sh` suite under sh, dash, `bash --posix`, busybox ash, macOS `/bin/sh` and Git Bash, `tests/play_test.ps1` under Windows PowerShell 5.1 and pwsh 7, the polyglot parse matrix with the legs each runner must run, and `tests/crlf_check.sh` on every runner; every harness prints pass, fail and skip counts, with a reason for each skip.
- M4 slash commands: `/islamic-notifier:test`, `mute`, `unmute`, `volume`, `pauses`, `sounds` and `status`, run by `ctl.sh` (Bash tool) or `ctl.ps1` (PowerShell tool), which write the config atomically and print one to eight plain-English lines; `data/adhkar.tsv` holds the six adhkar; the skills pre-approve their commands, so none prompts except `volume N` on the PowerShell tool (Claude Code 2.1.261 admits only exact rules there); `tests/ctl_test.sh` and `tests/ctl_test.ps1` (parity between the two scripts) run on every CI runner.
