# islamic-notifier: implementation plan

> **Written for:** the plugin author and whoever implements the plugin (a developer or Claude Code).
> **The decisions in §0 are fixed.** Everything else is the recommended design.
> **Status:** approved plan, before implementation. **Date:** 2026-09-27. **Researched against:** Claude Code 2.1.261 and the docs current at that date.

## TL;DR

- **What it does:** when Claude finishes a reply, it plays **one random dhikr clip**. There are six adhkar, plus any clips the user adds.
- **Where it works:** Windows, macOS, Linux and WSL, in the terminal and in VS Code. **No runtime dependencies.**
- **How it works:** one **async `Stop` hook** runs a command that works in both sh and PowerShell (a "polyglot"). On macOS, Linux and WSL it runs `notify.sh`. On Windows it runs `play.ps1`, either directly or via `notify.sh` under Git Bash.
- **Install:**
  - Terminal: `/plugin marketplace add Sh0aib-Ja0allah/claude-islamic-notifier`, then `/plugin install islamic-notifier@islamic-notifier`.
  - VS Code: `/plugins`, then **Marketplaces**, then add the same repo.
- **Seven slash commands**, `/islamic-notifier:…`: `test`, `mute`, `unmute`, `volume`, `pauses`, `sounds`, `status`.
- **Settings** are stored in `~/.claude/plugins/data/<id>/config`. **Custom clips** go in `~/.claude/islamic-notifier/sounds/`.
- **Bundled audio** is six normalized 16-bit mono WAVs. Per §0, they come from freely licensed web recordings (CC0 or CC BY, stated on the clip's own page), with a labelled paid-tier TTS voice for any gap. Each clip keeps its source's license, recorded in `CREDITS.md` (§13 #4).
- **Still to decide:** §13 #3, #6 and #8–#12 (voice variants, TTS vendor and billing, masters in git, reviewers, defaults, output language, and the Git Bash fallback).

## 0. Background and fixed decisions

**Purpose (the author's words):** "notify the developers that their work is done and ready to check after every call/prompt/order. It will be an Islamic notifier."

**The six adhkar, worded exactly as the author requested:**

1. اللهم صل على سيدنا محمد
2. سبحان الله
3. الحمد لله
4. لا إله إلا الله
5. الله أكبر
6. لا حول ولا قوة إلا بالله

**Fixed decisions (author Q&A, 2026-09-27):**

| Topic | Decision |
|---|---|
| Trigger | Only when Claude finishes a reply (the `Stop` event). No sound on permission prompts, idle, or subagents. |
| Short replies | **Always play.** There is no minimum-duration threshold. |
| Background pauses | **Play by default.** Claude also "stops" while it waits for background work. A new slash command, `/islamic-notifier:pauses off|on`, lets users skip or restore these pause chimes whenever they want. |
| v1 scope | Playback, **slash commands**, and a **custom sounds folder**. Showing text and quiet hours are out of scope. |
| Audio | The author wants **licensed sources recommended** (§7). The author may also supply recordings. |
| Audio source (2026-09-28) | **Recorded voices from the web, but only freely licensed clips** (CC0 or CC BY; the clip's page must say so). Phrases with no licensed clip yet get a **temporary synthetic (paid-tier TTS) voice, labelled as such**, until a licensed recording is found. |
| Name and distribution | The plugin is `islamic-notifier`, published from a **public GitHub repo that is also its marketplace**. |

## 1. Goals and non-goals

**Goals**

- At every `Stop`, play one random clip. This must work on Windows, macOS, Linux and WSL, in both the terminal CLI and the VS Code extension.
- **Zero runtime dependencies.** Users never need Node, Python, jq or ffmpeg.
- **Never block or slow Claude.** Never print into the conversation. Never show errors.
- **Respect the adhkar.** Never overlap two clips, and never *intentionally* cut a phrase. The one best-effort exception is `claude -p` teardown (§9).
- Install from a public GitHub marketplace, from the terminal or from the VS Code extension.
- Provide seven slash commands:
  - `test`: play a clip.
  - `mute` and `unmute`.
  - `volume`: show or set the volume.
  - `pauses`: toggle the background-pause chimes.
  - `sounds`: manage the custom folder and choose bundled, custom or both.
  - `status`: diagnostics.

**Non-goals for v1**

- Other triggers: Notification, SubagentStop, StopFailure.
- A minimum turn duration. Quiet hours.
- Printing text or hadith in the terminal.
- Remote or SSH audio forwarding.
- A relocatable custom folder.

## 2. How it works

```text
User prompt → Claude works → Claude finishes responding
                                  │  Stop event. Not fired on Esc-interrupt.
                                  │  API errors fire StopFailure instead (ignored).
                                  ▼
          hooks/hooks.json: Stop → ONE async command hook (sh/PowerShell polyglot, §4.3)
           ├─ shell is sh or Git Bash (macOS, Linux, WSL, Windows with Git Bash)
           │     → hands its stdin to `notify.sh --hook`, BACKGROUNDS it, and exits at once
           │         ├─ Windows (MINGW/MSYS) → powershell.exe -File play.ps1 -Worker
           │         ├─ macOS → afplay
           │         ├─ Linux → paplay / pw-play / aplay / mpg123 / ffplay / mpv (first one available)
           │         └─ WSL   → play.ps1 -Worker via interop; if that fails, the Linux players
           └─ shell is PowerShell (Windows without Git Bash)
                 → play.ps1 -Hook: reads stdin, decides, starts a hidden detached worker, and exits
```

**The decision, in order:**

1. A **force-next** marker from `/islamic-notifier:test` exists? Then play that clip, **even if muted**.
2. `muted=1` or `volume=0`? Then skip.
3. The hook JSON has non-empty `background_tasks` or `session_crons` **and** `pauses=off`? Then skip.
4. A remote session (SSH, Codespaces, devcontainer, cloud)? Then skip.
5. Another clip is already playing, or less than 2 s have passed since the last one? Then skip. **Never interrupt a playing clip.**
6. Otherwise pick a random clip, never the same one twice in a row, and play it at the configured volume.

**Verified facts behind this design** (sources in Appendix D):

- **When `Stop` fires:**
  - It fires every time the main agent finishes responding. It does not fire when the user interrupts with Esc.
  - API errors fire `StopFailure` instead. `SubagentStop` is a separate event. `Stop` supports no matcher.
- **What the hook receives:** the JSON input includes `stop_hook_active`, `last_assistant_message`, `background_tasks` and `session_crons`. Per the docs, the last two tell a finished session apart from one that is paused waiting for background work.
- **Async hooks:**
  - `async: true` runs the hook in the background, so it cannot block Claude.
  - Claude Code does **not enforce `timeout`** on async hooks.
  - Plain stdout never reaches the user.
  - In **`claude -p` only**, async hooks still running at teardown are killed: SIGTERM, then SIGKILL after 1.5 s, or a `taskkill /T /F` tree kill on Windows.
- **Which shell runs a shell-form hook:**
  - macOS and Linux: `sh -c`. That is dash on Ubuntu and WSL, and bash 3.2 in POSIX mode on macOS.
  - Windows with Git Bash: **Git Bash**.
  - Windows without Git Bash: **PowerShell**, with pwsh 7 preferred over 5.1, run with `-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command`.
- **Why one polyglot hook instead of two:** a hook pinned to `shell:"powershell"` throws where PowerShell is missing (macOS and Linux). A hook pinned to bash throws on Windows without Git Bash.
- **How `${CLAUDE_PLUGIN_ROOT}` is substituted:**
  - Git Bash mode: forward slashes (`C:/…`).
  - PowerShell mode: rewritten to `${env:CLAUDE_PLUGIN_ROOT}`.
- **What the hook process receives:** `CLAUDE_PLUGIN_ROOT`, `CLAUDE_PLUGIN_DATA` (`~/.claude/plugins/data/<id>/`, kept across updates, deleted on uninstall from the last scope) and `CLAUDE_PROJECT_DIR`. These variables are **not** in the Bash or PowerShell *tool* environment. Skills use them through inline substitution in their Markdown body and in `allowed-tools`.
- **What users can be assumed to have:** Node and Python are not guaranteed, because the native installer doesn't use Node and Windows `python3` is a Store stub. **POSIX sh plus Windows PowerShell 5.1 is the only zero-install pair.**
- **Where hooks run:** the same way in the terminal, the IDE extensions and the Desktop app. The VS Code extension bundles its own CLI.
- **Windows shell choice in the tools:** on Windows the **PowerShell tool is usually Claude's primary shell**, even when Git Bash is installed. That matters for how the slash commands run (§4.6).

## 3. Repository layout

The repository root is the marketplace root.

```text
claude-islamic-notifier/
├── .claude-plugin/
│   └── marketplace.json               # marketplace "islamic-notifier"
├── plugins/
│   └── islamic-notifier/              # the plugin; only this folder is copied to the plugin cache
│       ├── .claude-plugin/
│       │   └── plugin.json
│       ├── hooks/
│       │   └── hooks.json
│       ├── scripts/
│       │   ├── notify.sh              # POSIX sh: hook dispatcher + players (macOS, Linux, WSL, Git Bash)
│       │   ├── play.ps1               # Windows: hook mode + worker (PS 5.1 and 7), ASCII-only
│       │   ├── ctl.sh                 # settings/test CLI used by the slash commands (POSIX)
│       │   └── ctl.ps1                # the same CLI for PowerShell
│       ├── skills/                    # slash commands → /islamic-notifier:<name>
│       │   ├── test/SKILL.md
│       │   ├── mute/SKILL.md
│       │   ├── unmute/SKILL.md
│       │   ├── volume/SKILL.md
│       │   ├── pauses/SKILL.md
│       │   ├── sounds/SKILL.md
│       │   └── status/SKILL.md
│       ├── sounds/                    # bundled clips: <id>[.<variant>].wav
│       │   ├── LICENSE                # audio license (per-file, see CREDITS.md)
│       │   └── CREDITS.md             # per file: voice, human/TTS, license, consent, processing
│       ├── data/
│       │   └── adhkar.tsv             # id ⇥ arabic ⇥ transliteration ⇥ meaning (Appendix A)
│       ├── README.md                  # short pointer to the root README
│       └── LICENSE                    # MIT (code)
├── audio/
│   └── masters/                       # raw recordings (any ffmpeg-readable format); git-ignored by default
├── docs/
│   ├── PLAN.md                        # this document
│   └── recording-guide.md             # M5: how to record the six phrases
├── tools/
│   ├── prepare-audio.sh               # dev-time ffmpeg pipeline (§7.2)
│   └── make-test-tone.sh              # generates tests/fixtures/tone.wav for development (not shipped)
├── tests/                             # polyglot, notify.sh dry-run, play.ps1 and ctl tests (§10)
├── .github/
│   └── workflows/ci.yml
├── .gitattributes                     # see below
├── .gitignore                         # audio/masters/, tests/fixtures/*.wav
├── CHANGELOG.md
├── README.md                          # the main user-facing README (outline in §11)
└── LICENSE                            # MIT
```

`.gitattributes` has one rule per line:

```text
*.sh   text eol=lf
*.ps1  text eol=crlf
*.json text eol=lf
*.tsv  text eol=lf
*.wav  binary
*.mp3  binary
```

**Plugin cache vs marketplace clone:**

- Only `plugins/islamic-notifier/` is copied into the plugin cache (`CLAUDE_PLUGIN_ROOT`).
- But `/plugin marketplace add` clones the **whole repo** into `~/.claude/plugins/marketplaces/islamic-notifier/`. So keep the repo lean: no large masters committed, no binaries.

## 4. Components

### 4.1 `.claude-plugin/marketplace.json`

```json
{
  "name": "islamic-notifier",
  "owner": { "name": "Sh0aib-Ja0allah" },
  "description": "Islamic adhkar notifier for Claude Code",
  "plugins": [
    {
      "name": "islamic-notifier",
      "source": "./plugins/islamic-notifier",
      "description": "Plays a random dhikr when Claude finishes responding",
      "category": "productivity",
      "tags": ["notification", "audio", "islamic", "adhkar"]
    }
  ]
}
```

- The marketplace name is ASCII and contains neither "claude" nor "anthropic", so it passes the reserved-name and impersonation checks.
- The entry sets no `version`, because `plugin.json` takes precedence.

### 4.2 `plugins/islamic-notifier/.claude-plugin/plugin.json`

```json
{
  "name": "islamic-notifier",
  "displayName": "Islamic Notifier (Adhkar)",
  "version": "0.1.0",
  "description": "Plays a random dhikr (SubhanAllah, Alhamdulillah, ...) when Claude finishes a task",
  "author": { "name": "Sh0aib-Ja0allah" },
  "homepage": "https://github.com/Sh0aib-Ja0allah/claude-islamic-notifier",
  "repository": "https://github.com/Sh0aib-Ja0allah/claude-islamic-notifier",
  "license": "MIT",
  "keywords": ["adhkar", "dhikr", "islamic", "notification", "sound"]
}
```

- **No `userConfig` in v1.** The slash commands manage one config file (§4.5), which gives:
  - a single source of truth;
  - no dialog when the plugin is enabled;
  - no version gates (`options` needs 2.1.271+, `/config` rows need 2.1.269+);
  - no risk from the strict schema, where an unknown key stops the plugin from loading.
- **Bump `version` for every release.** Users stay on the pinned version until it changes.

### 4.3 `hooks/hooks.json`: one async Stop hook

```json
{
  "description": "islamic-notifier: play a random dhikr when Claude finishes responding",
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "echo `# <#` >/dev/null; exec 3<&0; sh \"${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh\" --hook <&3 >/dev/null 2>&1 & exit 0 #> > $null; & \"${CLAUDE_PLUGIN_ROOT}/scripts/play.ps1\" -Hook; exit 0",
            "async": true
          }
        ]
      }
    ]
  }
}
```

**How the polyglot parses:**

- **sh, dash, bash or Git Bash:**
  - `` `# <#` `` is an empty command substitution.
  - `exec 3<&0` saves the hook's stdin. A background job's stdin would otherwise become `/dev/null`.
  - `notify.sh --hook` starts **in the background**, with the saved stdin and its output discarded.
  - `exit 0` then ends the hook shell within milliseconds. Everything after ` #>` is a comment.
