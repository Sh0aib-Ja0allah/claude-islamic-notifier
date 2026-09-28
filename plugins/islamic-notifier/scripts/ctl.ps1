# islamic-notifier: the settings and test CLI behind the slash commands, for PowerShell
# (docs/PLAN.md, Appendix B.3 and section 4.6). Windows PowerShell 5.1 and PowerShell 7, core
# cmdlets and .NET only. ASCII only: PS 5.1 reads a script without a BOM as ANSI. ctl.sh is
# the same CLI for sh: both write byte-identical config and force-next files and print the
# same lines. Outside Windows it runs ctl.sh.
#
# Usage: ctl.ps1 -Data <dir> <verb> [arg ...]
#   test [id] | mute | unmute | volume [0-100] | pauses [on|off] |
#   sounds [list | open | mode both|bundled|custom] | status
# See ctl.sh for what each verb does. -Data is ${CLAUDE_PLUGIN_DATA} as Claude substituted
# it: an empty -Data, or one still holding "${", is bad usage. Arguments PowerShell reads as
# numbers (volume 070) reach this script as those numbers (70).
#
# Output: one to eight lines on stdout, written as UTF-8 without a BOM, so the TSV's Arabic
# survives any console code page. Exit: 0 done; 2 bad usage (stderr: why, then the usage
# line; no file changed); 1 a write that failed (stderr: how to allow it).
#
# Files are read and written as bytes (Latin-1 maps each byte to one char), so every line
# the write keeps is kept byte for byte, as in ctl.sh.

# No positional binding: "ctl.ps1 status" must not bind status to -Data.
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Data,
    [Parameter(ValueFromRemainingArguments = $true)][object[]]$Words
)

$ErrorActionPreference = 'Stop'
$Usage = 'usage: ctl.ps1 -Data <dir> {test [id] | mute | unmute | volume [0-100] | pauses [on|off] | sounds [list | open | mode both|bundled|custom] | status}'
$Latin1 = [Text.Encoding]::GetEncoding(28591)
$Utf8 = New-Object Text.UTF8Encoding $false
$script:out = New-Object System.Collections.Generic.List[string]

function Write-Bytes([IO.Stream]$stream, [string]$text) {
    $b = $Utf8.GetBytes($text)
    $stream.Write($b, 0, $b.Length)
    $stream.Flush()
}

# Leave with CODE after writing the collected lines (stdout) and ERR (stderr).
function Stop-Ctl([int]$code, [string]$err) {
    if ($script:out.Count -gt 0) {
        Write-Bytes ([Console]::OpenStandardOutput()) ((($script:out) -join "`n") + "`n")
    }
    if ($err) { Write-Bytes ([Console]::OpenStandardError()) $err }
    exit $code
}

function Say([string[]]$lines) { foreach ($l in $lines) { $script:out.Add($l) } }

function Stop-Usage([string]$why) {
    $script:out.Clear()
    $e = ''
    if ($why) { $e = "ctl.ps1: $why`n" }
    Stop-Ctl 2 ($e + $Usage + "`n")
}

# Outside Windows, the sh CLI does the work.
$OnWindows = $PSVersionTable.PSEdition -ne 'Core' -or $IsWindows
if (-not $OnWindows) {
    $sh = Join-Path $PSScriptRoot 'ctl.sh'
    $w = @($Words | ForEach-Object { "$_" })
    if ($PSBoundParameters.ContainsKey('Data')) {
        & sh $sh --data $Data @w
    } else {
        & sh $sh @w
    }
    exit $LASTEXITCODE
}

$Root = Split-Path -Parent $PSScriptRoot
$Tsv = Join-Path $Root 'data\adhkar.tsv'
$Play = Join-Path $PSScriptRoot 'play.ps1'

# ---- Arguments
if (-not $PSBoundParameters.ContainsKey('Data')) { Stop-Usage '-Data is required' }
if (-not $Data) { Stop-Usage '-Data is empty: ${CLAUDE_PLUGIN_DATA} was not substituted' }
if ($Data.Contains('${')) { Stop-Usage "-Data still holds `${: $Data" }
$Words = @($Words | Where-Object { $null -ne $_ } | ForEach-Object { "$_" })
if ($Words.Count -eq 0) { Stop-Usage 'no verb' }
$Verb = $Words[0]
$Rest = @()
if ($Words.Count -gt 1) { $Rest = $Words[1..($Words.Count - 1)] }
$DataDir = [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).ProviderPath, $Data))
$Custom = Join-Path "$env:USERPROFILE" '.claude\islamic-notifier\sounds'
$ConfigFile = Join-Path $DataDir 'config'

