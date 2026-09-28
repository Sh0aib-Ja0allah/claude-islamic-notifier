# Tests for plugins/islamic-notifier/scripts/play.ps1 (docs/PLAN.md, section 10). Plain
# PowerShell with no framework, for Windows PowerShell 5.1 and PowerShell 7. Prints
# "pass=N fail=M skip=K" and exits non-zero if any test fails; each failure is explained on
# stderr, and each skip on stdout.
#
# Usage, from the repo root:
#   powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests/play_test.ps1
#   pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests/play_test.ps1
#
# Every test gets a sandbox whose paths contain spaces. play.ps1 runs in a child process of
# this same PowerShell, with an environment built from scratch: USERPROFILE, LOCALAPPDATA,
# APPDATA, TEMP, TMP, CLAUDE_PLUGIN_DATA and CLAUDE_PLUGIN_ROOT point into the sandbox, and
# no host variable such as SSH_* or CLAUDE_* comes through. No test is audible: a real play
# is always at volume 0, or of a WAV with no samples.
#
# A test that needs a clip to play is skipped, with the reason, on a machine with no Windows
# Media Player (wmp.dll) or no audio output, as a Windows Server CI runner may be (section 9).
# Where both are present, a failed play fails the test.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$Repo = Split-Path -Parent $PSScriptRoot
$Play = Join-Path $Repo 'plugins\islamic-notifier\scripts\play.ps1'
$Notify = Join-Path $Repo 'plugins\islamic-notifier\scripts\notify.sh'
$Fixtures = Join-Path $PSScriptRoot 'fixtures'
$Exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$script:Pass = 0
$script:Fail = 0
$script:Skip = 0
$script:SkipReason = $null
$script:S = $null

# A child reads its stdin as Claude Code writes it: UTF-8 with no BOM. .NET Framework's
# Process writes the preamble of [Console]::InputEncoding into every child's stdin, so on a
# UTF-8 console (code page 65001, as on GitHub's Windows runners) each child would read a
# BOM before its input. Same code page, no preamble. pwsh never writes one.
$InputEncoding = [Console]::InputEncoding
if ($InputEncoding.CodePage -eq 65001 -and $InputEncoding.GetPreamble().Length -gt 0) {
    [Console]::InputEncoding = New-Object Text.UTF8Encoding $false
}

# The only host variables a child sees; everything else is the sandbox's.
$BaseEnvNames = @(
    'SystemRoot', 'SystemDrive', 'windir', 'ComSpec', 'PATHEXT', 'Path', 'ProgramFiles',
    'ProgramFiles(x86)', 'ProgramW6432', 'CommonProgramFiles', 'CommonProgramFiles(x86)',
    'CommonProgramW6432', 'ProgramData', 'ALLUSERSPROFILE', 'PUBLIC', 'PROCESSOR_ARCHITECTURE',
    'NUMBER_OF_PROCESSORS', 'OS', 'USERNAME', 'USERDOMAIN', 'COMPUTERNAME'
)

# Windows PowerShell's module analysis cache. A 5.1 child with none analyses every module on
# its module path before its first cmdlet: 29 s on a CI runner with the Az modules. Each
# sandbox gets a copy of this process's cache where a child looks for it: the local app data
# folder under USERPROFILE, which is not the LOCALAPPDATA variable (5.1 reads
# PSModuleAnalysisCachePath, else that folder; AnalysisCacheData.cacheStoreLocation). pwsh
# starts in well under a second without one, so it gets none.
$ModuleCacheName = 'Microsoft\Windows\PowerShell\ModuleAnalysisCache'
$ModuleCache = $null
if ($PSVersionTable.PSEdition -ne 'Core') {
    $ModuleCache = $env:PSModuleAnalysisCachePath
    if (-not $ModuleCache) {
        $ModuleCache = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) $ModuleCacheName
    }
    if (-not [IO.File]::Exists($ModuleCache)) { $ModuleCache = $null }
}

# ---- Sandbox

function New-Sandbox {
    $base = Join-Path ([IO.Path]::GetTempPath()) ('play test ' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $dir = Join-Path $base 'sand box'
    $s = [pscustomobject]@{
        Base    = $base
        Dir     = $dir
        Home    = Join-Path $dir 'home dir'
        Root    = Join-Path $dir 'plugin root'
        Data    = Join-Path $dir 'data dir'
        Local   = Join-Path $dir 'local app data'
        AppData = Join-Path $dir 'app data'
        Temp    = Join-Path $dir 'temp dir'
    }
    $s | Add-Member NoteProperty Bundled (Join-Path $s.Root 'sounds')
    $s | Add-Member NoteProperty Custom (Join-Path $s.Home '.claude\islamic-notifier\sounds')
    # A mutex of its own, so no test shares Local\IslamicNotifier with a real session.
    $s | Add-Member NoteProperty Mutex ('Local\IslamicNotifierTest-' + [Guid]::NewGuid().ToString('N'))
    foreach ($d in $s.Home, $s.Root, $s.Data, $s.Local, $s.AppData, $s.Temp) {
        $null = [IO.Directory]::CreateDirectory($d)
    }
    if ($ModuleCache) {
        # Only speed: a child with no copy is slow, not wrong.
        try {
            $cache = Join-Path $s.Home "AppData\Local\$ModuleCacheName"
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($cache))
            [IO.File]::Copy($ModuleCache, $cache)
        } catch { }
    }
    $s
}

# Wait for every worker the sandbox's debug.log names, so the sandbox can go.
function Wait-Workers {
    try {
        foreach ($id in (Get-WorkerPids)) {
            try { $null = (Get-Process -Id $id -ErrorAction Stop).WaitForExit(20000) } catch { }
        }
    } catch { }
}

function Remove-Sandbox {
    if (-not $script:S) { return }
    for ($i = 0; $i -lt 20; $i++) {
        try {
            if ([IO.Directory]::Exists($script:S.Base)) {
                Remove-Item -LiteralPath $script:S.Base -Recurse -Force
            }
            break
        } catch {
            Start-Sleep -Milliseconds 250
        }
    }
    $script:S = $null
}

# Test NAME BODY: run BODY with a fresh sandbox in $S. A thrown error fails the test, and
# Skip-Test skips it.
function Test([string]$name, [scriptblock]$body) {
    $script:S = New-Sandbox
    $script:SkipReason = $null
    try {
        & $body
        $script:Pass++
    } catch {
        if ($script:SkipReason) {
            $script:Skip++
            [Console]::Out.WriteLine("skip ${name}: $($script:SkipReason)")
        } else {
            $script:Fail++
            [Console]::Error.WriteLine("FAIL ${name}: $($_.Exception.Message)")
        }
    } finally {
        Wait-Workers
        Remove-Sandbox
    }
}

# Skip-Test REASON: end the test as skipped, for a capability this machine lacks. A skip is
# never a pass.
function Skip-Test([string]$reason) {
    $script:SkipReason = $reason
    throw "skip: $reason"
}

# ---- Running play.ps1

function Format-Arg([string]$a) {
    if ($a -cmatch '^[A-Za-z0-9_*.:\\/-]+\z') { return $a }
    '"' + ($a -replace '(\\+)$', '$1$1') + '"'
}

