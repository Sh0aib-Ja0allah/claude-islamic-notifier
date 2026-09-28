---
description: Play a dhikr when this reply ends, even if muted, the one you name or a random one
disable-model-invocation: true
argument-hint: "[salawat|subhanallah|alhamdulillah|la-ilaha-illallah|allahu-akbar|la-hawla]"
allowed-tools:
  - Bash(sh "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh" *)
  - PowerShell(& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" *)
  - PowerShell(& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" -Data "${CLAUDE_PLUGIN_DATA}" test)
  - PowerShell(& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" -Data "${CLAUDE_PLUGIN_DATA}" test salawat)
  - PowerShell(& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" -Data "${CLAUDE_PLUGIN_DATA}" test subhanallah)
  - PowerShell(& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" -Data "${CLAUDE_PLUGIN_DATA}" test alhamdulillah)
  - PowerShell(& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" -Data "${CLAUDE_PLUGIN_DATA}" test la-ilaha-illallah)
  - PowerShell(& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" -Data "${CLAUDE_PLUGIN_DATA}" test allahu-akbar)
  - PowerShell(& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" -Data "${CLAUDE_PLUGIN_DATA}" test la-hawla)
---

Run exactly ONE command with the shell tool you normally use, then reply with its output in one short line. Do nothing else.

- Bash tool: `sh "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh" --data "${CLAUDE_PLUGIN_DATA}" test $ARGUMENTS`
- PowerShell tool: `& "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.ps1" -Data "${CLAUDE_PLUGIN_DATA}" test $ARGUMENTS`