# ---- Config, read the way notify.sh and play.ps1 read it: whitelisted keys, the last valid
# line wins, then ISLAMIC_NOTIFIER_MUTE. Each value's source is kept.

# The config's lines: the BOM and each line's trailing CR stripped, as ctl.sh reads them.
# $null if it exists but cannot be read.
function Read-ConfigLines {
    $lines = New-Object System.Collections.Generic.List[string]
    if (-not [IO.File]::Exists($ConfigFile)) { return ,$lines }
    try {
        $text = $Latin1.GetString([IO.File]::ReadAllBytes($ConfigFile))
    } catch {
        return $null
    }
    $bom = "$([char]0xEF)$([char]0xBB)$([char]0xBF)"
    if ($text.StartsWith($bom, [StringComparison]::Ordinal)) { $text = $text.Substring(3) }
    if ($text.Length -eq 0) { return ,$lines }
    $parts = $text.Split([char]10)
    $n = $parts.Count
    if ($text.EndsWith("`n", [StringComparison]::Ordinal)) { $n-- }
    for ($i = 0; $i -lt $n; $i++) {
        $l = $parts[$i]
        if ($l.EndsWith("`r", [StringComparison]::Ordinal)) { $l = $l.Substring(0, $l.Length - 1) }
        $lines.Add($l)
    }
    return ,$lines
}

$S = @{ muted = '0'; volume = '70'; pauses = 'on'; mode = 'both' }
$Src = @{ muted = 'default'; volume = 'default'; pauses = 'default'; mode = 'default' }
foreach ($line in (Read-ConfigLines)) {
    $eq = $line.IndexOf('=')
    if ($eq -lt 0) { continue }
    $key = $line.Substring(0, $eq)
    $val = $line.Substring($eq + 1)
    switch -CaseSensitive ($key) {
        'muted' { if ($val -ceq '0' -or $val -ceq '1') { $S.muted = $val; $Src.muted = 'config' } }
        'volume' {
            if ($val -cmatch '^[0-9]+\z') {
                while ($val.Length -gt 1 -and $val.StartsWith('0', [StringComparison]::Ordinal)) { $val = $val.Substring(1) }
                if ($val.Length -le 3 -and [int]$val -le 100) { $S.volume = $val; $Src.volume = 'config' }
            }
        }
        'pauses' { if ($val -ceq 'on' -or $val -ceq 'off') { $S.pauses = $val; $Src.pauses = 'config' } }
        'sounds_mode' { if ($val -cin 'both', 'bundled', 'custom') { $S.mode = $val; $Src.mode = 'config' } }
    }
}
if ($env:ISLAMIC_NOTIFIER_MUTE -ceq '0' -or $env:ISLAMIC_NOTIFIER_MUTE -ceq '1') {
    $S.muted = $env:ISLAMIC_NOTIFIER_MUTE
    $Src.muted = 'env'
}

# ---- Writes

function Stop-NotWritable {
    $script:out.Clear()
    Stop-Ctl 1 "config not writable (sandbox?) - add $DataDir to sandbox.filesystem.allowWrite or approve the retry`n"
}

# Write TEXT to a temp file in the data dir, then rename it over NAME.
function Write-DataFile([string]$name, [string]$text) {
    $tmp = Join-Path $DataDir ".$name.$PID.tmp"
    $target = Join-Path $DataDir $name
    try {
        $null = [IO.Directory]::CreateDirectory($DataDir)
        [IO.File]::WriteAllBytes($tmp, $Latin1.GetBytes($text))
        if ([IO.File]::Exists($target)) {
            [IO.File]::Replace($tmp, $target, [NullString]::Value)
        } else {
            [IO.File]::Move($tmp, $target)
        }
    } catch {
        try { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } } catch { }
        Stop-NotWritable
    }
}

function Set-Key([string]$key, [string]$value) {
    # A config that cannot be read is not rewritten: its other lines would be lost.
    $old = Read-ConfigLines
    if ($null -eq $old) { Stop-NotWritable }
    $new = New-Object System.Collections.Generic.List[string]
    $found = $false
    foreach ($l in $old) {
        if ($l.StartsWith("$key=", [StringComparison]::Ordinal)) {
            if ($found) { continue }
            $found = $true
            $l = "$key=$value"
        }
        $new.Add($l)
    }
    if (-not $found) { $new.Add("$key=$value") }
    Write-DataFile 'config' ((($new) -join "`n") + "`n")
}

# ---- The dry-run report: play.ps1 -DryRun, run here with this data dir and plugin root.