- **PowerShell:**
  - `` `# `` is an escaped literal `#`, and `<# … #>` is a block comment that hides the whole sh part.
  - `play.ps1 -Hook` runs. It reads stdin, decides whether to play, starts a hidden detached worker, and returns.

**Why the hook exits at once:** in `claude -p`, only the async hook's own process tree is killed at teardown, so an orphaned `notify.sh` or worker survives.

**Rules for both script halves:**

- Every path variable stays double-quoted, so a path with spaces stays one argument. `claude plugin validate --strict` on 2.1.261 does not flag an unquoted variable, so the validator does not enforce this rule.
- Both halves end with `exit 0`.
- No `timeout` field, because it has no effect on async hooks.

**Test status:**

- An earlier form was already parse-tested (echo-only) under Git Bash, Git `sh`, Git `dash`, `bash --posix` and PowerShell 5.1, including after the `${env:}` rewrite and with a root path containing a space.
- **This exact form must pass the CI parse matrix (§10) at M3.** That matrix adds busybox ash, macOS `/bin/sh` and **pwsh 7**.
- **Fallback, decided at M3:** use the plain `sh` command and require Git for Windows on Windows.

### 4.4 Runtime scripts

Full step-by-step contracts are in Appendix B. What each script does:

| Script | Mode | Job |
|---|---|---|
| `notify.sh --hook` | Stop hook (sh/Git Bash) | Reads the hook JSON from stdin. Loads the config. Applies the decision order (§2). Takes the lock. Picks a clip. Starts the player, with the output silenced. On Windows (MINGW) it hands off to `play.ps1 -Worker`. On WSL it uses `play.ps1 -Worker -Path` via interop, then the Linux players if that fails. |
| `notify.sh --dry-run` | tests and `status` | Prints the decision path (OS, remote, pause state, pool, chosen clip, player, volume) to stdout. Plays nothing. |
| `play.ps1 -Hook` | Stop hook (PowerShell) | Reads the stdin JSON and applies decision steps 1–4. Starts `play.ps1 -Worker` hidden and detached (`Process.Start`, `CreateNoWindow`). Returns. |
| `play.ps1 -Worker [-Force id] [-Path f -Volume v]` | Windows playback | Takes the named mutex, then checks the minimum gap. Picks a clip unless `-Path` is given. Plays it with WPF MediaPlayer (pumped dispatcher, volume). Falls back to SoundPlayer for WAV. Exit codes: 0 played, 3 busy, 4 failed. |
| `ctl.sh` / `ctl.ps1` | slash commands | Reads and writes the config and markers. Prints one human-readable line per action. Runs `notify.sh --dry-run` / `play.ps1 -DryRun` for `status`. |

