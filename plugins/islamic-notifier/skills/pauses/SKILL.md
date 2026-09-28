---
description: Show or set whether a dhikr plays when Claude pauses to wait for background work
disable-model-invocation: true
argument-hint: "[on|off]"
allowed-tools:
  - Bash(sh "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh" *)
  - PowerShell(& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" *)
  - PowerShell(& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" -Data "${CLAUDE_PLUGIN_DATA}" pauses)
  - PowerShell(& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" -Data "${CLAUDE_PLUGIN_DATA}" pauses on)
  - PowerShell(& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" -Data "${CLAUDE_PLUGIN_DATA}" pauses off)
---

Run exactly ONE command with the shell tool you normally use, then reply with its output in one short line. Do nothing else.

- Bash tool: `sh "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh" --data "${CLAUDE_PLUGIN_DATA}" pauses $ARGUMENTS`
- PowerShell tool: `& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" -Data "${CLAUDE_PLUGIN_DATA}" pauses $ARGUMENTS`