# New-PlayInfo ARGS ENV: a ProcessStartInfo for play.ps1 in the sandbox. ENV adds variables
# ($null removes one). ISLAMIC_NOTIFIER_DEBUG=1 is on unless removed.
function New-PlayInfo([string[]]$Arguments, [hashtable]$Env) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $all = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Play) + $Arguments
    $psi.Arguments = ($all | ForEach-Object { Format-Arg $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $script:S.Dir
    $ev = $psi.EnvironmentVariables
    $ev.Clear()
    foreach ($n in $BaseEnvNames) {
        $v = [Environment]::GetEnvironmentVariable($n)
        if ($null -ne $v) { $ev[$n] = $v }
    }
    $ev['USERPROFILE'] = $script:S.Home
    $ev['LOCALAPPDATA'] = $script:S.Local
    $ev['APPDATA'] = $script:S.AppData
    $ev['TEMP'] = $script:S.Temp
    $ev['TMP'] = $script:S.Temp
    $ev['CLAUDE_PLUGIN_DATA'] = $script:S.Data
    $ev['CLAUDE_PLUGIN_ROOT'] = $script:S.Root
    $ev['ISLAMIC_NOTIFIER_DEBUG'] = '1'
    $ev['ISLAMIC_NOTIFIER_TEST_MUTEX'] = $script:S.Mutex
    if ($Env) {
        foreach ($k in $Env.Keys) {
            if ($null -eq $Env[$k]) { $ev.Remove($k) } else { $ev[$k] = [string]$Env[$k] }
        }
    }
    $psi
}

# Invoke-Play ARGS [-Env @{...}] [-Stdin TEXT]: run play.ps1 and wait for it.
function Invoke-Play {
    param([string[]]$Arguments = @(), [hashtable]$Env = @{}, [string]$Stdin = '')
    $psi = New-PlayInfo $Arguments $Env
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = [Diagnostics.Process]::Start($psi)
    if ($Stdin) { $p.StandardInput.Write($Stdin) }
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(90000)) {
        try { $p.Kill() } catch { }
        throw "play.ps1 $($Arguments -join ' ') did not exit in 90 s"
    }
    $p.WaitForExit()
    [pscustomobject]@{
        Rc  = $p.ExitCode
        Out = $out.Result
        Err = $err.Result
        Ms  = $sw.ElapsedMilliseconds
    }
}

function Get-Fixture([string]$name) {
    [IO.File]::ReadAllText((Join-Path $Fixtures $name))
}

# Hook [ENV] [FIXTURE] [ARGS]: play.ps1 -Hook, which must exit 0 and print nothing.
function Hook {
    param([hashtable]$Env = @{}, [string]$Fixture = 'stop-idle.json', [string[]]$Extra = @())
    $r = Invoke-Play -Arguments (@('-Hook') + $Extra) -Env $Env -Stdin (Get-Fixture $Fixture)
    Assert-Quiet $r
    $r
}

# Dry [ENV] [ARGS] [STDIN]: play.ps1 -DryRun, which must exit 0 with an empty stderr; the
# report comes back as an ordered dictionary.
function Dry {
    param([hashtable]$Env = @{}, [string[]]$Extra = @(), [string]$Stdin = '')
    $r = Invoke-Play -Arguments (@('-DryRun') + $Extra) -Env $Env -Stdin $Stdin
    Assert-Eq 0 $r.Rc 'dry-run exit code'
    Assert-Eq '' $r.Err 'dry-run stderr'
    ConvertFrom-Report $r.Out
}

function ConvertFrom-Report([string]$text) {
    $h = [ordered]@{}
    foreach ($l in ($text -split "`r?`n")) {
        $i = $l.IndexOf('=')
        if ($i -gt 0) { $h[$l.Substring(0, $i)] = $l.Substring($i + 1) }
    }
    $h
}

# ---- State of the sandbox

# Get-Log [DIR]: the lines of debug.log, read while workers may still append to it.
function Get-Log([string]$dir = $script:S.Data) {
    $f = Join-Path $dir 'debug.log'
    for ($try = 0; $try -lt 10; $try++) {
        if (-not [IO.File]::Exists($f)) { return @() }
        try {
            $fs = New-Object IO.FileStream($f, 'Open', 'Read', 'ReadWrite')
            try {
                $text = (New-Object IO.StreamReader($fs)).ReadToEnd()
            } finally {
                $fs.Dispose()
            }
            return @($text -split "`n" | Where-Object { $_ -ne '' })
        } catch {
            Start-Sleep -Milliseconds 50
        }
    }
    throw "debug.log could not be read"
}

function Get-WorkerStarts { @(Get-Log | Where-Object { $_ -match 'worker started, pid ' }) }

function Get-WorkerPids {
    if (-not $script:S) { return @() }
    foreach ($l in (Get-WorkerStarts)) {
        if ($l -match 'worker started, pid (\d+)') { [int]$Matches[1] }
    }
}

function Get-DataFiles {
    @([IO.Directory]::GetFiles($script:S.Data) | ForEach-Object { [IO.Path]::GetFileName($_) } |
        Sort-Object) -join ' '
}

# Put FILE LINE...: write FILE with LF-ended lines, making its directory.
function Put([string]$file, [string[]]$lines) {
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file))
    [IO.File]::WriteAllText($file, (($lines | ForEach-Object { "$_`n" }) -join ''))
}

function Now { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

# ---- Asserts

function Assert-Eq($expected, $actual, [string]$what) {
    if ("$expected" -cne "$actual") { throw "${what}: expected [$expected], got [$actual]" }
}

function Assert-True($cond, [string]$what) {
    if (-not $cond) { throw $what }
}

function Assert-Quiet($r) {
    Assert-Eq 0 $r.Rc 'exit code'
    Assert-Eq '' $r.Out 'stdout'
    Assert-Eq '' $r.Err 'stderr'
}

# The worker the hook started (exactly one), after it has finished.
function Assert-OneWorker([string]$tail) {
    $starts = @(Get-WorkerStarts)
    Assert-Eq 1 $starts.Count 'workers started'
    Assert-True ($starts[0] -match ": $([regex]::Escape($tail))\z") "worker args: $($starts[0])"
    Wait-Workers
}

function Assert-NoWorker {
    Assert-Eq 0 (Get-WorkerStarts).Count 'workers started'
}

# ---- Clips and the worker

# New-Wav FILE [SAMPLES]: a 16-bit mono 44.1 kHz WAV of silence, with no samples by default.
function New-Wav([string]$file, [int]$samples = 0) {
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file))
    $n = $samples * 2
    $ms = New-Object IO.MemoryStream
    $w = New-Object IO.BinaryWriter($ms)
    $ascii = [Text.Encoding]::ASCII
    $w.Write($ascii.GetBytes('RIFF')); $w.Write([int](36 + $n)); $w.Write($ascii.GetBytes('WAVE'))
    $w.Write($ascii.GetBytes('fmt ')); $w.Write([int]16); $w.Write([int16]1); $w.Write([int16]1)
    $w.Write([int]44100); $w.Write([int]88200); $w.Write([int16]2); $w.Write([int16]16)
    $w.Write($ascii.GetBytes('data')); $w.Write([int]$n); $w.Write((New-Object byte[] $n))
    $w.Flush()
    [IO.File]::WriteAllBytes($file, $ms.ToArray())
}