function Get-Report([string]$forceId) {
    # play.ps1 runs as it runs from a hook, not with this script's Stop.
    $ErrorActionPreference = 'Continue'
    $saveData = $env:CLAUDE_PLUGIN_DATA
    $saveRoot = $env:CLAUDE_PLUGIN_ROOT
    $env:CLAUDE_PLUGIN_DATA = $DataDir
    $env:CLAUDE_PLUGIN_ROOT = $Root
    $lines = @()
    try {
        if ($forceId) {
            $lines = @(& $Play -DryRun -Force $forceId 2>$null)
        } else {
            $lines = @(& $Play -DryRun 2>$null)
        }
    } catch {
    } finally {
        $env:CLAUDE_PLUGIN_DATA = $saveData
        $env:CLAUDE_PLUGIN_ROOT = $saveRoot
    }
    $r = @{}
    foreach ($l in $lines) {
        $s = "$l"
        $i = $s.IndexOf('=')
        if ($i -gt 0 -and -not $r.ContainsKey($s.Substring(0, $i))) { $r[$s.Substring(0, $i)] = $s.Substring($i + 1) }
    }
    $r
}

function Get-R($report, [string]$key) {
    if ($report.ContainsKey($key)) { return $report[$key] }
    '<unknown>'
}

# ---- Clips: the pool rule of notify.sh and play.ps1, dir by dir

# What is in DIR: the clips, the files the player skips, and WAVs over 20 s.
function Get-Scan([string]$dir) {
    $r = @{ N = 0; Names = @(); Ign = @(); Long = @() }
    if (-not [IO.Directory]::Exists($dir)) { return $r }
    $files = [IO.Directory]::GetFiles($dir)
    [Array]::Sort($files, [StringComparer]::Ordinal)
    foreach ($f in $files) {
        $n = [IO.Path]::GetFileName($f)
        if ($n.StartsWith('.', [StringComparison]::Ordinal)) { continue }
        if ($n -match '\.(wav|mp3)\z') {
            $r.N++
            $r.Names += $n
            if ($n -match '\.wav\z' -and (Test-WavOver20 $f)) { $r.Long += $n }
        } else {
            $r.Ign += "$n (unsupported extension)"
        }
    }
    $r
}

# True if the WAV's data runs over 20 s: (size - 44) / the byte rate at offset 28.
function Test-WavOver20([string]$file) {
    try {
        $fs = [IO.File]::OpenRead($file)
        try {
            $size = $fs.Length
            if ($size -lt 32) { return $false }
            $b = New-Object byte[] 4
            $null = $fs.Seek(28, 'Begin')
            if ($fs.Read($b, 0, 4) -ne 4) { return $false }
        } finally {
            $fs.Dispose()
        }
        $rate = [long]$b[0] + 256L * $b[1] + 65536L * $b[2] + 16777216L * $b[3]
        if ($rate -le 0) { return $false }
        return ($size - 44) -gt (20 * $rate)
    } catch {
        return $false
    }
}

function Join-Names($list) {
    if (@($list).Count -eq 0) { return 'none' }
    @($list) -join ', '
}

# ---- Verbs

function Add-MuteNote {
    if ($env:ISLAMIC_NOTIFIER_MUTE -ceq '0' -or $env:ISLAMIC_NOTIFIER_MUTE -ceq '1') {
        Say "Note: ISLAMIC_NOTIFIER_MUTE=$($env:ISLAMIC_NOTIFIER_MUTE) in the environment overrides this."
    }
}

function Get-PausesText([string]$v) {
    if ($v -ceq 'on') { return 'a clip plays when Claude stops to wait for background work' }
    'no clip when Claude stops to wait for background work'
}

function Get-ModeText([string]$m) {
    switch -CaseSensitive ($m) {
        'both' { 'bundled and custom clips' }
        'bundled' { 'bundled clips only' }
        'custom' { 'custom clips only' }
    }
}

function Invoke-Mute {
    if ($Rest.Count -ne 0) { Stop-Usage 'mute takes no argument' }
    Set-Key 'muted' '1'
    Say 'Muted: no clip plays until /islamic-notifier:unmute (/islamic-notifier:test still plays one).'
    Add-MuteNote
}

function Invoke-Unmute {
    if ($Rest.Count -ne 0) { Stop-Usage 'unmute takes no argument' }
    Set-Key 'muted' '0'
    if ($S.volume -ceq '0') {
        Say 'Unmuted, but the volume is 0, so nothing plays; raise it with /islamic-notifier:volume.'
    } else {
        Say 'Unmuted: a clip plays when this reply ends.'
    }
    Add-MuteNote
}