**Internal constants** (not user settings):

| Constant | Value | Meaning |
|---|---|---|
| `MIN_GAP` | 2 s | minimum time between two clips |
| `MAX_PLAY` | 30 s | hard cap for a hung player; custom clips should be under 20 s |
| `STALE_LOCK` | `MAX_PLAY` + 5 s | age after which a lock is considered stale |
| `FORCE_TTL` | 120 s | how long a force-next marker stays valid |

### 4.5 Config and state (`${CLAUDE_PLUGIN_DATA}`)

**`config` file format:**

- Plain `key=value` lines, **ASCII values only**.
- **UTF-8 without a BOM, LF line endings**, written atomically (temp file, then rename).
- Both readers strip a leading BOM and a trailing `\r`, so the file tolerates hand edits.
- Readers use a whitelisted parser and never `source` the file.

| key | values | default | set by |
|---|---|---|---|
| `muted` | `0` / `1` | `0` | `mute`, `unmute` |
| `volume` | `0`–`100`, linear amplitude; `0` counts as muted | `70` | `volume` |
| `pauses` | `on` / `off` (play at background-work pauses) | `on` | `pauses` |
| `sounds_mode` | `both` / `bundled` / `custom` | `both` | `sounds mode …` |

**Runtime files:**

| File | Contents |
|---|---|
| `last-play` | epoch time of the last play |
| `last-file` | the last clip played |
| `force-next` | `<epoch> <id or *>` |
| `play.lock/ts` | lock directory with an epoch timestamp (POSIX) |
| `debug.log` | only when `ISLAMIC_NOTIFIER_DEBUG=1` |

**Fixed custom folder: `~/.claude/islamic-notifier/sounds/`.** It lives outside the plugin root, which is replaced on every update. It also lives outside `CLAUDE_PLUGIN_DATA`, which is deleted on uninstall. **The folder survives both.**

**Environment overrides**, read by the hooks. Users can set them in their shell or in the `env` block of `settings.json`:

| Variable | Effect |
|---|---|
| `ISLAMIC_NOTIFIER_MUTE=1` | silences scripted `claude -p` runs |
| `ISLAMIC_NOTIFIER_FORCE_LOCAL=1` | plays even when a remote session is detected |
| `ISLAMIC_NOTIFIER_DEBUG=1` | writes `debug.log` |
| `ISLAMIC_NOTIFIER_DRY_RUN=1` | decides but plays nothing |

**Precedence:** env, then `config`, then the defaults.

**Fallback data dir** when `CLAUDE_PLUGIN_DATA` is absent (manual or dev runs only):

- POSIX: `${XDG_STATE_HOME:-~/.local/state}/islamic-notifier`
- Windows: `%LOCALAPPDATA%\islamic-notifier`

**`ctl` never falls back.** It exits with an error if `--data` is empty or still contains `${`.

### 4.6 Slash commands

Each command is `skills/<name>/SKILL.md` and is namespaced as `/islamic-notifier:<name>`.

**Frontmatter** (every `argument-hint` quoted):

```yaml
---
description: Mute islamic-notifier adhkar sounds
disable-model-invocation: true
argument-hint: ""
allowed-tools:
  - Bash(sh "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh" *)
  - PowerShell(& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" *)
  - PowerShell(& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" -Data "${CLAUDE_PLUGIN_DATA}" mute)
---
```

**Body.** The body tells Claude:

> Run exactly ONE command with the shell tool you normally use, then reply with its output in one short line. Do nothing else.
>
> - Bash tool: `sh "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh" --data "${CLAUDE_PLUGIN_DATA}" <verb> $ARGUMENTS`
> - PowerShell tool: `& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" -Data "${CLAUDE_PLUGIN_DATA}" <verb> $ARGUMENTS`

**Why both lines and both rules:**

- On Windows, PowerShell is usually Claude's primary shell. That holds even with Git Bash installed, so both lines are needed, each pre-approved by its own rules.
- On 2.1.261, a PowerShell command that starts with `&` is pre-approved only by an exact rule, so each skill also lists one exact rule per fixed form (the PowerShell line with the verb and its words filled in, such as `pauses on`), and `volume N` prompts once on the PowerShell tool. Launching through `powershell.exe -File` doesn't avoid this, because 2.1.261 always asks before starting a nested PowerShell process.
- `${CLAUDE_PLUGIN_ROOT}` is substituted in `allowed-tools`. The docs say this for Bash rules, and the 2.1.261 binary does it for the whole field.
- **"No permission prompt" is a release check (§10).**

**Why Claude runs the command, not `` !`…` `` injection:** an injected command runs in bash when bash exists and in PowerShell otherwise, so one string can't serve both shells. A failed injection also aborts the whole skill.

**Arguments** are simple tokens. `ctl` validates them and prints usage on bad input.

| Command | Behavior |
|---|---|
| `/islamic-notifier:test [id]` | Writes the `force-next` marker. When this reply finishes, the **real hook path** plays that clip (`salawat`, `subhanallah`, …) or a random one, **even if muted**. It prints which dhikr will play (Arabic, transliteration, meaning from `adhkar.tsv`). If nothing is heard, it points the user to `status`. |
| `/islamic-notifier:mute` | Sets `muted=1`. |
| `/islamic-notifier:unmute` | Sets `muted=0`. The hook at the end of this reply plays a clip, which confirms the change. |
| `/islamic-notifier:volume [0-100]` | Shows or sets the volume. A new value is confirmed audibly at the end of the reply. |
| `/islamic-notifier:pauses [on\|off]` | Shows or sets whether to play when Claude pauses for background work. **Default `on`**, per the author's decision. |
| `/islamic-notifier:sounds [list\|open\|mode both\|bundled\|custom]` | Shows the custom folder, creating it if needed. `list` shows bundled and custom clip counts and files, plus ignored files with the reason (unsupported extension, over 20 s if known). `open` opens the folder. `mode` sets the pool. |
| `/islamic-notifier:status` | Shows the diagnostics: <ul><li>plugin version, OS, hook shell path</li><li>the player `--dry-run` would pick</li><li>remote detection result</li><li>the config values and where each came from</li><li>clip counts and the last clip played</li><li>data dir writability (catches the sandbox case)</li><li>on Windows: `Get-ExecutionPolicy -List`, and whether MediaPlayer is available</li></ul> |