# Worker [ARGS] [ENV]: play.ps1 -Worker, which must print nothing; its exit code is in .Rc.
function Worker {
    param([string[]]$Extra = @(), [hashtable]$Env = @{})
    $r = Invoke-Play -Arguments (@('-Worker') + $Extra) -Env $Env
    Assert-Eq '' $r.Out 'worker stdout'
    Assert-Eq '' $r.Err 'worker stderr'
    $r
}

# The clips the workers chose, in order.
function Get-Played {
    @(Get-Log | ForEach-Object { if ($_ -match ' play\[\d+\] clip (.*)\z') { $Matches[1] } })
}

function Get-LogMatch([string]$pattern) {
    @(Get-Log | Where-Object { $_ -match $pattern })
}

function Read-Data([string]$name) {
    $f = Join-Path $S.Data $name
    if (-not [IO.File]::Exists($f)) { return $null }
    [IO.File]::ReadAllText($f).TrimEnd("`n")
}

# ---- What this machine can play

# WPF's MediaPlayer needs Windows Media Player (wmp.dll), and a clip plays to its end only
# with an audio output. waveOutGetNumDevs counts no output when there is no audio device or
# the Windows Audio service is not running; -1 means it could not be asked, which skips
# nothing.
function Get-AudioOutputCount {
    try {
        $t = Add-Type -Namespace PlayTest -Name WinMM -PassThru -MemberDefinition @'
[DllImport("winmm.dll")] public static extern uint waveOutGetNumDevs();
'@
        [int]$t::waveOutGetNumDevs()
    } catch {
        -1
    }
}

$HasWmp = [IO.File]::Exists((Join-Path ([Environment]::SystemDirectory) 'wmp.dll'))
$AudioOutputs = Get-AudioOutputCount
$script:NoMediaPlayer = $null
if (-not $HasWmp) { $script:NoMediaPlayer = 'no Windows Media Player here (wmp.dll is missing)' }
$script:NoPlayback = $script:NoMediaPlayer
if (-not $script:NoPlayback -and $AudioOutputs -eq 0) {
    $script:NoPlayback = 'no audio output here (waveOutGetNumDevs is 0)'
}
$AudioService = 'missing'
try { $AudioService = [string](Get-Service -Name Audiosrv -ErrorAction Stop).Status } catch { }
[Console]::Out.WriteLine("host: PowerShell $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition), " +
    "wmp.dll $(if ($HasWmp) { 'yes' } else { 'no' }), audio outputs $AudioOutputs, audio service $AudioService, " +
    "stdin code page $($InputEncoding.CodePage) with a $($InputEncoding.GetPreamble().Length)-byte preamble, " +
    "now $([Console]::InputEncoding.GetPreamble().Length), " +
    "module cache $(if ($ModuleCache) { "$((Get-Item -LiteralPath $ModuleCache).Length) bytes" } else { 'none' })")

# For a test that needs MediaPlayer to exist.
function Skip-UnlessMediaPlayer {
    if ($script:NoMediaPlayer) { Skip-Test $script:NoMediaPlayer }
}

# For a test that needs a clip to play to its end.
function Skip-UnlessPlayback {
    if ($script:NoPlayback) { Skip-Test $script:NoPlayback }
}

# ---- Report

# The report's keys, as notify.sh's report() prints them, in order.
function Get-NotifyKeys {
    $text = [IO.File]::ReadAllText($Notify)
    $block = [regex]::Match($text, '(?s)\nreport\(\) \{(.*?)\n\}').Groups[1].Value
    @([regex]::Matches($block, '"([a-z_]+)=') | ForEach-Object { $_.Groups[1].Value })
}

# ---- The harness