function Invoke-Volume {
    if ($Rest.Count -gt 1) { Stop-Usage 'volume takes at most one value' }
    if ($Rest.Count -eq 0) {
        Say "Volume: $($S.volume) ($($Src.volume)), on a scale of 0 to 100."
        return
    }
    $v = $Rest[0]
    if ($v -cnotmatch '^(0|[1-9][0-9]?|100)\z') { Stop-Usage "volume must be a whole number from 0 to 100, not: $v" }
    Set-Key 'volume' $v
    if ($v -ceq '0') {
        Say 'Volume set to 0: nothing plays until you raise it.'
    } elseif ($S.muted -ceq '1') {
        Say "Volume set to $v; sounds are muted, so run /islamic-notifier:unmute to hear it."
    } else {
        Say "Volume set to $v; a clip plays at this volume when this reply ends."
    }
}

function Invoke-Pauses {
    if ($Rest.Count -gt 1) { Stop-Usage 'pauses takes at most one value' }
    if ($Rest.Count -eq 0) {
        Say "Pauses: $($S.pauses) ($($Src.pauses)): $(Get-PausesText $S.pauses)."
        return
    }
    $v = $Rest[0]
    if ($v -cne 'on' -and $v -cne 'off') { Stop-Usage "pauses must be on or off, not: $v" }
    Set-Key 'pauses' $v
    Say "Pauses set to ${v}: $(Get-PausesText $v)."
}

function New-Custom {
    if ([IO.Directory]::Exists($Custom)) { return }
    try {
        $null = [IO.Directory]::CreateDirectory($Custom)
    } catch {
        $script:out.Clear()
        Stop-Ctl 1 "could not create $Custom (sandbox?) - add it to sandbox.filesystem.allowWrite or approve the retry`n"
    }
}

function Invoke-Sounds {
    $sub = ''
    if ($Rest.Count -gt 0) { $sub = $Rest[0] }
    switch -CaseSensitive ($sub) {
        '' {
            New-Custom
            Say "Custom sounds folder: $Custom", "Mode: $($S.mode) ($($Src.mode)), $(Get-ModeText $S.mode). Add .wav or .mp3 clips under 20 s; /islamic-notifier:sounds list shows them."
        }
        'list' {
            if ($Rest.Count -ne 1) { Stop-Usage 'sounds list takes no argument' }
            $b = Get-Scan (Join-Path $Root 'sounds')
            $c = Get-Scan $Custom
            Say "Bundled ($($b.N)): $(Join-Names $b.Names)", "Custom ($($c.N)): $(Join-Names $c.Names)"
            $ign = @($b.Ign) + @($c.Ign)
            $long = @($b.Long) + @($c.Long)
            if ($ign.Count -gt 0) { Say "Ignored ($($ign.Count)): $($ign -join ', ')" }
            if ($long.Count -gt 0) { Say "Over 20 s, still played but cut at 30 s ($($long.Count)): $($long -join ', ')" }
            Say "Mode: $($S.mode) ($($Src.mode)), $(Get-ModeText $S.mode); custom folder: $Custom"
        }
        'open' {
            if ($Rest.Count -ne 1) { Stop-Usage 'sounds open takes no argument' }
            New-Custom
            $opener = Get-Command explorer.exe -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($opener) {
                # explorer.exe exits 1 even when it opened the folder, so no status is trusted.
                try { $null = & explorer.exe $Custom 2>$null } catch { }
                Say "Opened $Custom"
            } else {
                Say "Cannot open folders here; the custom sounds folder is $Custom"
            }
        }
        'mode' {
            if ($Rest.Count -ne 2) { Stop-Usage 'sounds mode takes one of both, bundled, custom' }
            $m = $Rest[1]
            if ($m -cnotin 'both', 'bundled', 'custom') { Stop-Usage "sounds mode must be both, bundled or custom, not: $m" }
            Set-Key 'sounds_mode' $m
            Say "Sounds mode set to ${m}: $(Get-ModeText $m)."
        }
        default { Stop-Usage "unknown sounds argument: $sub" }
    }
}

# The TSV row for ID (arabic, translit, meaning), read as UTF-8, or $null.
function Get-Dhikr([string]$id) {
    try {
        $rows = [IO.File]::ReadAllText($Tsv, $Utf8).Split([char]10)
    } catch {
        return $null
    }
    for ($i = 1; $i -lt $rows.Count; $i++) {
        $f = $rows[$i].Split([char]9)
        if ($f.Count -ge 4 -and $f[0] -ceq $id) { return ,$f }
    }
    $null
}