Because a skill invocation is a normal model turn, the `Stop` hook fires after it. `test`, `unmute` and `volume` rely on that for their audible confirmation.

**Esc edge case:** if the user presses Esc during a `test` turn, the `force-next` marker is used at the next Stop within 120 s. That is harmless.

## 5. Platform behavior matrix

| Platform | Hook shell | Player | Volume | Notes |
|---|---|---|---|---|
| macOS | `/bin/sh` (bash 3.2) | `afplay -v <0.xx> -t 30` | yes | Plays mp3 and wav. Check perceived loudness at M6. |
| Linux, PipeWire | `/bin/sh` (dash, bash) | `pw-play` | yes | Chosen when `pactl info` reports PipeWire. |
| Linux, PulseAudio (e.g. Ubuntu 22.04) | `/bin/sh` | `paplay` | yes (cubic, converted) | aplay is WAV only. mp3 needs mpg123, ffplay or mpv, or libsndfile ≥ 1.1. |
| Windows + Git Bash | Git Bash | `play.ps1 -Worker` via `powershell.exe` | yes (MediaPlayer) | SoundPlayer WAV fallback plays at full volume, and never when volume is 0. |
| Windows, PowerShell only | pwsh 7 or PS 5.1 | `play.ps1 -Hook` → hidden worker | yes | AllSigned GPO or `CLAUDE_CODE_POWERSHELL_RESPECT_EXECUTION_POLICY` → silent no-op. `status` shows it. |
| WSL2 | `/bin/sh` (dash) | `play.ps1 -Worker -Path` via interop → Linux players | yes | Interop takes 0.5–2 s. A UNC clip is copied to `%TEMP%` inside play.ps1. Best effort in v1. |
| SSH, devcontainer, Codespaces, cloud | — | skipped | — | Override with `ISLAMIC_NOTIFIER_FORCE_LOCAL=1`. |
| `claude -p` / scripts | as above | detached | — | Best effort not to cut the clip at teardown. Use `ISLAMIC_NOTIFIER_MUTE=1` for scripts. |

## 6. Audio file specification

**Bundled format:** WAV, 16-bit PCM (`pcm_s16le`), mono, 44.1 kHz. No metadata, no `WAVE_FORMAT_EXTENSIBLE` header.

- WAV is the only format that plays everywhere with no extra decoders: `afplay`, `SoundPlayer`, `aplay`, `paplay` or `pw-play` on any libsndfile, and MediaPlayer.
- Six clips of about 3 s each come to roughly 1.6 MB.

**Author's recordings (input)** go in `audio/masters/<id>.<ext>`. Any ffmpeg-readable format works: m4a from phone memos, mp3, wav or ogg. `tools/prepare-audio.sh audio/masters plugins/islamic-notifier/sounds` converts them.

**Custom clips (users):**

- Formats: `.wav` or `.mp3`, extensions case-insensitive. Other files are ignored and reported by `sounds list`.
- **Linux:** mp3 needs mpg123, ffplay, mpv, or libsndfile ≥ 1.1.
- **Length:** keep clips **under 20 s**. The 30 s cap exists only for hung players.

**Targets for every bundled clip:**

- **Length:** 1–4 s, containing the whole phrase.
- **Edges:** silence trimmed, 10–15 ms fades, about 120 ms of pre-roll so Bluetooth or HDMI outputs don't clip the first syllable.
- **Loudness:** about −16 LUFS integrated (−18 for a softer feel), true peak ≤ −1.5 dBTP, matched across all clips.

**Naming:**

- `<id>[.<variant>].wav`. The id is the part before the first dot, for example `subhanallah.wav` or `subhanallah.female.wav`.
- The ids are `salawat`, `subhanallah`, `alhamdulillah`, `la-ilaha-illallah`, `allahu-akbar` and `la-hawla`.
- Bundled names are ASCII only.

## 7. Audio sourcing and licensing

### 7.1 Rules

**Free to download does not mean licensed to redistribute.** The repo contains only audio whose explicit license allows public redistribution.

- The audio is licensed **separately from the code (MIT)**.
- `sounds/LICENSE` states "per-file license, see CREDITS.md". **CC0 or CC BY 4.0** is preferred.
- `CREDITS.md` has one row per file with these columns:
  - file
  - voice (name or "volunteer")
  - human or TTS; for TTS also the provider, voice and tier
  - **license**
  - consent or release reference
  - date
  - processing notes
- CC BY-SA files may appear only if their row says so. CC BY-NC is excluded, because non-commercial terms conflict with the permissive license chosen for the audio.

**Release gate:** v0.1.0 is not published without six licensed clips. Paid TTS clearly labelled "synthetic voice" is an acceptable interim.

### 7.2 Preparation pipeline

`tools/prepare-audio.sh` is dev-time only and needs ffmpeg (for example `winget install ffmpeg`).

1. Convert to mono 44.1 kHz and trim the silence at both ends (`silenceremove` + `areverse`).
2. Measure the loudness on a copy **padded to 3 s or more**. `loudnorm` and R128 are unreliable on clips under 3 s.
3. Apply a static gain with `alimiter`, add 15 ms fades and a 120 ms `adelay`, and write `pcm_s16le` with `-map_metadata -1`.
4. Verify with `ebur128=peak=true`: about −16 LUFS, ≤ −1.5 dBTP, 4 s or less.

**Human check (required):**

- Every syllable is intact.
- Shadda and vowels are correct.
- The *lām* of *Allāh* has the right weight:
  - **heavy** in اللَّهُمَّ, سُبْحَانَ اللَّهِ, إِلَّا اللَّهُ and اللَّهُ أَكْبَرُ;
  - **light** in لِلَّهِ and بِاللَّهِ.

The reviewer is an open item (§13). `docs/recording-guide.md` (M5) gives volunteers these steps.

### 7.3 Recommended sources, best first

§0 (2026-09-28) overrides the ranking below: freely licensed web recordings (CC0 or CC BY) come first and a labelled paid-tier TTS voice fills the gaps; the researched candidates are in `docs/audio-sources.md`.

1. **The author's own voice, or a consenting volunteer or local imam.**
   - Needs a short written release that grants CC0 or CC BY 4.0 and allows public distribution.
   - A phone voice memo in a quiet room is enough: 3–5 takes per phrase, calm and moderate pace, no reverb, no music.
2. **Paid-tier commercial TTS, as an interim or alternative pack.**
   - **Options:**
     - **Azure Neural** `ar-SA-HamedNeural` / `ar-SA-ZariyahNeural` on a **paid S0 resource**. The free F0 tier has no output-use rights. The paid-tier clause comes from Microsoft Q&A moderators, so confirm it in the Product Terms.
     - **Google Cloud TTS** `ar-XA` (WaveNet or Chirp3-HD). Check its output terms.
     - **ElevenLabs paid plans**, which include a commercial license.
     - Amazon Polly is not recommended: it has no neural MSA voice (Zeina is standard only; Hala and Zayd are Gulf).
   - **Requirements:**
     - Feed the TTS the **pausal forms** from Appendix A, for example `مُحَمَّدْ`.
     - Have a native speaker review the output.
     - Label it "synthetic voice".
   - The cost is negligible.
