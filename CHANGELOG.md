# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Added

- M1 repository skeleton: marketplace manifest, plugin manifest, and an async `Stop` hook wired to no-op stub scripts (`notify.sh`, `play.ps1`).
- Line-ending rules (`.gitattributes`) and ignore list (`.gitignore`).
- MIT licenses for the repository and the plugin folder, and stub READMEs.
- M2 POSIX playback: `notify.sh` decides (force-next, mute, pauses, remote, hand-off to `play.ps1` on Windows), then keeps a minimum gap and a lock, picks a clip and plays it on macOS, Linux and WSL; `--dry-run` prints the decision; `tools/make-test-tone.sh` writes a test tone; `tests/notify_test.sh` covers it all in POSIX sh.
- M3 Windows playback: `play.ps1 -Hook` makes the same decisions and starts a hidden, detached worker; `-Worker` takes a mutex, keeps the gap, picks a clip and plays it with MediaPlayer, falling back to SoundPlayer for WAV; `-DryRun` prints notify.sh's report; `notify.sh` uses the same `%LOCALAPPDATA%` data dir on Windows; `tests/play_test.ps1` and `tests/polyglot_test.sh` cover them.