# A 5.1 child finds its copy of the module cache where it looks for one, inside the sandbox.
Test 'harness_children_find_the_module_cache' {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        Assert-Eq '' "$ModuleCache" 'module cache copied for pwsh'
        return
    }
    if (-not $ModuleCache) { Skip-Test 'this machine has no Windows PowerShell module cache to copy' }
    $psi = New-PlayInfo @() @{}
    $psi.Arguments = '-NoProfile -NonInteractive -Command "' +
        '[Management.Automation.PSObject].Assembly.GetType(''System.Management.Automation.AnalysisCacheData'').' +
        'GetField(''cacheStoreLocation'', [Reflection.BindingFlags]''Static,NonPublic'').GetValue($null)"'
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $err = $p.StandardError.ReadToEndAsync()
    $where = $p.StandardOutput.ReadToEnd().Trim()
    $p.WaitForExit()
    Assert-Eq '' $err.Result 'stderr'
    Assert-True ($where.StartsWith($S.Dir + '\', [StringComparison]::OrdinalIgnoreCase)) "the child's module cache is not in the sandbox: [$where]"
    Assert-True ([IO.File]::Exists($where)) "the child's module cache is missing: $where"
}

Test 'report_keys_match_notify_sh' {
    $keys = Get-NotifyKeys
    Assert-Eq 20 $keys.Count 'keys found in notify.sh'
    $r = Invoke-Play -Arguments '-DryRun'
    Assert-Eq '0 ' "$($r.Rc) $($r.Err)" 'exit code and stderr'
    # Exactly one key=value line per fact, nothing else.
    $lines = @($r.Out -split "`r?`n" | Where-Object { $_ -ne '' })
    Assert-Eq 22 $lines.Count 'report lines'
    foreach ($l in $lines) { Assert-True ($l -cmatch '^[a-z_]+=') "not a key=value line: $l" }
    $rep = ConvertFrom-Report $r.Out
    Assert-Eq (($keys + 'execution_policy', 'media_player') -join ' ') (@($rep.Keys) -join ' ') 'report keys'
    Assert-Eq '1 win none' "$($rep.report) $($rep.os) $($rep.input)" 'report os input'
}

Test 'report_input_is_read_only_with_hook' {
    Assert-Eq none (Dry).input 'input without -Hook'
    foreach ($c in 'idle:stop-idle.json', 'paused:stop-background.json', 'paused:stop-crons.json') {
        $want, $fix = $c -split ':'
        $rep = Dry -Extra '-Hook' -Stdin (Get-Fixture $fix)
        Assert-Eq $want $rep.input "input for $fix"
    }
}

Test 'report_values' {
    $rep = Dry
    Assert-Eq $S.Root $rep.root 'root'
    Assert-Eq $S.Data $rep.data 'data'
    Assert-Eq '0 70 on both none 0' "$($rep.muted) $($rep.volume) $($rep.pauses) $($rep.sounds_mode) $($rep.remote) $($rep.force_local)" 'defaults'
    Assert-Eq 'ok free 0 none skip-no-clip' "$($rep.gap) $($rep.lock) $($rep.pool) $($rep.clip) $($rep.decision)" 'worker facts'
    Assert-True ($rep.execution_policy -cmatch '^(MachinePolicy|UserPolicy|Process|CurrentUser|LocalMachine):[A-Za-z]+(,[A-Za-z]+:[A-Za-z]+){4}\z') "execution_policy: $($rep.execution_policy)"
    # wmp.dll decides it, where PresentationCore loads.
    $want = 'yes'
    if ($script:NoMediaPlayer) { $want = 'no' }
    Assert-Eq $want $rep.media_player 'media_player'
    if ($rep.media_player -eq 'yes') {
        Assert-Eq 'MediaPlayer none 0.70' "$($rep.player) $($rep.fallback) $($rep.player_volume)" 'player'
        # With a WAV to fall back on, and another volume.
        Put (Join-Path $S.Data 'config') 'volume=5'
        New-Wav (Join-Path $S.Bundled 'subhanallah.wav')
        $rep = Dry
        Assert-Eq 'MediaPlayer SoundPlayer 0.05 play' "$($rep.player) $($rep.fallback) $($rep.player_volume) $($rep.decision)" 'player with a WAV'
    } else {
        Assert-Eq 'none none none' "$($rep.player) $($rep.fallback) $($rep.player_volume)" 'player, no MediaPlayer'
        Put (Join-Path $S.Data 'config') 'volume=5'
        New-Wav (Join-Path $S.Bundled 'subhanallah.wav')
        $rep = Dry
        Assert-Eq 'SoundPlayer none none play' "$($rep.player) $($rep.fallback) $($rep.player_volume) $($rep.decision)" 'player with a WAV, no MediaPlayer'
    }
}

Test 'report_dry_run_env_var_starts_nothing' {
    $psi = New-PlayInfo @('-Hook') @{ ISLAMIC_NOTIFIER_DRY_RUN = '1' }
    $p = [Diagnostics.Process]::Start($psi)
    $hookPid = $p.Id
    $p.StandardInput.Write((Get-Fixture 'stop-idle.json'))
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    Assert-Eq 0 $p.ExitCode 'exit code'
    $rep = ConvertFrom-Report $out
    Assert-Eq 'idle skip-no-clip' "$($rep.input) $($rep.decision)" 'input decision'
    Assert-Eq '' (Get-DataFiles) 'data dir files'
    # A worker would outlive the hook with the hook as its parent.
    $kids = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $hookPid")
    Assert-Eq 0 $kids.Count 'processes the dry run started'
}

Test 'report_changes_no_file' {
    $env = @{ CLAUDE_PLUGIN_DATA = $null }
    $fallback = Join-Path $S.Local 'islamic-notifier'
    $rep = Dry -Env $env
    Assert-Eq $fallback $rep.data 'data, LOCALAPPDATA fallback'
    Assert-True (-not [IO.Directory]::Exists($fallback)) 'dry run created the data dir'
    Put (Join-Path $fallback 'force-next') "$(Now) subhanallah"
    $before = [IO.File]::ReadAllText((Join-Path $fallback 'force-next'))
    $rep = Dry -Env $env
    Assert-Eq subhanallah $rep.force 'force'
    Assert-Eq $before ([IO.File]::ReadAllText((Join-Path $fallback 'force-next'))) 'force-next'
    Assert-Eq 'force-next' (@([IO.Directory]::GetFiles($fallback) | ForEach-Object { [IO.Path]::GetFileName($_) }) -join ' ') 'data dir files'
}

Test 'report_data_dir_order' {
    $other = Join-Path $S.Dir 'other data'
    Assert-Eq $S.Data (Dry -Extra '-DataDir', $other).data 'CLAUDE_PLUGIN_DATA over -DataDir'
    Assert-Eq $other (Dry -Env @{ CLAUDE_PLUGIN_DATA = $null } -Extra '-DataDir', $other).data '-DataDir over LOCALAPPDATA'
}

# ---- Config

Test 'config_bom_and_crlf' {
    $bytes = [byte[]](@(0xEF, 0xBB, 0xBF) + [Text.Encoding]::ASCII.GetBytes("muted=1`r`nvolume=40`r`npauses=off`r`nsounds_mode=custom`r`n"))
    [IO.File]::WriteAllBytes((Join-Path $S.Data 'config'), $bytes)
    $rep = Dry
    Assert-Eq '1 40 off custom' "$($rep.muted) $($rep.volume) $($rep.pauses) $($rep.sounds_mode)" 'config'
    Hook | Out-Null
    Assert-NoWorker
}

Test 'config_unknown_keys_and_bad_values_are_ignored' {
    Put (Join-Path $S.Data 'config') 'colour=blue', 'volume=abc', 'volume=150', 'volume=', 'volume=-5',
        'muted=yes', 'pauses=maybe', 'sounds_mode=all', ' volume=10', 'volume =10', 'muted',
        '# volume=20', '', 'VOLUME=30', 'Muted=1'
    $rep = Dry
    Assert-Eq '0 70 on both' "$($rep.muted) $($rep.volume) $($rep.pauses) $($rep.sounds_mode)" 'config'
}

Test 'config_last_valid_line_wins_and_zeros_are_decimal' {
    Put (Join-Path $S.Data 'config') 'volume=30', 'volume=abc', 'volume=045', 'pauses=off', 'pauses=on'
    $rep = Dry
    Assert-Eq '45 on' "$($rep.volume) $($rep.pauses)" 'volume pauses'
    [IO.File]::WriteAllText((Join-Path $S.Data 'config'), "pauses=off`nvolume=000")
    $rep = Dry
    Assert-Eq '0 off' "$($rep.volume) $($rep.pauses)" 'no final newline'
}

Test 'config_env_beats_config_beats_defaults' {
    Assert-Eq '0 70' "$((Dry).muted) $((Dry).volume)" 'defaults'
    Put (Join-Path $S.Data 'config') 'muted=1', 'volume=40'
    $rep = Dry
    Assert-Eq '1 40' "$($rep.muted) $($rep.volume)" 'config over defaults'
    Assert-Eq 0 (Dry -Env @{ ISLAMIC_NOTIFIER_MUTE = '0' }).muted 'env 0 over config 1'
    Hook -Env @{ ISLAMIC_NOTIFIER_MUTE = '0' } | Out-Null
    Assert-OneWorker '-Worker'
    Put (Join-Path $S.Data 'config') 'muted=0'
    Assert-Eq 1 (Dry -Env @{ ISLAMIC_NOTIFIER_MUTE = '1' }).muted 'env 1 over config 0'
    Assert-Eq 0 (Dry -Env @{ ISLAMIC_NOTIFIER_MUTE = 'yes' }).muted 'env not 0 or 1, config 0'
    Put (Join-Path $S.Data 'config') 'muted=1'
    Assert-Eq 1 (Dry -Env @{ ISLAMIC_NOTIFIER_MUTE = 'yes' }).muted 'env not 0 or 1, config 1'
}

# ---- force-next

Test 'force_fresh_marker_is_claimed_and_passed_on' {
    $t = Now
    Put (Join-Path $S.Data 'config') 'muted=1'
    Put (Join-Path $S.Data 'force-next') "$($t - 120) subhanallah"
    Hook -Env @{ ISLAMIC_NOTIFIER_TEST_NOW = "$t" } | Out-Null
    Assert-OneWorker '-Worker -Force subhanallah'
    Assert-Eq 'config debug.log' (Get-DataFiles) 'data dir files'
}

Test 'force_stale_marker_is_deleted' {
    $t = Now
    Put (Join-Path $S.Data 'config') 'muted=1'
    Put (Join-Path $S.Data 'force-next') "$($t - 121) *"
    Hook -Env @{ ISLAMIC_NOTIFIER_TEST_NOW = "$t" } | Out-Null
    Assert-NoWorker
    Assert-Eq 'config debug.log' (Get-DataFiles) 'data dir files'
}

Test 'force_marker_from_the_future_or_with_a_bad_epoch_is_ignored' {
    $t = Now
    Put (Join-Path $S.Data 'config') 'muted=1'
    foreach ($bad in "$($t + 1)", "0$t", '123456789012345678901234', '12a4') {
        Put (Join-Path $S.Data 'force-next') "$bad *"
        Assert-Eq none (Dry -Env @{ ISLAMIC_NOTIFIER_TEST_NOW = "$t" }).force "force for $bad"
        Hook -Env @{ ISLAMIC_NOTIFIER_TEST_NOW = "$t" } | Out-Null
        Assert-NoWorker
        Assert-True (-not [IO.File]::Exists((Join-Path $S.Data 'force-next'))) "marker $bad kept"
    }
}

Test 'force_invalid_id_becomes_any' {
    Put (Join-Path $S.Data 'force-next') "$(Now) -Path"
    Hook | Out-Null
    Assert-OneWorker '-Worker -Force *'
    Put (Join-Path $S.Data 'force-next') "$(Now) sub hanallah"
    Assert-Eq '*' (Dry).force 'force for an id with a space'
    Put (Join-Path $S.Data 'force-next') "$(Now)"
    Assert-Eq '*' (Dry).force 'force with no id'
}

Test 'force_dry_run_leaves_the_marker' {
    Put (Join-Path $S.Data 'force-next') "$(Now) subhanallah"
    $before = [IO.File]::ReadAllText((Join-Path $S.Data 'force-next'))
    Assert-Eq subhanallah (Dry).force 'force'
    Assert-Eq subhanallah (Dry).force 'force on a second dry run'
    Assert-Eq $before ([IO.File]::ReadAllText((Join-Path $S.Data 'force-next'))) 'force-next'
    Assert-Eq 'force-next' (Get-DataFiles) 'data dir files'
}

Test 'force_parameter_wins_and_keeps_the_marker' {
    Put (Join-Path $S.Data 'config') 'muted=1'
    Put (Join-Path $S.Data 'force-next') "$(Now) subhanallah"
    $before = [IO.File]::ReadAllText((Join-Path $S.Data 'force-next'))
    Hook -Extra '-Force', 'alhamdulillah' | Out-Null
    Assert-OneWorker '-Worker -Force alhamdulillah'
    Assert-Eq $before ([IO.File]::ReadAllText((Join-Path $S.Data 'force-next'))) 'force-next'
}

# ---- Mute and pauses

Test 'mute_config_env_and_volume_0_skip' {
    Put (Join-Path $S.Data 'config') 'muted=1'
    Hook | Out-Null
    Assert-NoWorker
    Assert-Eq skip-muted (Dry).decision 'decision, muted=1'
    Put (Join-Path $S.Data 'config') 'volume=0'
    Hook | Out-Null
    Assert-NoWorker
    Assert-Eq skip-volume (Dry).decision 'decision, volume=0'
    Remove-Item -LiteralPath (Join-Path $S.Data 'config')
    Hook -Env @{ ISLAMIC_NOTIFIER_MUTE = '1' } | Out-Null
    Assert-NoWorker
}

Test 'mute_volume_0_is_beaten_by_force' {
    Put (Join-Path $S.Data 'config') 'volume=0'
    Put (Join-Path $S.Data 'force-next') "$(Now) *"
    Hook | Out-Null
    Assert-OneWorker '-Worker -Force *'
}

Test 'pauses_off_with_each_fixture' {
    Put (Join-Path $S.Data 'config') 'pauses=off'
    Hook -Fixture 'stop-background.json' | Out-Null
    Hook -Fixture 'stop-crons.json' | Out-Null
    Assert-NoWorker
    Hook -Fixture 'stop-idle.json' | Out-Null
    Assert-OneWorker '-Worker'
}

Test 'pauses_on_with_each_fixture' {
    Put (Join-Path $S.Data 'config') 'pauses=on'
    foreach ($f in 'stop-idle.json', 'stop-background.json', 'stop-crons.json') { Hook -Fixture $f | Out-Null }
    Assert-Eq 3 (Get-WorkerStarts).Count 'workers started'
}

Test 'pauses_off_is_beaten_by_force' {
    Put (Join-Path $S.Data 'config') 'pauses=off'
    Put (Join-Path $S.Data 'force-next') "$(Now) la-hawla"
    Hook -Fixture 'stop-crons.json' | Out-Null
    Assert-OneWorker '-Worker -Force la-hawla'
}

Test 'pauses_malformed_json_falls_back_to_the_text_check' {
    Put (Join-Path $S.Data 'config') 'pauses=off'
    $bad = '{ "background_tasks" : [ { "id": "a" } ], oops'
    $rep = Dry -Extra '-Hook' -Stdin $bad
    Assert-Eq 'paused skip-paused' "$($rep.input) $($rep.decision)" 'malformed, one task'
    $rep = Dry -Extra '-Hook' -Stdin '{ "background_tasks" : [ ], oops'
    Assert-Eq idle $rep.input 'malformed, no task'
    $rep = Dry -Extra '-Hook' -Stdin '{"last_assistant_message":"see \"background_tasks\":[{ here"}'
    Assert-Eq idle $rep.input 'the key quoted inside a string'
    $rep = Dry -Extra '-Hook' -Stdin '{"background_tasks":{"id":"a"},"session_crons":[]}'
    Assert-Eq idle $rep.input 'an object, not an array'
}

# Inputs where the JSON check and the text check disagree: valid JSON is read as JSON.
Test 'pauses_valid_json_is_parsed_not_matched' {
    Assert-Eq paused (Dry -Extra '-Hook' -Stdin '{"background_tasks":[1]}').input 'a non-object entry'
    Assert-Eq idle (Dry -Extra '-Hook' -Stdin '{"meta":{"background_tasks":[{"id":"a"}]}}').input 'a nested key'
    Assert-Eq paused (Dry -Extra '-Hook' -Stdin '{"session_crons":[{"id":"c"}],"background_tasks":[]}').input 'crons only'
}

# ---- Remote

$RemoteCases = @(
    @('ssh', 'SSH_CONNECTION', '10.0.0.2 50000 10.0.0.1 22'),
    @('ssh', 'SSH_CLIENT', '10.0.0.2 50000 22'),
    @('ssh', 'SSH_TTY', '/dev/pts/0'),
    @('codespaces', 'CODESPACES', 'true'),
    @('devcontainer', 'REMOTE_CONTAINERS', 'true'),
    @('claude-remote', 'CLAUDE_CODE_REMOTE', 'true'),
    @('gitpod', 'GITPOD_WORKSPACE_ID', 'abc-123')
)
foreach ($c in $RemoteCases) {
    $script:Case = $c
    Test "remote_$($c[1].ToLower())_skips" {
        $reason, $name, $value = $script:Case
        Hook -Env @{ $name = $value } | Out-Null
        Assert-NoWorker
        $rep = Dry -Env @{ $name = $value }
        Assert-Eq "$reason skip-remote" "$($rep.remote) $($rep.decision)" 'remote decision'
    }
}

Test 'remote_force_local_overrides' {
    $env = @{ SSH_TTY = '/dev/pts/0'; ISLAMIC_NOTIFIER_FORCE_LOCAL = '1' }
    Hook -Env $env | Out-Null
    Assert-OneWorker '-Worker'
    $rep = Dry -Env $env
    Assert-Eq 'ssh 1 skip-no-clip' "$($rep.remote) $($rep.force_local) $($rep.decision)" 'remote force_local decision'
}

Test 'remote_values_other_than_true_do_not_skip' {
    Hook -Env @{ CODESPACES = 'false'; REMOTE_CONTAINERS = '1'; CLAUDE_CODE_REMOTE = 'TRUE' } | Out-Null
    Assert-OneWorker '-Worker'
}

# ---- The hook and its worker

Test 'hook_starts_one_worker_and_returns' {
    $r = Hook
    Assert-OneWorker '-Worker'
    Assert-True (Get-Log | Where-Object { $_ -match 'skip no-clip' }) 'the worker did not run'
    Assert-True ($r.Ms -lt 15000) "hook took $($r.Ms) ms"
}

Test 'hook_is_quiet_on_bad_input' {
    foreach ($in in '', 'not json at all', '{"background_tasks":[{') {
        $r = Invoke-Play -Arguments '-Hook' -Stdin $in
        Assert-Quiet $r
    }
    Assert-Quiet (Invoke-Play -Arguments '-Hook', '-Bogus', 'x' -Stdin '{}')
    Assert-Quiet (Invoke-Play -Arguments @())
}

# The hook's stdout and stderr must close when the hook exits, not when its worker does:
# Claude Code waits on them, and claude -p teardown kills what is still running.
Test 'hook_pipes_close_before_the_worker_ends' {
    $psi = New-PlayInfo @('-Hook') @{ ISLAMIC_NOTIFIER_TEST_HOLD_MS = '6000' }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write((Get-Fixture 'stop-idle.json'))
    $p.StandardInput.Close()
    $err = $p.StandardError.ReadToEndAsync()
    $null = $p.StandardOutput.ReadToEnd()
    $null = $err.Result
    $eof = $sw.ElapsedMilliseconds
    $ids = @(Get-WorkerPids)
    Assert-Eq 1 $ids.Count 'workers started'
    $w = $null
    try { $w = Get-Process -Id $ids[0] -ErrorAction Stop } catch { }
    Assert-True ($w -and -not $w.HasExited) "the worker had ended when the hook's pipes closed ($eof ms)"
    $null = $w.WaitForExit(20000)
    $end = $sw.ElapsedMilliseconds
    Assert-True ($eof + 2000 -lt $end) "pipes closed at $eof ms, worker ended at $end ms"
    [Console]::Error.WriteLine("  (handles: hook pipes closed at $eof ms; worker ended at $end ms)")
}

# ---- The worker

Test 'worker_held_mutex_exits_3' {
    Skip-UnlessPlayback
    Put (Join-Path $S.Data 'config') 'volume=0'
    New-Wav (Join-Path $S.Bundled 'a.wav')
    $m = New-Object Threading.Mutex($false, $S.Mutex)
    Assert-True ($m.WaitOne(0)) 'the test could not take the mutex'
    try {
        Assert-Eq 3 (Worker).Rc 'exit code with the mutex held'
        $rep = Dry -Extra '-Force', '*'
        Assert-Eq 'busy skip-busy' "$($rep.lock) $($rep.decision)" 'lock decision'
    } finally {
        $m.ReleaseMutex()
        $m.Dispose()
    }
    Assert-Eq 0 (Get-Played).Count 'clips played while busy'
    Assert-Eq 0 (Worker).Rc 'exit code once free'
    Assert-Eq 1 (Get-Played).Count 'clips played once free'
}

# Without the test seam, the mutex is the real Local\IslamicNotifier. Held for a moment only.
Test 'worker_mutex_name_is_local_islamicnotifier' {
    $m = New-Object Threading.Mutex($false, 'Local\IslamicNotifier')
    $got = $m.WaitOne(0)
    try {
        Assert-True $got 'Local\IslamicNotifier is held by another process (a real session?)'
        $rep = Dry -Env @{ ISLAMIC_NOTIFIER_TEST_MUTEX = $null } -Extra '-Force', '*'
        Assert-Eq busy $rep.lock 'lock'
    } finally {
        if ($got) { $m.ReleaseMutex() }
        $m.Dispose()
    }
}

# A worker that died holding the mutex leaves it abandoned; the next one takes it (B.2 step 1).
Test 'worker_abandoned_mutex_counts_as_taken' {
    Skip-UnlessPlayback
    Put (Join-Path $S.Data 'config') 'volume=0'
    New-Wav (Join-Path $S.Bundled 'a.wav')
    # A handle of our own keeps the mutex alive after its owner exits.
    $keep = New-Object Threading.Mutex($false, $S.Mutex)
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.Arguments = "-NoProfile -NonInteractive -Command `"`$m = New-Object Threading.Mutex(`$false, '$($S.Mutex)'); if (`$m.WaitOne(0)) { exit 0 }; exit 1`""
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $p = [Diagnostics.Process]::Start($psi)
        $p.WaitForExit()
        Assert-Eq 0 $p.ExitCode 'the owner could not take the mutex'
        Assert-Eq 0 (Worker).Rc 'exit code'
        Assert-Eq 1 (Get-Played).Count 'clips played'
    } finally {
        $keep.Dispose()
    }
}

