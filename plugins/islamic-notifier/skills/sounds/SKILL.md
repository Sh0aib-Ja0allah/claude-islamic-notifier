---
description: Show, list or open your custom adhkar sounds folder, or choose bundled, custom or both clips
disable-model-invocation: true
argument-hint: "[list|open|mode both|bundled|custom]"
allowed-tools:
  - Bash(sh "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh" *)
  - PowerShell(& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" *)
  - PowerShell(& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" -Data "${CLAUDE_PLUGIN_DATA}" sounds)
  - PowerShell(& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" -Data "${CLAUDE_PLUGIN_DATA}" sounds list)
  - PowerShell(& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" -Data "${CLAUDE_PLUGIN_DATA}" sounds open)
  - PowerShell(& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" -Data "${CLAUDE_PLUGIN_DATA}" sounds mode both)
  - PowerShell(& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" -Data "${CLAUDE_PLUGIN_DATA}" sounds mode bundled)
  - PowerShell(& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" -Data "${CLAUDE_PLUGIN_DATA}" sounds mode custom)
---

Run exactly ONE command with the shell tool you normally use, then reply with its output in one short line. Do nothing else.

- Bash tool: `sh "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh" --data "${CLAUDE_PLUGIN_DATA}" sounds $ARGUMENTS`
- PowerShell tool: `& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" -Data "${CLAUDE_PLUGIN_DATA}" sounds $ARGUMENTS`
