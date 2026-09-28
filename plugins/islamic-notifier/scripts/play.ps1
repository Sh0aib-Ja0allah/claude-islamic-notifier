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
#   ISLAMIC_NOTIFIER_TEST_HOLD_MS=<ms>       the worker waits this long after taking the mutex
#   ISLAMIC_NOTIFIER_TEST_MUTEX=<name>       the mutex name, so tests never share a real one
#   ISLAMIC_NOTIFIER_TEST_NO_MEDIAPLAYER=1   MediaPlayer is missing, as without Windows Media
#                                            Player; =throw: it throws when created, as WPF
#                                            does for MILAVERR_INVALIDWMPVERSION. Either way
#                                            tests reach the SoundPlayer fallback.

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
$OpenTimeoutMs = 5000
$MaxPlayMs = 30000
$MutexName = 'Local\IslamicNotifier'
if ($env:ISLAMIC_NOTIFIER_TEST_MUTEX) { $MutexName = $env:ISLAMIC_NOTIFIER_TEST_MUTEX }

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

# The hook, its worker and a status call can all log at once, so the file is shared for
# reading and writing, and a busy file gets a few more tries.
function Write-Log([string]$msg) {
    if (-not $script:debug) { return }
    $bytes = [Text.Encoding]::UTF8.GetBytes("$(Get-Now) play[$PID] $msg`n")
    for ($try = 0; $try -lt 5; $try++) {
        try {
            $fs = New-Object IO.FileStream((Join-Path $script:data 'debug.log'), 'Append', 'Write', 'ReadWrite')
            try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
            return
        } catch {
            Start-Sleep -Milliseconds 20
        }
    }
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
        # Absolute, since the worker starts in another directory.
        $script:data = [IO.Path]::GetFullPath($DataDir)
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
    if ($env:ISLAMIC_NOTIFIER_TEST_NO_MEDIAPLAYER -eq '1') { return $false }
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
    # The mutex is only looked at: opening an existing one does not take it. One an elevated
    # session created may deny access; it is still held.
    $lock = 'free'
    $m = $null
    try {
        if ([Threading.Mutex]::TryOpenExisting($MutexName, [ref]$m)) {
            $lock = 'busy'
            $m.Dispose()
        }
    } catch {
        $lock = 'busy'
    }
    if ($lock -eq 'busy') { Set-Skip busy }
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
    $ep = 'unknown'
    try {
        $ep = @(Get-ExecutionPolicy -List | ForEach-Object { "$($_.Scope):$($_.ExecutionPolicy)" }) -join ','
    } catch { }
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
    if ($DataDir) { $tail += ' -DataDir ' + (ConvertTo-Arg $script:data) }
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

# ---- -Worker: B.2 worker steps 1-6

# Step 1. The mutex is released in the top-level finally, on this same thread.
function Enter-Mutex {
    try {
        $script:mutex = New-Object System.Threading.Mutex($false, $MutexName)
    } catch [System.UnauthorizedAccessException] {
        # An elevated session created it and holds it: busy.
        return $false
    }
    try {
        $script:owned = $script:mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        # Its last owner died holding it; the wait gave it to this process.
        $script:owned = $true
    }
    $script:owned
}

# A file: URI with each path segment escaped, so a space, '#', '%' or '[' in a name stays
# part of the name.
function ConvertTo-FileUri([string]$file) {
    $parts = [IO.Path]::GetFullPath($file).Split('\')
    $esc = @($parts[0])
    for ($i = 1; $i -lt $parts.Count; $i++) { $esc += [Uri]::EscapeDataString($parts[$i]) }
    New-Object Uri (('file:///' + ($esc -join '/')), [UriKind]::Absolute)
}

# Step 4. WPF MediaPlayer, pumped on this thread's dispatcher until the clip ends, fails, is
# not open after 5 s, or reaches the 30 s cap (which counts as played). True if it played.
# WPF reports some failures as events and others, such as MILAVERR_INVALIDWMPVERSION, by
# throwing from the constructor, Open or the Volume setter; both mean false, so the
# fallback runs.
function Invoke-MediaPlayer([string]$file, [int]$vol) {
    if (-not (Test-MediaPlayer)) {
        Write-Log 'media failed: MediaPlayer is not available'
        return $false
    }
    $state = @{ Opened = $false; Ended = $false; Failed = $null }
    $mp = $null
    try {
        if ($env:ISLAMIC_NOTIFIER_TEST_NO_MEDIAPLAYER -eq 'throw') {
            throw 'MediaPlayer creation failed (test seam)'
        }
        $mp = New-Object System.Windows.Media.MediaPlayer
        # Always set: the default is 0.5.
        $mp.Volume = $vol / 100
        $mp.add_MediaOpened({ $state.Opened = $true }.GetNewClosure())
        $mp.add_MediaEnded({ $state.Ended = $true }.GetNewClosure())
        $mp.add_MediaFailed({
                param($sender, $e)
                $state.Failed = "failed: $($e.ErrorException.Message)"
            }.GetNewClosure())
        Write-Log "media open at volume $(Get-Decimal $vol): $file"
        $mp.Open((ConvertTo-FileUri $file))
        $mp.Play()
        $dispatcher = [Windows.Threading.Dispatcher]::CurrentDispatcher
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $opened = $false
        while ($true) {
            $null = $dispatcher.Invoke([Windows.Threading.DispatcherPriority]::Background, [Action] { })
            if ($state.Opened -and -not $opened) {
                $opened = $true
                Write-Log 'media opened'
            }
            if ($state.Failed) {
                Write-Log "media $($state.Failed)"
                return $false
            }
            if ($state.Ended) {
                Write-Log "media ended after $($sw.ElapsedMilliseconds) ms"
                return $true
            }
            if (-not $opened -and $sw.ElapsedMilliseconds -ge $OpenTimeoutMs) {
                Write-Log 'media failed: not open after 5 s'
                return $false
            }
            if ($sw.ElapsedMilliseconds -ge $MaxPlayMs) {
                Write-Log 'media stopped at the 30 s cap'
                return $true
            }
            Start-Sleep -Milliseconds 25
        }
    } catch {
        Write-Log "media failed: $($_.Exception.Message)"
        return $false
    } finally {
        if ($mp) {
            try {
                $mp.Stop()
                $mp.Close()
            } catch { }
        }
    }
}

# Step 5. SoundPlayer plays WAV only, at full volume. It reads a stream, so no name is ever
# parsed as a URL.
function Invoke-SoundPlayer([string]$wav) {
    $stream = $null
    try {
        $stream = [IO.File]::OpenRead($wav)
        $sp = New-Object System.Media.SoundPlayer
        $sp.Stream = $stream
        $sp.PlaySync()
        $sp.Dispose()
        Write-Log "soundplayer played: $wav"
        return $true
    } catch {
        Write-Log "soundplayer failed: $($_.Exception.Message)"
        return $false
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

# Steps 3 to 5 for one clip. True if it played.
function Invoke-Clip([string]$clip) {
    if (-not [IO.File]::Exists($clip)) {
        Write-Log "failed: no such file: $clip"
        return $false
    }
    $file = $clip
    # Step 3. A clip on a share (a WSL path, \\wsl$\...) plays from a local copy.
    if ($clip.StartsWith('\\', [StringComparison]::Ordinal)) {
        $script:tempCopy = Join-Path ([IO.Path]::GetTempPath()) ("islamic-notifier-$PID" + [IO.Path]::GetExtension($clip))
        [IO.File]::Copy($clip, $script:tempCopy, $true)
        Write-Log "copied to $($script:tempCopy)"
        $file = $script:tempCopy
    }
    if (Invoke-MediaPlayer $file $script:vol) { return $true }
    # SoundPlayer never runs at volume 0: it cannot play quieter than full.
    if ($script:vol -le 0) {
        Write-Log 'failed: no fallback at volume 0'
        return $false
    }
    if ($file -match '\.wav\z') {
        $wav = $file
    } else {
        $wav = Get-WavFor $clip
    }
    if (-not $wav) {
        Write-Log 'failed: no WAV for the fallback'
        return $false
    }
    Invoke-SoundPlayer $wav
}

function Invoke-Worker {
    if ($Force) {
        $script:forced = $true
        $script:fid = Get-ForceId $Force
    }
    if (-not (Enter-Mutex)) {
        Write-Log 'busy: another clip is playing'
        $script:rc = 3
        return
    }
    $hold = $env:ISLAMIC_NOTIFIER_TEST_HOLD_MS
    if ($hold -cmatch '^[0-9]{1,6}\z') { Start-Sleep -Milliseconds ([int]$hold) }
    $start = Get-Now
    # Step 2. -Path comes from WSL, where notify.sh already kept the gap and picked.
    if ($script:clipPath) {
        $clip = $script:clipPath
    } else {
        if (Test-GapRecent) {
            Set-Skip gap
            return
        }
        $clip = Select-Clip (Get-Pool)
        if (-not $clip) {
            Set-Skip no-clip
            return
        }
    }
    Write-Log "clip $clip"
    $script:chosen = $true
    if (-not (Invoke-Clip $clip)) {
        $script:rc = 4
        return
    }
    # The same state files as notify.sh (docs/PLAN.md, section 4.5); last-play is when this
    # play started. The WSL caller keeps its own.
    if (-not $script:clipPath) {
        try {
            [IO.File]::WriteAllText((Join-Path $script:data 'last-play'), "$start`n")
            [IO.File]::WriteAllText((Join-Path $script:data 'last-file'), "$clip`n")
        } catch {
            Write-Log "state not written: $($_.Exception.Message)"
        }
    }
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
$script:mutex = $null
$script:owned = $false
$script:chosen = $false
$script:tempCopy = $null
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
    # An error after a clip was chosen means that clip failed.
    if ($script:chosen) { $script:rc = 4 }
} finally {
    if ($script:owned) {
        try { $script:mutex.ReleaseMutex() } catch { }
    }
    if ($script:mutex) {
        try { $script:mutex.Dispose() } catch { }
    }
    if ($script:tempCopy) {
        try { [IO.File]::Delete($script:tempCopy) } catch { }
    }
}
exit $script:rc
