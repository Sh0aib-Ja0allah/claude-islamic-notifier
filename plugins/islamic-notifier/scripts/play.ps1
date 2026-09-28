# islamic-notifier: play a random dhikr on Windows (docs/PLAN.md, Appendix B.2).
# Windows PowerShell 5.1 and PowerShell 7, core cmdlets and .NET only. ASCII only: PS 5.1
# reads a script without a BOM as ANSI. It never throws out.
#
# Modes:
#   -Hook    The Stop hook where there is no Git Bash. Reads the hook input from stdin and,
#            as notify.sh does, applies the config and env, force-next, mute, pauses and the
#            remote checks. If a clip should play, starts a hidden, detached -Worker and
#            returns. Always exits 0.
#   -Worker  Takes the mutex, keeps the minimum gap, picks a clip and plays it. Exits 0 when
#            it played or skipped cleanly, 3 when another clip is playing, 4 when the chosen
#            clip failed. Started by -Hook, by notify.sh under Git Bash (-Force id), and by
#            notify.sh on WSL (-Path file -Volume v, which skips the gap, the pick and the
#            state files: the caller owns them).
#   -DryRun  Prints the report below and changes no file; ISLAMIC_NOTIFIER_DRY_RUN=1 does the
#            same. With -Hook it also reads stdin; without, input=none.
# Parameters: -Force <id|*>, -Path <file>, -Volume <0-100>, -DataDir <dir>.
#
# Report: one key=value line per fact, with notify.sh's keys, order and values (see its
# header), where os=win, lock is free or busy from the mutex, and player and fallback are
# MediaPlayer, SoundPlayer or none. Two more keys follow at the end:
#   execution_policy=<scope>:<policy>,...   Get-ExecutionPolicy -List
#   media_player=yes|no                     PresentationCore loads and wmp.dll exists
#
# Test seams, inert unless set:
#   ISLAMIC_NOTIFIER_TEST_NOW=<epoch>        the clock, for tests at a time limit
#   ISLAMIC_NOTIFIER_TEST_HOLD_MS=<ms>       the worker waits this long before its work

param(
    [switch]$Hook,
    [switch]$Worker,
    [switch]$DryRun,
    [string]$Force,
    [string]$Path,
    [string]$DataDir,
    [string]$Volume
)

$ErrorActionPreference = 'Stop'
# $null.Count must stay 0 for a missing JSON array.
Set-StrictMode -Off

$MinGap = 2
$ForceTtl = 120
$MutexName = 'Local\IslamicNotifier'

# ---- Helpers