Test 'worker_missing_file_exits_4' {
    $r = Worker -Extra '-Path', (Join-Path $S.Dir 'no such clip.wav'), '-Volume', '0'
    Assert-Eq 4 $r.Rc 'exit code'
    Assert-Eq 1 (Get-LogMatch 'failed: no such file').Count 'log'
    Assert-Eq 'debug.log' (Get-DataFiles) 'data dir files'
}

Test 'worker_gap' {
    Skip-UnlessPlayback
    $t = Now
    $env = @{ ISLAMIC_NOTIFIER_TEST_NOW = "$t" }
    Put (Join-Path $S.Data 'config') 'volume=0'
    New-Wav (Join-Path $S.Bundled 'a.wav')
    foreach ($age in 0, 1) {
        Put (Join-Path $S.Data 'last-play') "$($t - $age)"
        Assert-Eq 0 (Worker -Extra '-Force', '*' -Env $env).Rc "exit code, last play $age s ago"
    }
    Assert-Eq 0 (Get-Played).Count 'clips played inside the gap'
    $rep = Dry -Env $env -Extra '-Force', '*'
    Assert-Eq 'recent skip-gap' "$($rep.gap) $($rep.decision)" 'gap decision'
    foreach ($age in 2, 3) {
        Put (Join-Path $S.Data 'last-play') "$($t - $age)"
        Assert-Eq 0 (Worker -Extra '-Force', '*' -Env $env).Rc "exit code, last play $age s ago"
    }
    Assert-Eq 2 (Get-Played).Count 'clips played at 2 and 3 s'
    Assert-Eq "$t" (Read-Data 'last-play') 'last-play'
}

