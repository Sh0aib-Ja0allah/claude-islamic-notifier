---
description: Unmute islamic-notifier adhkar sounds; a dhikr plays when this reply ends
disable-model-invocation: true
argument-hint: ""
allowed-tools:
  - Bash(sh "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh" *)
  - PowerShell(& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" *)
---

Run exactly ONE command with the shell tool you normally use, then reply with its output in one short line. Do nothing else.

- Bash tool: `sh "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh" --data "${CLAUDE_PLUGIN_DATA}" unmute $ARGUMENTS`
- PowerShell tool: `& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" -Data "${CLAUDE_PLUGIN_DATA}" unmute $ARGUMENTS`