# Unix epoch in UTC. Get-Date -UFormat %s is local time in PS 5.1, hours off on most machines,
# and force-next and last-play are shared with notify.sh.
function Get-Now {
    $t = $env:ISLAMIC_NOTIFIER_TEST_NOW
    if ($t -and (Test-Epoch $t)) { return [long]$t }
    [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

# Test-Epoch VALUE: 1 to 12 digits with no leading zero, as in notify.sh. Anything else in a
# state file is treated as missing.
function Test-Epoch([string]$s) {
    $s -cmatch '^(0|[1-9][0-9]{0,11})\z'
}

# The first line of a file, or $null if it cannot be read.
function Read-FirstLine([string]$file) {
    try {
        if (-not [IO.File]::Exists($file)) { return $null }
        $lines = [IO.File]::ReadAllLines($file, [Text.Encoding]::UTF8)
        if ($lines.Count -eq 0) { return '' }
        return $lines[0]
    } catch {
        return $null
    }
}

function Write-Log([string]$msg) {
    if (-not $script:debug) { return }
    try {
        [IO.File]::AppendAllText((Join-Path $script:data 'debug.log'), "$(Get-Now) play[$PID] $msg`n")
    } catch { }
}

# skip REASON: record why nothing plays. The first reason wins, so the report shows it.
function Set-Skip([string]$reason) {
    if (-not $script:decision) { $script:decision = "skip-$reason" }
    Write-Log "skip $reason"
}

# An id is a clip name up to its first dot (docs/PLAN.md, section 6). Anything else means
# any clip, so it can never reach the worker's command line as an option.
function Get-ForceId([string]$id) {
    if ($id -ceq '*') { return '*' }
    if ($id -cmatch '^[A-Za-z0-9_][A-Za-z0-9_-]*\z') { return $id }
    '*'
}

# ---- Common setup: directories, config and environment (B.2, and notify.sh steps 4-5)

function Initialize-Setup {
    if ($env:CLAUDE_PLUGIN_ROOT) {
        $script:root = $env:CLAUDE_PLUGIN_ROOT
    } else {
        $script:root = Split-Path -Parent $PSScriptRoot
    }
    if ($env:CLAUDE_PLUGIN_DATA) {
        $script:data = $env:CLAUDE_PLUGIN_DATA
    } elseif ($DataDir) {
        $script:data = $DataDir
    } else {
        $local = $env:LOCALAPPDATA
        if (-not $local) { $local = [Environment]::GetFolderPath('LocalApplicationData') }
        $script:data = Join-Path $local 'islamic-notifier'
    }
    # A dry run creates nothing, not even this.
    if (-not $script:dry) {
        try { $null = [IO.Directory]::CreateDirectory($script:data) } catch { }
    }

    # Defaults, then whitelisted key=value lines (docs/PLAN.md, section 4.5). A value that is
    # not valid for its key is ignored, and the last valid line wins.
    $script:muted = '0'
    $script:vol = 70
    $script:pauses = 'on'
    $script:mode = 'both'
    $file = Join-Path $script:data 'config'
    try {
        if ([IO.File]::Exists($file)) {
            $first = $true
            foreach ($line in [IO.File]::ReadAllLines($file, [Text.Encoding]::UTF8)) {
                # Ordinal: a culture compare ignores U+FEFF and would match every line.
                if ($first) {
                    $first = $false
                    if ($line.StartsWith([string][char]0xFEFF, [StringComparison]::Ordinal)) {
                        $line = $line.Substring(1)
                    }
                }
                if ($line.EndsWith("`r", [StringComparison]::Ordinal)) {
                    $line = $line.Substring(0, $line.Length - 1)
                }
                $eq = $line.IndexOf('=')
                if ($eq -lt 0) { continue }
                $key = $line.Substring(0, $eq)
                $val = $line.Substring($eq + 1)
                if ($key -ceq 'muted') {
                    if ($val -ceq '0' -or $val -ceq '1') { $script:muted = $val }
                } elseif ($key -ceq 'volume') {
                    # Leading zeros are stripped, as notify.sh does.
                    if ($val -cmatch '^[0-9]+\z') {
                        $v = $val.TrimStart('0')
                        if ($v -eq '') { $v = '0' }
                        if ($v.Length -le 3 -and [int]$v -le 100) { $script:vol = [int]$v }
                    }
                } elseif ($key -ceq 'pauses') {
                    if ($val -ceq 'on' -or $val -ceq 'off') { $script:pauses = $val }
                } elseif ($key -ceq 'sounds_mode') {
                    if ($val -ceq 'both' -or $val -ceq 'bundled' -or $val -ceq 'custom') {
                        $script:mode = $val
                    }
                }
            }
        }
    } catch {
        Write-Log 'config not readable'
    }
    $m = $env:ISLAMIC_NOTIFIER_MUTE
    if ($m -ceq '0' -or $m -ceq '1') { $script:muted = $m }
}

# ---- B.2 -Hook step 2: force-next, mute, pauses; then the remote checks of B.1 step 10

# The marker is "<epoch> <id or *>". A hook claims it with a rename, so two sessions stopping
# together cannot both use it, and deletes it whether it is fresh or not. A dry run only
# reads it. -Force wins over the marker and leaves it in place.
function Read-ForceMarker([string]$file) {
    $line = Read-FirstLine $file
    if ($null -eq $line) { return $null }
    $sp = $line.IndexOf(' ')
    if ($sp -ge 0) {
        $ts = $line.Substring(0, $sp)
        $id = $line.Substring($sp + 1)
    } else {
        $ts = $line
        $id = '*'
    }
    if (-not (Test-Epoch $ts)) { return $null }
    $age = (Get-Now) - [long]$ts
    if ($age -lt 0 -or $age -gt $ForceTtl) { return $null }
    $id
}

function Resolve-Force {
    $script:forced = $false
    $script:fid = $null
    $id = $null
    $marker = Join-Path $script:data 'force-next'
    if ($Force) {
        $id = $Force
    } elseif ([IO.File]::Exists($marker)) {
        if ($script:dry) {
            $id = Read-ForceMarker $marker
        } else {
            $claimed = "$marker.$PID"
            try {
                [IO.File]::Move($marker, $claimed)
                $id = Read-ForceMarker $claimed
            } catch {
                $id = $null
            } finally {
                try { [IO.File]::Delete($claimed) } catch { }
            }
        }
    }
    if ($null -ne $id) {
        $script:forced = $true
        $script:fid = Get-ForceId $id
        Write-Log "force $($script:fid)"
    }
}

function Test-NonEmptyArray($x) {
    ($x -is [array]) -and ($x.Count -gt 0)
}

# Background work: a non-empty background_tasks or session_crons. The input is parsed as JSON
# (B.2); if that fails, the same text check as notify.sh decides.
function Test-Paused([string]$text) {
    try {
        $j = ConvertFrom-Json -InputObject $text
        return ((Test-NonEmptyArray $j.background_tasks) -or (Test-NonEmptyArray $j.session_crons))
    } catch {
        $c = $text -replace '[ \t\r\n]', ''
        return ($c.Contains('"background_tasks":[{') -or $c.Contains('"session_crons":[{'))
    }
}

function Read-HookInput {
    $script:inputState = 'none'
    if (-not $Hook) { return }
    $script:inputState = 'idle'
    $text = $null
    # Only a redirected stdin: on a console, ReadToEnd would wait forever.
    try {
        if ([Console]::IsInputRedirected) { $text = [Console]::In.ReadToEnd() }
    } catch { }
    if ($text -and (Test-Paused $text)) { $script:inputState = 'paused' }
}

# The env checks of B.1 step 10; the container files do not apply on Windows. "Set" is any
# value: Windows has no empty variables.
function Get-Remote {
    if ($null -ne $env:SSH_CONNECTION -or $null -ne $env:SSH_CLIENT -or $null -ne $env:SSH_TTY) {
        return 'ssh'
    }
    if ($env:CODESPACES -ceq 'true') { return 'codespaces' }
    if ($env:REMOTE_CONTAINERS -ceq 'true') { return 'devcontainer' }
    if ($env:CLAUDE_CODE_REMOTE -ceq 'true') { return 'claude-remote' }
    if ($null -ne $env:GITPOD_WORKSPACE_ID) { return 'gitpod' }
    'none'
}

# The decision order of docs/PLAN.md, section 2, up to the worker: mute, pauses, remote.
function Invoke-HookChecks {
    Resolve-Force
    if (-not $script:forced) {
        if ($script:muted -eq '1') {
            Set-Skip muted
        } elseif ($script:vol -eq 0) {
            Set-Skip volume
        }
    }
    Read-HookInput
    if (-not $script:forced -and $script:pauses -eq 'off' -and $script:inputState -eq 'paused') {
        Set-Skip paused
    }
    $script:remote = Get-Remote
    $script:forceLocal = '0'
    if ($env:ISLAMIC_NOTIFIER_FORCE_LOCAL -eq '1') { $script:forceLocal = '1' }
    if ($script:remote -ne 'none' -and $script:forceLocal -eq '0') { Set-Skip remote }
}

# ---- Worker facts, shared by the report and the worker

function Get-Pool {
    $dirs = @()
    if ($script:mode -ne 'custom') { $dirs += Join-Path $script:root 'sounds' }
    if ($script:mode -ne 'bundled' -and $env:USERPROFILE) {
        $dirs += Join-Path $env:USERPROFILE '.claude\islamic-notifier\sounds'
    }
    $pool = New-Object System.Collections.Generic.List[string]
    foreach ($d in $dirs) {
        try {
            if (-not [IO.Directory]::Exists($d)) { continue }
            $files = [IO.Directory]::GetFiles($d)
            [Array]::Sort($files, [StringComparer]::Ordinal)
            foreach ($f in $files) {
                $n = [IO.Path]::GetFileName($f)
                if ($n.StartsWith('.', [StringComparison]::Ordinal)) { continue }
                if ($n -notmatch '\.(wav|mp3)\z') { continue }
                if ($script:forced -and $script:fid -ne '*' -and
                    -not $n.StartsWith("$($script:fid).", [StringComparison]::Ordinal)) {
                    continue
                }
                $pool.Add($f)
            }
        } catch { }
    }
    return ,$pool.ToArray()
}

# With two or more clips, the one played last is left out; Get-Random picks from the rest.
function Select-Clip($pool) {
    if ($pool.Count -eq 0) { return $null }
    if ($pool.Count -eq 1) { return $pool[0] }
    $last = Read-FirstLine (Join-Path $script:data 'last-file')
    $cands = @($pool | Where-Object { $_ -ne $last })
    if ($cands.Count -eq 0) { return $pool[0] }
    Get-Random -InputObject $cands
}

function Test-MediaPlayer {
    try {
        Add-Type -AssemblyName PresentationCore, WindowsBase
    } catch {
        return $false
    }
    [IO.File]::Exists((Join-Path ([Environment]::SystemDirectory) 'wmp.dll'))
}

# The WAV SoundPlayer can play for a clip: the clip itself, or a .wav beside it.
function Get-WavFor([string]$clip) {
    if (-not $clip) { return $null }
    if ($clip -match '\.wav\z') { return $clip }
    $sib = [IO.Path]::ChangeExtension($clip, '.wav')
    if ([IO.File]::Exists($sib)) { return $sib }
    $null
}

function Get-Decimal([int]$v) {
    "$([Math]::Floor($v / 100)).$(($v % 100).ToString('D2'))"
}

function Test-GapRecent {
    $lp = Read-FirstLine (Join-Path $script:data 'last-play')
    if (-not (Test-Epoch $lp)) { return $false }
    $age = (Get-Now) - [long]$lp
    ($age -ge 0 -and $age -lt $MinGap)
}

# ---- -DryRun: the report

function Invoke-Report {
    Invoke-HookChecks
    $gap = '-'
    $pool = '-'
    $clip = $script:clipPath
    if ($clip) {
        if (-not [IO.File]::Exists($clip)) { Set-Skip no-clip }
    } else {
        $gap = 'ok'
    }
    # The mutex is only looked at: opening an existing one does not take it.
    $lock = 'free'
    $m = $null
    if ([Threading.Mutex]::TryOpenExisting($MutexName, [ref]$m)) {
        $lock = 'busy'
        $m.Dispose()
        Set-Skip busy
    }
    if (-not $clip) {
        if (Test-GapRecent) {
            $gap = 'recent'
            Set-Skip gap
        }
        $all = Get-Pool
        $pool = $all.Count
        $clip = Select-Clip $all
        if (-not $clip) {
            $clip = 'none'
            Set-Skip no-clip
        }
    }
    $mediaOk = Test-MediaPlayer
    $wav = $null
    if ($clip -ne 'none') { $wav = Get-WavFor $clip }
    $soundOk = [bool]$wav -and $script:vol -gt 0
    $player = 'none'
    $fallback = 'none'
    $pv = 'none'
    if ($mediaOk) {
        $player = 'MediaPlayer'
        $pv = Get-Decimal $script:vol
        if ($soundOk) { $fallback = 'SoundPlayer' }
    } elseif ($soundOk) {
        $player = 'SoundPlayer'
    }
    if ($player -eq 'none') { Set-Skip no-player }
    if (-not $script:decision) { $script:decision = 'play' }
    $forceText = 'none'
    if ($script:forced) { $forceText = $script:fid }
    $ep = @(Get-ExecutionPolicy -List | ForEach-Object { "$($_.Scope):$($_.ExecutionPolicy)" }) -join ','
    $mp = 'no'
    if ($mediaOk) { $mp = 'yes' }
    @(
        'report=1'
        'os=win'
        "root=$($script:root)"
        "data=$($script:data)"
        "input=$($script:inputState)"
        "force=$forceText"
        "muted=$($script:muted)"
        "volume=$($script:vol)"
        "pauses=$($script:pauses)"
        "sounds_mode=$($script:mode)"
        "remote=$($script:remote)"
        "force_local=$($script:forceLocal)"
        "gap=$gap"
        "lock=$lock"
        "pool=$pool"
        "clip=$clip"
        "player=$player"
        "fallback=$fallback"
        "player_volume=$pv"
        "decision=$($script:decision)"
        "execution_policy=$ep"
        "media_player=$mp"
    )
}

# ---- -Hook: B.2 step 3, the detached worker

# Process.Start creates the worker with every inheritable handle of this process. Besides
# its std handles, a redirected powershell.exe holds more inheritable copies of the pipes
# its parent reads (seen: two extra pipe handles). A worker holding them would keep the
# hook's stdout and stderr open until the clip ended: Claude Code would see the hook still
# running, and claude -p teardown would kill it. So no handle here stays inheritable;
# Process.Start then makes fresh pipes for the worker alone. The P/Invoke is emitted at run
# time, so nothing is compiled.
function Clear-HandleInheritance {
    try {
        $name = New-Object Reflection.AssemblyName 'IslamicNotifierNative'
        $asm = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly($name, 'Run')
        $mod = $asm.DefineDynamicModule('IslamicNotifierNative')
        $tb = $mod.DefineType('IslamicNotifierNative.Kernel32', 'Public, Class')
        $method = $tb.DefinePInvokeMethod('SetHandleInformation', 'kernel32.dll',
            'Public, Static, PinvokeImpl', 'Standard', [bool], [Type[]]@([IntPtr], [int], [int]),
            'Winapi', 'Ansi')
        $method.SetImplementationFlags('PreserveSig')
        $k32 = $tb.CreateType()
        # HANDLE_FLAG_INHERIT is 1. Handle values are multiples of 4; a value that is not a
        # handle just fails.
        for ($h = 4; $h -lt 65536; $h += 4) {
            $null = $k32::SetHandleInformation([IntPtr]$h, 1, 0)
        }
    } catch {
        Write-Log "handles still inheritable: $($_.Exception.Message)"
    }
}

function ConvertTo-Arg([string]$s) {
    # A backslash before the closing quote would escape it.
    '"' + ($s -replace '(\\+)$', '$1$1') + '"'
}

function Start-Worker {
    Clear-HandleInheritance
    $tail = '-Worker'
    if ($script:forced) { $tail += ' -Force ' + $script:fid }
    if ($DataDir) { $tail += ' -DataDir ' + (ConvertTo-Arg $DataDir) }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
        (ConvertTo-Arg $PSCommandPath) + ' ' + $tail
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    # Its own pipes, never written to; stdin is closed at once.
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # Not the project dir or the plugin root, which the worker would keep busy.
    $psi.WorkingDirectory = [IO.Path]::GetTempPath()
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    Write-Log "worker started, pid $($p.Id): $tail"
}

function Invoke-Hook {
    Invoke-HookChecks
    if ($script:decision) { return }
    Start-Worker
}

# ---- -Worker (checkpoint B brings the mutex, the gap, the pick and playback)

function Invoke-Worker {
    $hold = $env:ISLAMIC_NOTIFIER_TEST_HOLD_MS
    if ($hold -cmatch '^[0-9]{1,6}\z') { Start-Sleep -Milliseconds ([int]$hold) }
    Write-Log 'worker done'
}

# ---- Main

# Script state never reuses a parameter's name: PowerShell names ignore case, so
# $script:force would be the -Force parameter itself.
$script:rc = 0
$script:decision = $null
$script:debug = $false
$script:remote = 'none'
$script:forceLocal = '0'
$script:forced = $false
$script:inputState = 'none'
$script:clipPath = $null
try {
    $script:dry = [bool]$DryRun -or $env:ISLAMIC_NOTIFIER_DRY_RUN -eq '1'
    $script:debug = -not $script:dry -and $env:ISLAMIC_NOTIFIER_DEBUG -eq '1'
    Initialize-Setup
    if ($Path) { $script:clipPath = $Path }
    if ($Volume -cmatch '^[0-9]{1,3}\z' -and [int]$Volume -le 100) { $script:vol = [int]$Volume }
    if ($script:dry) {
        Invoke-Report
    } elseif ($Hook) {
        Invoke-Hook
    } elseif ($Worker) {
        Invoke-Worker
    }
} catch {
    Write-Log "error: $($_.Exception.Message)"
}
exit $script:rc