Test 'worker_empty_pool_exits_0' {
    Put (Join-Path $S.Data 'config') 'volume=0'
    Assert-Eq 0 (Worker).Rc 'exit code'
    Assert-Eq 1 (Get-LogMatch 'skip no-clip').Count 'log'
    Assert-Eq 'config debug.log' (Get-DataFiles) 'data dir files'
}

Test 'worker_pool_modes' {
    Skip-UnlessPlayback
    Put (Join-Path $S.Data 'config') 'volume=0'
    $b = Join-Path $S.Bundled 'subhanallah.wav'
    $c = Join-Path $S.Custom 'alhamdulillah.wav'
    New-Wav $b
    New-Wav $c
    Assert-Eq 2 (Dry).pool 'pool, both'
    Put (Join-Path $S.Data 'last-file') $b
    Assert-Eq 0 (Worker).Rc 'exit code'
    Remove-Item -LiteralPath (Join-Path $S.Data 'last-play')
    Assert-Eq 0 (Worker).Rc 'exit code'
    Assert-Eq "$c|$b" ((Get-Played) -join '|') 'clips, both'
    foreach ($m in @(@('bundled', $b), @('custom', $c))) {
        Put (Join-Path $S.Data 'config') 'volume=0', "sounds_mode=$($m[0])"
        $rep = Dry
        Assert-Eq "1 $($m[1])" "$($rep.pool) $($rep.clip)" "pool clip, $($m[0])"
        Remove-Item -LiteralPath (Join-Path $S.Data 'last-play')
        Assert-Eq 0 (Worker).Rc 'exit code'
        Assert-Eq $m[1] (Get-Played)[-1] "clip, $($m[0])"
    }
}