function Get-Ids {
    try {
        $rows = [IO.File]::ReadAllText($Tsv, $Utf8).Split([char]10)
    } catch {
        return ''
    }
    @(for ($i = 1; $i -lt $rows.Count; $i++) {
            $f = $rows[$i].Split([char]9)
            if ($f[0]) { $f[0] }
        }) -join ', '
}

function Invoke-Test {
    if ($Rest.Count -gt 1) { Stop-Usage 'test takes at most one id' }
    $id = '*'
    $row = $null
    if ($Rest.Count -eq 1) {
        $row = Get-Dhikr $Rest[0]
        if (-not $row) { Stop-Usage "unknown id: $($Rest[0]) (ids: $(Get-Ids))" }
        $id = $Rest[0]
    }
    Write-DataFile 'force-next' ("$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) $id`n")
    $pool = Get-R (Get-Report $id) 'pool'
    if ($row) {
        Say "Next: $($row[1])", "$($row[2]) - $($row[3])"
    } else {
        Say 'Next: a random dhikr.'
    }
    if ($pool -ceq '0') {
        if ($id -ceq '*') {
            Say "No clip found: add .wav or .mp3 clips to $Custom"
        } else {
            Say "No clip for $id yet: add $id.wav or $id.mp3 to $Custom"
        }
    } else {
        Say 'It plays when this reply ends, even if muted.'
    }
    Say 'If you hear nothing, run /islamic-notifier:status.'
}

# Where Claude Code runs hooks on Windows: Git Bash if it finds one, else PowerShell.
function Get-HookShell {
    $p = $env:CLAUDE_CODE_GIT_BASH_PATH
    if ($p -and [IO.File]::Exists($p)) { return 'Git Bash' }
    foreach ($g in @(Get-Command git.exe -All -ErrorAction SilentlyContinue)) {
        $dir = Split-Path -Parent $g.Source
        for ($k = 0; $k -lt 3 -and $dir; $k++) {
            if ([IO.File]::Exists((Join-Path $dir 'bin\bash.exe'))) { return 'Git Bash' }
            $dir = Split-Path -Parent $dir
        }
    }
    'PowerShell'
}

function Invoke-Status {
    if ($Rest.Count -ne 0) { Stop-Usage 'status takes no argument' }
    $r = Get-Report ''
    $version = '<unknown>'
    try {
        $j = [IO.File]::ReadAllText((Join-Path $Root '.claude-plugin\plugin.json')) | ConvertFrom-Json
        if ($j.version) { $version = $j.version }
    } catch { }
    $b = Get-Scan (Join-Path $Root 'sounds')
    $c = Get-Scan $Custom
    $last = 'none'
    try {
        $lf = Join-Path $DataDir 'last-file'
        if ([IO.File]::Exists($lf)) {
            $t = ([IO.File]::ReadAllText($lf)).Split([char]10)[0]
            if ($t.EndsWith("`r", [StringComparison]::Ordinal)) { $t = $t.Substring(0, $t.Length - 1) }
            if ($t) { $last = $t }
        }
    } catch { }
    $writable = "not writable (sandbox?) - add $DataDir to sandbox.filesystem.allowWrite or approve the retry"
    try {
        $null = [IO.Directory]::CreateDirectory($DataDir)
        $probe = Join-Path $DataDir ".writable.$PID"
        [IO.File]::WriteAllBytes($probe, (New-Object byte[] 0))
        [IO.File]::Delete($probe)
        $writable = 'writable'
    } catch { }
    Say "islamic-notifier $version on $(Get-R $r 'os'); hooks run in $(Get-HookShell).",
        "Next reply end: $(Get-R $r 'decision'); player $(Get-R $r 'player') at volume $(Get-R $r 'player_volume'); remote session: $(Get-R $r 'remote').",
        "Settings: muted $($S.muted) ($($Src.muted)), volume $($S.volume) ($($Src.volume)), pauses $($S.pauses) ($($Src.pauses)), sounds_mode $($S.mode) ($($Src.mode)).",
        "Clips: $($b.N) bundled, $($c.N) custom; last played: $last.",
        "Data dir: $DataDir, $writable.",
        "Windows: execution policy $(Get-R $r 'execution_policy'); MediaPlayer $(Get-R $r 'media_player')."
}

switch -CaseSensitive ($Verb) {
    'test' { Invoke-Test }
    'mute' { Invoke-Mute }
    'unmute' { Invoke-Unmute }
    'volume' { Invoke-Volume }
    'pauses' { Invoke-Pauses }
    'sounds' { Invoke-Sounds }
    'status' { Invoke-Status }
    default { Stop-Usage "unknown verb: $Verb" }
}
Stop-Ctl 0 ''
