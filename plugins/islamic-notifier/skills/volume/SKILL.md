---
description: Show or set the islamic-notifier volume, from 0 to 100
disable-model-invocation: true
argument-hint: "[0-100]"
allowed-tools:
  - Bash(sh "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh" *)
  - PowerShell(& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" *)
  - PowerShell(& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" -Data "${CLAUDE_PLUGIN_DATA}" volume)
---

Run exactly ONE command with the shell tool you normally use, then reply with its output in one short line. Do nothing else.

- Bash tool: `sh "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh" --data "${CLAUDE_PLUGIN_DATA}" volume $ARGUMENTS`
- PowerShell tool: `& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" -Data "${CLAUDE_PLUGIN_DATA}" volume $ARGUMENTS`