Test 'worker_never_repeats_the_last_clip' {
    Skip-UnlessPlayback
    Put (Join-Path $S.Data 'config') 'volume=0'
    # Not $s: PowerShell names ignore case, and $S is the sandbox.
    $alh = Join-Path $S.Bundled 'alhamdulillah.wav'
    $sub = Join-Path $S.Bundled 'subhanallah.wav'
    New-Wav $alh
    New-Wav $sub
    Put (Join-Path $S.Data 'last-file') $sub
    for ($i = 0; $i -lt 4; $i++) {
        $lp = Join-Path $S.Data 'last-play'
        if ([IO.File]::Exists($lp)) { Remove-Item -LiteralPath $lp }
        Assert-Eq 0 (Worker).Rc 'exit code'
    }
    Assert-Eq "$alh|$sub|$alh|$sub" ((Get-Played) -join '|') 'clips in play order'
}

Test 'worker_variants_and_the_forced_id' {
    Skip-UnlessPlayback
    Put (Join-Path $S.Data 'config') 'volume=0'
    foreach ($n in 'subhanallah.female.wav', 'subhanallah2.wav', 'alhamdulillah.wav') {
        New-Wav (Join-Path $S.Bundled $n)
    }
    $rep = Dry -Extra '-Force', 'subhanallah'
    Assert-Eq "1 $(Join-Path $S.Bundled 'subhanallah.female.wav')" "$($rep.pool) $($rep.clip)" 'pool clip'
    Assert-Eq 0 (Worker -Extra '-Force', 'subhanallah').Rc 'exit code'
    Assert-Eq (Join-Path $S.Bundled 'subhanallah.female.wav') ((Get-Played) -join '|') 'clip'
    Assert-Eq 0 (Dry -Extra '-Force', 'la-hawla').pool 'pool for an id with no clip'
}

Test 'worker_extensions_in_any_case' {
    Put (Join-Path $S.Data 'config') 'volume=0'
    foreach ($n in 'A.WAV', 'b.Mp3', 'c.ogg', 'd.wav.txt', 'wav', '.hidden.wav') {
        New-Wav (Join-Path $S.Custom $n)
    }
    $null = [IO.Directory]::CreateDirectory((Join-Path $S.Custom 'dir.wav'))
    Assert-Eq 2 (Dry).pool 'pool'
    Put (Join-Path $S.Data 'last-file') (Join-Path $S.Custom 'A.WAV')
    $null = Worker
    Assert-Eq (Join-Path $S.Custom 'b.Mp3') ((Get-Played) -join '|') 'clip'
}

Test 'worker_name_with_a_space_hash_percent_and_brackets_plays' {
    Skip-UnlessPlayback
    Put (Join-Path $S.Data 'config') 'volume=0'
    $f = Join-Path $S.Custom 'a b#c%d [1].wav'
    New-Wav $f
    Assert-Eq 0 (Worker).Rc 'exit code'
    Assert-Eq 1 (Get-LogMatch 'media ended').Count 'media ended'
    Assert-Eq $f (Read-Data 'last-file') 'last-file'
}

Test 'worker_arabic_name_plays' {
    Skip-UnlessPlayback
    Put (Join-Path $S.Data 'config') 'volume=0'
    $f = Join-Path $S.Custom ((-join [char[]](0x0633, 0x0628, 0x062D, 0x0627, 0x0646)) + '.wav')
    New-Wav $f
    Assert-Eq 0 (Worker).Rc 'exit code'
    Assert-Eq 1 (Get-LogMatch 'media ended').Count 'media ended'
    Assert-Eq $f (Read-Data 'last-file') 'last-file'
}

Test 'worker_silent_real_play_ends_and_writes_state' {
    Skip-UnlessPlayback
    Put (Join-Path $S.Data 'config') 'volume=0'
    $f = Join-Path $S.Bundled 'subhanallah.wav'
    New-Wav $f 44100
    $before = Now
    $r = Worker
    $after = Now
    Assert-Eq 0 $r.Rc 'exit code'
    $opened = @(Get-LogMatch 'media opened')
    $ended = @(Get-LogMatch 'media ended after (\d+) ms')
    Assert-Eq '1 1' "$($opened.Count) $($ended.Count)" 'media opened, media ended'
    Assert-Eq 1 (Get-LogMatch 'media open at volume 0.00').Count 'volume'
    $null = $ended[0] -match 'after (\d+) ms'
    Assert-True ([int]$Matches[1] -ge 900) "a 1 s clip ended after $($Matches[1]) ms"
    $lp = [long](Read-Data 'last-play')
    Assert-True ($lp -ge $before -and $lp -le $after) "last-play $lp is not between $before and $after"
    Assert-Eq $f (Read-Data 'last-file') 'last-file'
}

Test 'worker_mediaplayer_that_throws_falls_back_to_soundplayer' {
    Skip-UnlessMediaPlayer
    $env = @{ ISLAMIC_NOTIFIER_TEST_NO_MEDIAPLAYER = 'throw' }
    Put (Join-Path $S.Data 'config') 'volume=50'
    $f = Join-Path $S.Bundled 'subhanallah.wav'
    New-Wav $f
    Assert-Eq 0 (Worker -Env $env).Rc 'exit code'
    Assert-Eq 1 (Get-LogMatch 'media failed: MediaPlayer creation failed').Count 'media failed'
    Assert-Eq 1 (Get-LogMatch 'soundplayer played').Count 'soundplayer played'
    Assert-Eq $f (Read-Data 'last-file') 'last-file'
}