3. **CC stopgap clips (partial only).**
   - **Wikimedia Commons / Lingua Libre:** "Allahu Akbar" (CC0, 1.25 s) and "الحمد لله" (CC BY-SA 4.0, South Levantine). That covers 2 of 6 phrases, from different speakers.
   - **Freesound:** a CC0 "Allahu Akbar" field recording from Morocco, 11 s and not clean.
   - Open each file page to verify its license before use. **Decided (§13 #7): these are the starting point, more sources are searched for the other phrases, and each CC BY-SA clip needs the author's OK per file.**
4. **Users' own audio.**
   - Anyone may put recordings they have rights to into the custom folder, including favourite reciters for personal use.
   - The repo never redistributes these.

### 7.4 Do NOT bundle

These were checked and found unlicensed or unsafe:

- **hisnmuslim.com audio:** no license, no reciter named, and the clips are full hadith recitations, not the short phrases.
- **archive.org Hisn al-Muslim items:** the license tags are self-asserted and demonstrably wrong. One "CC0" Alafasy item says «جميع الحقوق» ("all rights reserved").
- **mp3s from other azkar apps' repos** (altaqwaa-android, Azkar-App, Islamic-tasbeh-reminder): no provenance.
- **YouTube, SoundCloud, or famous reciters** without written permission.
- **Pixabay:** its license bans "standalone" redistribution.
- **CC BY-NC clips.**
- **Unsafe TTS outputs:**
  - edge-tts (unofficial endpoint);
  - Coqui XTTS (CPML license, non-commercial);
  - Meta MMS-TTS (CC BY-NC);
  - Piper `ar_JO-kareem` (its training chain includes research-only data).
- **Never** Quran recitation or adhan as a notification. **Never** clone a known reciter's voice.

## 8. Religious and etiquette considerations

Scholars differ on using dhikr as an alert tone:

- **Stricter view:**
  - Al-Fawzan, quoted verbatim on IslamQA 128756, says «لا يجوز استعمال الأذكار … بدلاً عن المنبِّه» ("it is not permissible to use adhkar … in place of an alarm"). He calls it «من التنطّع» ("excessive") and «من الاستهانة» ("making light of the adhkar").
  - IslamQA 128756 itself concludes that a phone tone should preferably be plain: «لا تحتوي على ذكر الله» ("without dhikr of Allah"), and with no music.
  - IslamQA 105479, which is about **caller ringback tones**, is more lenient on du'a («أما الدعاء فالأمر فيه أهون», "as for du'a, the matter is lighter").
- **Other view:** an IslamOnline article citing Sheikh Ali Jum'ah forbids Quran and adhan tones but suggests hadith-based praises instead.

**What the plugin does about it.** These measures address **secondary** concerns: truncation, overlap, music and loudness. **They do not resolve the core objection.**

- It never overlaps clips and never intentionally cuts a phrase.
- It uses no music, effects, or pitch or speed changes, and no Quran or adhan.
- The default volume is moderate (70), and muting is one command.

Users who follow the stricter view can mute or uninstall. A neutral-chime mode is planned (§14). The README presents this respectfully. Who reviews that wording is an open item.

**On «سيدنا».** It is kept exactly as the author requested. The plugin plays it outside prayer, where scholars allow it:

- Ibn Baz: no harm outside prayer (binbaz.org.sa fatwa 10806; cite the full slugged URL).
- Islamweb fatwa 93239, which concerns the Ibrahimi salawat *inside prayer*, prefers leaving it out.
- Dar al-Ifta Egypt (fatwa 17990) recommends it.

**On random order.** Muslim 2137 (sunnah.com/muslim:2137a) says of the **four** phrases (tasbih, tahmid, tahlil, takbir) «لا يضرك بأيهن بدأت» ("it does not matter which of them you begin with"). The README can quote it for those four only.

## 9. Risks and mitigations

| Risk | Mitigation |
|---|---|
| The polyglot misparses in an untested shell (busybox, macOS sh, pwsh 7) | CI parse matrix at M3. If it fails, plain `sh …` and Git for Windows required on Windows. |
| Slash commands prompt for permission on Windows (PowerShell is the primary shell) | Pre-approve both `Bash(...)` and `PowerShell(...)` rules. "No prompt" is a release check on all OSes. Fallback: document a one-time "always allow". |
| CRLF checkout breaks `notify.sh` | `.gitattributes` `eol=lf`, plus a CI check. |
| BOM or CRLF in `config` (a PowerShell writer or a hand edit) | Writers use UTF-8 without BOM and LF, atomically. Readers strip the BOM and CR. Tests cover this. |
| Console window flashes on Windows (open upstream issues) | Never `Start-Process` or `-WindowStyle`. The worker starts with `CreateNoWindow`. Manual checks in the terminal and in VS Code. |
| No MediaPlayer (the legacy Windows Media Player component is missing) | SoundPlayer WAV fallback, which is why bundled clips are WAV. |
| AllSigned GPO, `CLAUDE_CODE_POWERSHELL_RESPECT_EXECUTION_POLICY`, or Constrained Language Mode | Silent no-op. `status` shows the policy. README troubleshooting covers it. |
| Several sessions stop at once | POSIX `mkdir` lock (stale lock broken atomically with `mv`) and a Windows named mutex `Local\IslamicNotifier`. Skip; never interrupt. |
| A hung player | Player chosen once (by `command -v` and extension, falling through only on a fast failure). Total cap of 30 s: `timeout -k 2 30` or `afplay -t 30`. Stale lock after 35 s. |
| `claude -p` teardown kills the async hook | The hook shell exits in about 1 ms, and the orphaned worker survives. Best effort only, and not guaranteed on the PowerShell path. `ISLAMIC_NOTIFIER_MUTE=1` for scripts. |
| Background-pause chimes feel noisy | `/islamic-notifier:pauses off`. |
| Bash sandbox blocks `ctl` from writing `CLAUDE_PLUGIN_DATA` (macOS, Linux, WSL) | `ctl` detects the failed write and prints how to fix it: add the data dir to `sandbox.filesystem.allowWrite`, or approve the unsandboxed retry. |
| Pool of one clip, or an empty pool | One clip is played as is. No clips at all is a silent no-op, and `status` says "0 clips". |
| Remote or headless machine | Remote detection skips playback. With no player, it is a silent no-op. |
| WSL UNC paths, slow interop | `play.ps1` copies UNC clips to `%TEMP%`. Exit code 4 falls back to the Linux players. Best effort. |
| Arabic mangled in PS 5.1 scripts | Scripts are ASCII-only. Arabic lives only in `adhkar.tsv`, read as UTF-8 (`Import-Csv -Encoding UTF8`, or `awk`). |
| State lost on plugin update | No state in the root: settings live in `CLAUDE_PLUGIN_DATA`, custom sounds in `~/.claude/islamic-notifier/sounds`. |
| Licensing complaint | Per-file licenses in CREDITS, only the sources recommended in §7.3, and a release gate. |

## 10. Testing and verification

**Local development:**

- **Tone fixture:** `tools/make-test-tone.sh` generates `tests/fixtures/tone.wav` so M2–M4 can play audio before the recordings exist.
- **Load the plugin:** `claude --plugin-dir ./plugins/islamic-notifier`. Then check:
  - `/hooks` lists the Stop hook under Plugin Hooks;
  - the Errors tab of `/plugin` is empty;
  - `/reload-plugins` picks up edits.
- **Validate:** run `claude plugin validate . --strict` and `claude plugin validate ./plugins/islamic-notifier --strict`. Both must pass with zero warnings.
- **Dry runs:**
  - `ISLAMIC_NOTIFIER_DRY_RUN=1 sh plugins/islamic-notifier/scripts/notify.sh --dry-run < tests/fixtures/stop-idle.json`
  - `powershell -File plugins/islamic-notifier/scripts/play.ps1 -DryRun`

**Automated tests** (`tests/` + GitHub Actions):

**Polyglot parse matrix.** Run the exact `command` string from `hooks.json` with:
- `CLAUDE_PLUGIN_ROOT` set to a path containing a space;
- stub scripts that echo a branch marker;
- stdin fed with a sample Stop JSON.

| Runner | Shells |
|---|---|
| ubuntu | `sh`, `dash`, `bash --posix` |
| alpine container | busybox `ash` |
| macOS | `/bin/sh` |
| windows | Git Bash, and `powershell.exe` / `pwsh` with Claude's exact arguments plus the `${env:}` rewrite |

Expected results:
- exactly one branch runs;
- exit code 0;
- the hook returns in under 200 ms;
- the stub receives the stdin JSON.

**`notify.sh` dry-run tests:**
- OS detection, faked with `uname` and env shims.
- Remote detection.
- mute, volume 0, force-next (and that it overrides mute).
- `pauses` on and off, with `stop-idle.json` and with `stop-background.json` (non-empty `background_tasks`).
- Lock, stale-lock break and minimum gap.
- Pool modes: an empty pool, a pool of one, no immediate repeat, case-insensitive extensions, variant names.
- Player selection and argument formats, via PATH shims. This includes the decimal volume format and the cubic conversions.
- A config file with BOM and CRLF.

**`play.ps1` tests:**
- The parser reports 0 errors.
- The file is ASCII-only.
- `-DryRun` output, the mutex-busy exit code 3, and the missing-file exit code 4.
- The BOM/CRLF config case.
- Optionally Pester.

**`ctl.sh` / `ctl.ps1` tests:**
- Every verb round-trips identically between the two scripts.
- Invalid input (a bad volume, an unknown mode) is rejected.
- `--data` values that are empty or unsubstituted are rejected.
- A read-only data dir produces the documented message.

**Lint:** `shellcheck -s sh`.

**Manual release checklist** (real audio). Test on the **floor version** (Appendix C) and on the latest Claude Code.

| Platform | Checks |
|---|---|
| Windows 11 terminal (Git Bash present) | clip plays after a reply; no console flash; volume works; **all 7 commands run with no permission prompt** |
| Windows 11 VS Code extension | install through the `/plugins` UI; same checks |
| Windows without Git Bash (VM) | PowerShell hook path plays; commands work through the PowerShell tool with no prompt |
| macOS | `afplay`; commands work; loudness at volume 70 sounds right |
| Ubuntu 22.04 (PulseAudio) | `paplay` |
| Ubuntu 24.04 (PipeWire) | `pw-play` |
| WSL2 | interop path, or the Linux fallback |
| SSH session | silent |
| Any | Two sessions finishing together play one clip, with no overlap. `test` plays exactly once. `pauses off` skips while a background subagent runs and plays when it's done. `claude -p "hi"` plays the full clip on POSIX and Git Bash; the PowerShell path is best effort. |

## 11. Distribution and README

1. **Publish the repo:** `git init`, then push to `github.com/Sh0aib-Ja0allah/claude-islamic-notifier` as a public repo.
2. **Install, terminal:**

   ```text
   /plugin marketplace add Sh0aib-Ja0allah/claude-islamic-notifier
   /plugin install islamic-notifier@islamic-notifier
   /reload-plugins
   ```

   `/plugin install` opens a panel where the user picks a scope. From the shell, the equivalents are `claude plugin marketplace add …` and `claude plugin install …`.
3. **Install, VS Code** (the extension doesn't put `claude` on PATH):
   - Type `/plugins` in the prompt box.
   - Open **Marketplaces**.
   - Add `Sh0aib-Ja0allah/claude-islamic-notifier`.
   - Install `islamic-notifier`.
   - An install link also works: `vscode://anthropic.claude-code/install-plugin?plugin=islamic-notifier&marketplace=Sh0aib-Ja0allah/claude-islamic-notifier`.
4. **Updates:**
   - **Auto-update is off by default for third-party marketplaces.** Users turn it on under `/plugin` → Marketplaces.
   - Or they update by hand: `/plugin marketplace update islamic-notifier`, then `claude plugin update islamic-notifier@islamic-notifier`.
5. **Release:**
   - Bump `version` in `plugin.json` and update `CHANGELOG.md`.
   - Tag `vX.Y.Z` and create a GitHub release.
6. **Uninstall:** `/plugin uninstall islamic-notifier@islamic-notifier`.
   - This deletes `CLAUDE_PLUGIN_DATA` (settings) **only when uninstalled from the last scope**. `--keep-data` keeps it.
   - `/plugin disable` is the gentle option that keeps settings.
   - The README gives per-OS commands to remove `~/.claude/islamic-notifier/` (custom sounds) and the fallback dirs.
7. **Later (optional):** submit to Anthropic's community plugin directory.

**README outline** (root README; the plugin README only links to it):

1. What it does (with the six adhkar and their meanings)
2. Requirements: Claude Code ≥ floor version (Appendix C); OS support
3. Install for Terminal / for VS Code
4. Commands table
5. Custom sounds: folder, formats, length, variants
6. How it decides when to play: pauses, remote, mute, `claude -p` and the env vars
7. Troubleshooting via `/islamic-notifier:status`: no sound on Linux, Windows WMP/SoundPlayer, execution policy, sandbox
8. Etiquette note (§8)
9. Audio credits and licenses
10. Uninstall and cleanup
11. Contributing recordings (points to the recording guide)
12. License

## 12. Milestones

| # | Milestone | Deliverables |
|---|---|---|
| M0 | Plan | `docs/PLAN.md` |
| M1 | Skeleton | git repo, marketplace.json, plugin.json, hooks.json (stub scripts), `.gitattributes`, `.gitignore`, LICENSEs, `CHANGELOG.md`, README stub; `validate --strict` passes |
| M2 | POSIX playback | `notify.sh` (all modes, lock, pool, players, dry-run) + tone fixture + tests |
| M3 | Windows playback | `play.ps1` (hook, worker, mutex, MediaPlayer, SoundPlayer) + **polyglot CI matrix green, or the fallback decided** |
| M4 | Slash commands | `ctl.sh`, `ctl.ps1`, the 7 skills, `adhkar.tsv`; no-prompt check |
| M5 | Audio | `docs/recording-guide.md`, recordings in `audio/masters/`, `prepare-audio.sh` → 6 WAVs + CREDITS + audio LICENSE; pronunciation review |
| M6 | CI + manual QA | GitHub Actions green; §10 checklist done on the floor version and the latest, on all platforms |
| M7 | Release v0.1.0 | release gate met (§7.1); full README; tag; announcement |

## 13. Open items for the author

Each item has a recommended default and the milestone it is needed by.

| # | Decision | Recommended default | Needed by |
|---|---|---|---|
| 1 | GitHub owner/account and `author` name | **Decided:** `Sh0aib-Ja0allah` (repo: https://github.com/Sh0aib-Ja0allah/claude-islamic-notifier) | M1 |
| 2 | Voice: yours, a volunteer or imam, or TTS placeholder | **Decided:** freely licensed web recordings (CC0 / CC BY); labelled TTS fills gaps (§0) | M5 |
| 3 | Voice gender or variants (e.g. `subhanallah.female.wav`) | one voice for v0.1 | M5 |
| 4 | Audio license | **Follows from #2:** each clip keeps its source license (per-file in `CREDITS.md`); TTS placeholders CC0 | M5 |
| 5 | Credit the voice by name, or anonymously | **Follows from #2:** credit each source as its license requires (CC BY needs name, link, license) | M5 |
| 6 | If TTS: which vendor and whose billing account | Azure S0 or Google ar-XA | M5 |
| 7 | Use the CC stopgap clips (2 of 6) | **Decided:** yes, they are the starting point; search more sources for the other 4. CC BY-SA clips need the author's OK per file | M5 |
| 8 | Commit raw masters to the repo | no (git-ignored) | M5 |
| 9 | Who checks pronunciation, and who reviews the etiquette wording | a native speaker / a trusted local scholar | M5 / M7 |
| 10 | Default volume 70, `pauses` on, `sounds_mode` both | keep | M4 |
| 11 | Language of the README and command output | English, with Arabic phrase names | M7 |
| 12 | If the polyglot fails: require Git Bash on Windows | yes (fallback) | M3 |

## 14. Future ideas (not v1)

- More triggers: `Notification` (`permission_prompt`, `idle_prompt`), `StopFailure`.
- A minimum turn duration. Quiet hours.
- A text or hadith line, in transliteration by default because the VS Code terminal breaks Arabic shaping.
- A **neutral non-dhikr chime mode** for users who follow the stricter view.
- A relocatable custom folder. Settings as `userConfig` / `/config` rows once Claude Code ≥ 2.1.271 is common.
- Voice packs as separate plugins.
- A remote bell or OSC 9 fallback via a sync hook (terminal CLI only).
- A cache of pre-scaled WAVs, so Windows can use the fast SoundPlayer at any volume.

## Appendix A: `data/adhkar.tsv` (virtues verified on sunnah.com)

The TSV columns are `id`, `arabic`, `translit` and `meaning`. The pausal form (used for TTS) and the virtue text are not TSV columns; they live in `docs/` and the README.

| id | Arabic (display) | Pausal form (TTS) | Transliteration | Meaning | Virtue (README only) |
|---|---|---|---|---|---|
| `salawat` | اللَّهُمَّ صَلِّ عَلَى سَيِّدِنَا مُحَمَّدٍ | …مُحَمَّدْ | Allāhumma ṣalli ʿalā sayyidinā Muḥammad | O Allah, send blessings upon our master Muhammad | «مَنْ صَلَّى عَلَيَّ وَاحِدَةً صَلَّى اللَّهُ عَلَيْهِ عَشْرًا» (Whoever sends blessings on me once, Allah sends blessings on him ten times). Muslim 408 |
| `subhanallah` | سُبْحَانَ اللَّهِ | سُبْحَانَ اللَّهْ | Subḥāna-llāh | Glory be to Allah | 100 tasbīḥ → 1000 good deeds, or 1000 sins removed. Muslim 2698 |
| `alhamdulillah` | الْحَمْدُ لِلَّهِ | الْحَمْدُ لِلَّهْ | Al-ḥamdu li-llāh | All praise is due to Allah | «وَالْحَمْدُ لِلَّهِ تَمْلَأُ الْمِيزَانَ» (and Alhamdulillah fills the Scale). Muslim 223 |
| `la-ilaha-illallah` | لَا إِلَهَ إِلَّا اللَّهُ | …إِلَّا اللَّهْ | Lā ilāha illa-llāh | There is no god but Allah | The best branch of faith (Muslim 35b). «أفضل الذكر» (the best dhikr), Tirmidhi 3383 (ḥasan) |
| `allahu-akbar` | اللَّهُ أَكْبَرُ | اللَّهُ أَكْبَرْ | Allāhu akbar | Allah is the Greatest | «أَحَبُّ الْكَلَامِ إِلَى اللَّهِ أَرْبَعٌ…» (The dearest words to Allah are four). Muslim 2137a (the four phrases) |
| `la-hawla` | لَا حَوْلَ وَلَا قُوَّةَ إِلَّا بِاللَّهِ | …إِلَّا بِاللَّهْ | Lā ḥawla wa lā quwwata illā bi-llāh | No might nor power except by Allah | «كَنْزٌ مِنْ كُنُوزِ الْجَنَّةِ» (a treasure from the treasures of Paradise). Bukhari 6384, Muslim 2704 |

Store each reference with its sunnah.com URL, because numbering differs between editions.

## Appendix B: Script contracts

### B.1 `notify.sh`

Contract:

- **Portability:** POSIX sh only (dash, busybox, bash 3.2).
- **Exit:** always exits 0.
- **Line endings:** LF.
- **Output:** never writes to the tty. Output goes to stdout only in `--dry-run`.

Steps:

1. **Parse arguments:** `--hook`, `--dry-run`, `--force <id|*>`. Set `LC_ALL=C`.
2. **Read input.** In `--hook` mode, and only when `[ ! -t 0 ]`, read stdin into a variable with a size bound (`head -c 262144`, falling back to `cat`). Claude closes stdin right after writing.
3. **Silence output.** Outside dry-run, silence stdout and stderr (`exec >/dev/null 2>&1`). In dry-run, print the report.
4. **Resolve directories:**
   - `ROOT`: `$CLAUDE_PLUGIN_ROOT`, or the script's parent directory.
   - `DATA`: `$CLAUDE_PLUGIN_DATA`, or the fallback from §4.5.
   - `mkdir -p` both.
5. **Load config.** Parse the whitelisted `key=value` lines, stripping the BOM and `\r`. Then apply the env overrides.
6. **force-next.** If `force-next` exists and is at most 120 s old (compared as epochs), consume it and set FORCE. FORCE bypasses mute and pauses.
7. **Mute.** Unless FORCE, exit if `muted=1` or `volume=0`.
8. **Pauses.** Unless FORCE: if `pauses=off` and the compacted JSON (`tr -d ' \t\r\n'`) contains `"background_tasks":[{` or `"session_crons":[{`, exit.
9. **Detect the OS** with `uname -s`: `Darwin` → mac; `Linux` plus `WSL_DISTRO_NAME` or "microsoft" in `/proc/version` → wsl; `MINGW*`, `MSYS*` or `CYGWIN*` → win.
10. **Remote check.** Unless `FORCE_LOCAL`, exit if any of these hold:
    - `SSH_CONNECTION`, `SSH_CLIENT` or `SSH_TTY` is set;
    - `CODESPACES=true`, `REMOTE_CONTAINERS=true` or `CLAUDE_CODE_REMOTE=true`;
    - `GITPOD_WORKSPACE_ID` is set;
    - `/.dockerenv` or `/run/.containerenv` exists.
11. **Windows.** On `win`, run `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$ROOT/scripts/play.ps1")" -Worker [-Force <id>]` in the foreground (this process is already detached), then exit. `play.ps1` owns the gap, the mutex, the pick and playback on Windows.
12. **Minimum gap.** Exit if now − `last-play` < `MIN_GAP`.
13. **Lock.**
    - Take the lock with `mkdir "$DATA/play.lock"` and write an epoch to `ts`. Set `trap 'rm -rf "$LOCK"' EXIT`.
    - If the lock exists and its `ts` is younger than `STALE_LOCK`, exit. A missing `ts` counts as fresh.
    - Otherwise break it atomically: `mv "$LOCK" "$LOCK.stale.$$" && rm -rf "$LOCK.stale.$$"`, then run `mkdir` again.
14. **Pick a clip.**
    - Build the pool from `sounds_mode`. Bundled clips come from `$ROOT/sounds`, custom clips from `~/.claude/islamic-notifier/sounds`. Match `.wav` and `.mp3` case-insensitively.
    - With FORCE and an id, filter by that id.
    - Empty pool: exit. One clip: take it. Two or more: choose among the clips other than `last-file`, drawing the random index from `od -An -N2 -tu2 /dev/urandom`. There is no loop.
15. **Choose the player once**, from `command -v` and the file extension:
    - **mac:** `afplay -v <dec> -t 30`
    - **wsl:** `powershell.exe` via interop (or `wslpath -u` of the full path). Run it from `cd /mnt/c` with `-Worker -Path "$(wslpath -w f)" -Volume v`. If the exit code is 4, or powershell.exe is missing, use the Linux players.
    - **linux, WAV:** `pw-play` if `pactl info` reports PipeWire, otherwise `paplay`. Then `aplay -q`, `ffplay`, `mpv`.
    - **linux, MP3:** `mpg123`, `ffplay`, `mpv`, then `pw-play` or `paplay`.
    - Fall through to the next player only on a fast failure (under 1 s), never on exit codes 124, 137 or 143.
16. **Volume.** Treat `v` as linear. Build the decimal as `printf '%d.%02d' $((v/100)) $((v%100))`. Convert for the cubic players with `awk`: paplay = `65536*(v/100)^(1/3)`, mpv = `100*(v/100)^(1/3)`. ffplay and mpg123 (`-f 32768*v/100`) are linear.
17. **Play.** Write `last-play` and `last-file`. Run the player under `timeout -k 2 30` where it exists, or rely on `afplay -t 30`. Remove the lock when the trap fires, then exit 0.

### B.2 `play.ps1`

Contract:

- **Compatibility:** PS 5.1 and PS 7.
- **Encoding:** **ASCII-only**.
- **Dependencies:** core cmdlets and .NET only.
- **Errors:** never throws out.

**Common setup:** `$data` = `$env:CLAUDE_PLUGIN_DATA`, or `-DataDir`, or `%LOCALAPPDATA%\islamic-notifier`. Read the config with `[IO.File]::ReadAllLines` (UTF-8), stripping the BOM and CR.

**`-Hook` mode:**

1. Read stdin with `[Console]::In.ReadToEnd()`, then `ConvertFrom-Json`, inside a try block.
2. Apply B.1 steps 6–8, using `.background_tasks.Count` and `.session_crons.Count`.
3. Start the worker hidden and detached:
   - `ProcessStartInfo` with `FileName` = the current host exe;
   - `Arguments` = `-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<this script>" -Worker [-Force id]`;
   - `UseShellExecute=$false`, `CreateNoWindow=$true`;
   - then `[Diagnostics.Process]::Start(...)`.
4. `exit 0`.

**`-Worker` mode:**

1. **Mutex:** create the named mutex `Local\IslamicNotifier` and call `WaitOne(0)`, treating `AbandonedMutexException` as acquired. If it is not acquired, exit 3.
2. **Gap and pick:** check the minimum gap, then pick a clip as in B.1 step 14 using `Get-Random`. With `-Path` (WSL), skip both.
3. **UNC clips:** if the clip path starts with `\\`, copy it to `$env:TEMP` first.
4. **MediaPlayer:**
   - Load it with `Add-Type -AssemblyName PresentationCore, WindowsBase`.
   - **Always set `Volume = v/100`**, because the default is 0.5.
   - Register scriptblock handlers for `MediaOpened`, `MediaEnded` and `MediaFailed`.
   - `Open([Uri]$path)`, then `Play()`.
   - **Pump the dispatcher:** `[Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke('Background',[Action]{})` plus a 25 ms sleep. Use a 5 s open timeout and a 30 s cap.
   - A console host is STA by default in PS 5.1 and PS 7, so no `-STA` is needed.
5. **Fallback:** if MediaPlayer fails (for example `MILAVERR_INVALIDWMPVERSION`), the file is WAV (or has a `.wav` sibling), and `volume > 0`, use `System.Media.SoundPlayer.PlaySync()`.
6. **Exit codes:** 0 played, 3 busy, 4 failed. Release the mutex in `finally`.

**`-DryRun` mode:** print the same report as `notify.sh`, plus `Get-ExecutionPolicy -List` and whether MediaPlayer is available.

### B.3 `ctl.sh` / `ctl.ps1`

Both scripts follow the same rules:

- **Arguments:** `--data <dir>` (`-Data`) is required. Exit with an error if it is empty or contains `${`.
- **Verbs:**
  - `test [id]` validates the id against `adhkar.tsv`, writes `force-next`, and prints the dhikr text.
  - `mute`, `unmute`.
  - `volume [n]`.
  - `pauses [on|off]`.
  - `sounds [list|open|mode <m>]`.
  - `status` runs the dry-run of `notify.sh` or `play.ps1` and prints the diagnostics.
- **Writes:** atomic (temp file, then rename), UTF-8 without BOM, LF. If the write fails, print: `config not writable (sandbox?) — add <dir> to sandbox.filesystem.allowWrite or approve the retry`.
- **Output:** one to eight plain-English lines.

## Appendix C: Minimum Claude Code version

**Proposed floor: 2.1.149.** Confirm it at M6.

| Version | What the plugin relies on |
|---|---|
| 2.1.72+ | async hooks receive stdin correctly |
| 2.1.75+ | async completion notices hidden by default |
| 2.1.78+ | `${CLAUDE_PLUGIN_DATA}` |
| 2.1.120+ | Windows without Git Bash runs hooks in PowerShell |
| 2.1.126+ | PowerShell is the primary shell when enabled |
| 2.1.145+ | `claude plugin validate --strict` (development only) |
| 2.1.149+ | PowerShell allow rules pre-approve scripts |
| 2.1.198+ | the `${env:}` rewrite applies to all hooks; plugin hooks had it earlier |

The plan was researched on 2.1.261.

## Appendix D: Sources

**Claude Code documentation:**

- Hooks: https://code.claude.com/docs/en/hooks. Sections: Stop, Stop input, "Run hooks in the background", "Exec form and shell form", "Command hook fields".
- Plugin manifest: https://code.claude.com/docs/en/plugins-reference. Sections: fields, userConfig, environment variables, quoting, standard layout.
- Marketplaces: https://code.claude.com/docs/en/plugins/marketplace-reference. Sections: reserved names, relative sources, strict mode.
- Skills: https://code.claude.com/docs/en/skills. Sections: frontmatter, `allowed-tools`, string substitutions, "How injected commands run".
- Also: tools-reference (PowerShell tool), sandboxing, vs-code (plugins, install URL), plugins/install (auto-update defaults), plugins/cli-reference (validate `--strict`, uninstall `--keep-data`), setup (Node not required), env-vars (`CLAUDE_CODE_REMOTE`).

**Prior art:** peon-ping (https://github.com/PeonPing/peon-ping), bells-and-whistles, claude-sounds.

**Windows audio:**

- MediaPlayer.Volume (Microsoft Learn).
- dotnet/wpf#10366: MediaPlayer fails without the legacy Windows Media Player component.
- SoundPlayer documentation.
- about_Execution_Policies (PowerShell 5.1).

**Linux audio:**

- libsndfile 1.1.0 release notes (mp3 support).
- The PulseAudio cubic volume scale.
- pw-cat, where the volume value follows the locale.
- Ubuntu 22.10 release notes (PipeWire becomes the default).

**Audio preparation:** ffmpeg `loudnorm`, and the short-clip caveat (ffmpeg-normalize #87).

**Hadith:** sunnah.com muslim:408, 2698, 223, 35b, 2137a, 2704; tirmidhi:3383; bukhari:6384.

**Fatwas:** IslamQA 128756 and 105479; binbaz.org.sa 10806 (use the full slugged URL); islamweb 93239; dar-alifta 17990.

