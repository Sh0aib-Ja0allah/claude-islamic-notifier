# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Added

- M1 repository skeleton: marketplace manifest, plugin manifest, and an async `Stop` hook wired to no-op stub scripts (`notify.sh`, `play.ps1`).
- Line-ending rules (`.gitattributes`) and ignore list (`.gitignore`).
- MIT licenses for the repository and the plugin folder, and stub READMEs.
- M2 POSIX playback: `notify.sh` decides (force-next, mute, pauses, remote, hand-off to `play.ps1` on Windows), then keeps a minimum gap and a lock, picks a clip and plays it on macOS, Linux and WSL; `--dry-run` prints the decision; `tools/make-test-tone.sh` writes a test tone; `tests/notify_test.sh` covers it all in POSIX sh.