Test 'worker_soundplayer_fallback' {
    $env = @{ ISLAMIC_NOTIFIER_TEST_NO_MEDIAPLAYER = '1' }
    Put (Join-Path $S.Data 'config') 'volume=50'
    $f = Join-Path $S.Bundled 'subhanallah.wav'
    New-Wav $f
    $rep = Dry -Env $env
    Assert-Eq 'SoundPlayer none none no play' "$($rep.player) $($rep.fallback) $($rep.player_volume) $($rep.media_player) $($rep.decision)" 'report'
    Assert-Eq 0 (Worker -Env $env).Rc 'exit code'
    Assert-Eq 1 (Get-LogMatch 'media failed').Count 'media failed'
    Assert-Eq 1 (Get-LogMatch 'soundplayer played').Count 'soundplayer played'
    Assert-Eq $f (Read-Data 'last-file') 'last-file'
}

Test 'worker_soundplayer_uses_a_wav_beside_the_clip' {
    $env = @{ ISLAMIC_NOTIFIER_TEST_NO_MEDIAPLAYER = '1' }
    Put (Join-Path $S.Data 'config') 'volume=50'
    $mp3 = Join-Path $S.Custom 'la-hawla.mp3'
    $wav = Join-Path $S.Custom 'la-hawla.wav'
    Put $mp3 'not audio'
    $rep = Dry -Env $env
    Assert-Eq 'none skip-no-player' "$($rep.player) $($rep.decision)" 'report without a WAV'
    Assert-Eq 4 (Worker -Env $env).Rc 'exit code without a WAV'
    # With the WAV in the pool too, last-file makes the pick the MP3.
    New-Wav $wav
    Put (Join-Path $S.Data 'last-file') $wav
    Assert-Eq 0 (Worker -Env $env).Rc 'exit code with a WAV beside'
    Assert-Eq $mp3 ((Get-Played)[-1]) 'clip'
    Assert-Eq 1 (Get-LogMatch ([regex]::Escape("soundplayer played: $wav"))).Count 'played the WAV'
    Assert-Eq $mp3 (Read-Data 'last-file') 'last-file'
}

Test 'worker_no_soundplayer_at_volume_0' {
    $env = @{ ISLAMIC_NOTIFIER_TEST_NO_MEDIAPLAYER = '1' }
    Put (Join-Path $S.Data 'config') 'volume=0'
    New-Wav (Join-Path $S.Bundled 'subhanallah.wav')
    Assert-Eq 'none skip-no-player' "$((Dry -Env $env -Extra '-Force', '*').player) $((Dry -Env $env -Extra '-Force', '*').decision)" 'report'
    Assert-Eq 4 (Worker -Extra '-Force', '*' -Env $env).Rc 'exit code'
    Assert-Eq 0 (Get-LogMatch 'soundplayer').Count 'soundplayer ran'
    Assert-Eq 1 (Get-LogMatch 'no fallback at volume 0').Count 'log'
    Assert-Eq 'config debug.log' (Get-DataFiles) 'data dir files'
}

Test 'worker_path_skips_the_gap_the_pick_and_the_state' {
    Skip-UnlessMediaPlayer
    $t = Now
    # 1 s ago: inside the gap, and not what a play now would write.
    Put (Join-Path $S.Data 'last-play') "$($t - 1)"
    New-Wav (Join-Path $S.Bundled 'other.wav')
    $f = Join-Path $S.Dir 'from wsl.wav'
    New-Wav $f
    $r = Worker -Extra '-Path', $f, '-Volume', '20' -Env @{ ISLAMIC_NOTIFIER_TEST_NOW = "$t" }
    Assert-Eq 0 $r.Rc 'exit code'
    Assert-Eq $f ((Get-Played) -join '|') 'clip'
    Assert-Eq 1 (Get-LogMatch 'media open at volume 0.20').Count 'volume'
    Assert-Eq "$($t - 1)" (Read-Data 'last-play') 'last-play'
    Assert-Eq $null (Read-Data 'last-file') 'last-file'
}

# A relative -DataDir names the same dir for the hook and for its worker, which starts in TEMP.
Test 'worker_relative_data_dir_is_the_hooks' {
    $rel = Join-Path $S.Dir 'rel data'
    $r = Invoke-Play -Arguments '-Hook', '-DataDir', 'rel data' -Env @{ CLAUDE_PLUGIN_DATA = $null } -Stdin (Get-Fixture 'stop-idle.json')
    Assert-Quiet $r
    $start = @(Get-Log $rel | Where-Object { $_ -match 'worker started, pid (\d+)' })
    Assert-Eq 1 $start.Count 'workers started'
    $null = $start[0] -match 'worker started, pid (\d+)'
    try { $null = (Get-Process -Id ([int]$Matches[1]) -ErrorAction Stop).WaitForExit(20000) } catch { }
    Assert-Eq 1 @(Get-Log $rel | Where-Object { $_ -match 'skip no-clip' }).Count 'the worker logged in the same dir'
    Assert-Eq 0 @([IO.Directory]::GetFiles($S.Temp)).Count 'files in TEMP'
}

Test 'worker_unc_clip_is_played_from_a_temp_copy' {
    Skip-UnlessPlayback
    $f = Join-Path $S.Dir 'on a share.wav'
    New-Wav $f
    $unc = '\\?\' + $f
    Assert-Eq 0 (Worker -Extra '-Path', $unc, '-Volume', '0').Rc 'exit code'
    Assert-Eq 1 (Get-LogMatch ([regex]::Escape("copied to $($S.Temp)"))).Count 'copied to TEMP'
    Assert-Eq 1 (Get-LogMatch 'media ended').Count 'media ended'
    Assert-Eq 0 @([IO.Directory]::GetFiles($S.Temp)).Count 'files left in TEMP'
}

# The same pipe test as above, with a real, silent forced play instead of the hold seam.
Test 'hook_pipes_close_before_a_forced_silent_worker_ends' {
    Skip-UnlessPlayback
    Put (Join-Path $S.Data 'config') 'volume=0'
    Put (Join-Path $S.Data 'force-next') "$(Now) *"
    $f = Join-Path $S.Bundled 'subhanallah.wav'
    New-Wav $f (3 * 44100)
    $psi = New-PlayInfo @('-Hook') @{}
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write((Get-Fixture 'stop-idle.json'))
    $p.StandardInput.Close()
    $err = $p.StandardError.ReadToEndAsync()
    $null = $p.StandardOutput.ReadToEnd()
    $null = $err.Result
    $eof = $sw.ElapsedMilliseconds
    $ids = @(Get-WorkerPids)
    Assert-Eq 1 $ids.Count 'workers started'
    $w = $null
    try { $w = Get-Process -Id $ids[0] -ErrorAction Stop } catch { }
    Assert-True ($w -and -not $w.HasExited) "the worker had ended when the hook's pipes closed ($eof ms)"
    $null = $w.WaitForExit(30000)
    $end = $sw.ElapsedMilliseconds
    Assert-Eq $f (Read-Data 'last-file') 'last-file'
    Assert-Eq 1 (Get-LogMatch 'media ended').Count 'media ended'
    [Console]::Error.WriteLine("  (handles, real play: hook pipes closed at $eof ms; worker ended at $end ms)")
}

[Console]::Out.WriteLine("pass=$($script:Pass) fail=$($script:Fail) skip=$($script:Skip)")
if ($script:Fail -gt 0) { exit 1 }
exit 0
