# Tests for plugins/islamic-notifier/scripts/ctl.ps1, and its parity with ctl.sh (docs/PLAN.md,
# section 10: every verb round-trips identically between the two scripts). Plain PowerShell
# with no framework, for Windows PowerShell 5.1 and PowerShell 7. Prints "pass=N fail=M
# skip=K" and exits non-zero if any test fails; each failure is explained on stderr, and each
# skip on stdout.
#
# Usage, from the repo root:
#   powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests/ctl_test.ps1
#   pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests/ctl_test.ps1
# CTL_REQUIRE_PARITY=1 (the windows CI job) makes a missing sh a failure, not a skip.
#
# Every test gets a sandbox whose paths contain spaces, with a plugin root of its own (copies
# of ctl.ps1, ctl.sh, notify.sh, play.ps1, data/adhkar.tsv and plugin.json). ctl.ps1 runs in
# a child of this same PowerShell through -EncodedCommand, as the PowerShell tool runs a
# command, with each argument quoted; ctl.sh runs under Git's sh. Both get an environment
# built from scratch: HOME, USERPROFILE, LOCALAPPDATA, APPDATA, TEMP and TMP in the sandbox.
# "sounds open" finds an explorer.exe shim first on Path; no test opens a window.
#
# Parity: from the same start, in the same sandbox, ctl.sh and then ctl.ps1 run each verb.
# Their exit codes, stdout, config bytes and data dir files must be identical, and force-next
# too, with the epochs at most 2 s apart. status must show the same facts: all its lines, but
# for the execution policies, which differ between powershell.exe and pwsh.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$Repo = Split-Path -Parent $PSScriptRoot
$Plugin = Join-Path $Repo 'plugins\islamic-notifier'
$Exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$Utf8 = New-Object Text.UTF8Encoding $false
$Latin1 = [Text.Encoding]::GetEncoding(28591)
$script:Pass = 0
$script:Fail = 0
$script:Skip = 0
$script:SkipReason = $null
$script:S = $null
$MsgTail = 'to sandbox.filesystem.allowWrite or approve the retry'

$BaseEnvNames = @(
    'SystemRoot', 'SystemDrive', 'windir', 'ComSpec', 'PATHEXT', 'Path', 'ProgramFiles',
    'ProgramFiles(x86)', 'ProgramW6432', 'CommonProgramFiles', 'CommonProgramFiles(x86)',
    'CommonProgramW6432', 'ProgramData', 'ALLUSERSPROFILE', 'PUBLIC', 'PROCESSOR_ARCHITECTURE',
    'NUMBER_OF_PROCESSORS', 'OS', 'USERNAME', 'USERDOMAIN', 'COMPUTERNAME'
)

# The 5.1 module analysis cache, copied into each sandbox where a 5.1 child looks for it (see
# tests/play_test.ps1): status and test run play.ps1 -DryRun, which would otherwise analyse
# every module on a CI runner's module path first.
$ModuleCacheName = 'Microsoft\Windows\PowerShell\ModuleAnalysisCache'
$ModuleCache = $env:PSModuleAnalysisCachePath
if (-not $ModuleCache) {
    $ModuleCache = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) $ModuleCacheName
}
if (-not [IO.File]::Exists($ModuleCache)) { $ModuleCache = $null }

# Git's sh (bin\sh.exe sets up its own PATH), or CTL_TEST_SH.
function Find-Sh {
    if ($env:CTL_TEST_SH -and [IO.File]::Exists($env:CTL_TEST_SH)) { return $env:CTL_TEST_SH }
    foreach ($g in @(Get-Command git.exe -All -ErrorAction SilentlyContinue)) {
        $dir = Split-Path -Parent $g.Source
        for ($k = 0; $k -lt 3 -and $dir; $k++) {
            $sh = Join-Path $dir 'bin\sh.exe'
            if ([IO.File]::Exists($sh)) { return $sh }
            $dir = Split-Path -Parent $dir
        }
    }
    $null
}
$GitSh = Find-Sh
$RequireParity = $env:CTL_REQUIRE_PARITY -eq '1'
[Console]::Out.WriteLine("host: PowerShell $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition), sh $(if ($GitSh) { $GitSh } else { 'none' }), " +
    "parity $(if ($RequireParity) { 'required' } else { 'optional' }), module cache $(if ($ModuleCache) { 'yes' } else { 'none' })")

# ---- Sandbox

function New-Sandbox {
    $base = Join-Path ([IO.Path]::GetTempPath()) ('ctl test ' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
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
        ShimSh  = Join-Path $dir 'shims sh'
        ShimPs  = Join-Path $dir 'shims ps'
        Log     = Join-Path $dir 'opener.log'
    }
    $s | Add-Member NoteProperty Bundled (Join-Path $s.Root 'sounds')
    $s | Add-Member NoteProperty Custom (Join-Path $s.Home '.claude\islamic-notifier\sounds')
    foreach ($d in $s.Home, $s.Data, $s.Local, $s.AppData, $s.Temp, $s.ShimSh, $s.ShimPs,
        (Join-Path $s.Root 'scripts'), (Join-Path $s.Root 'data'), (Join-Path $s.Root '.claude-plugin')) {
        $null = [IO.Directory]::CreateDirectory($d)
    }
    foreach ($f in 'ctl.ps1', 'ctl.sh', 'notify.sh', 'play.ps1') {
        [IO.File]::Copy((Join-Path $Plugin "scripts\$f"), (Join-Path $s.Root "scripts\$f"))
    }
    [IO.File]::Copy((Join-Path $Plugin 'data\adhkar.tsv'), (Join-Path $s.Root 'data\adhkar.tsv'))
    [IO.File]::Copy((Join-Path $Plugin '.claude-plugin\plugin.json'), (Join-Path $s.Root '.claude-plugin\plugin.json'))
    if ($ModuleCache) {
        try {
            $cache = Join-Path $s.Home "AppData\Local\$ModuleCacheName"
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($cache))
            [IO.File]::Copy($ModuleCache, $cache)
        } catch { }
    }
    # The openers: a script sh finds, and a .cmd PowerShell finds. Each logs its arguments.
    $logM = $s.Log.Replace('\', '/')
    [IO.File]::WriteAllText((Join-Path $s.ShimSh 'explorer.exe'), "#!/bin/sh`nprintf 'sh %s\n' `"`$*`" >> '$logM'`n")
    [IO.File]::WriteAllText((Join-Path $s.ShimPs 'explorer.exe.cmd'), "@echo ps %*>> `"$($s.Log)`"`r`n")
    $s
}

function Remove-Sandbox {
    if (-not $script:S) { return }
    for ($i = 0; $i -lt 20; $i++) {
        try {
            if ([IO.Directory]::Exists($script:S.Base)) { Remove-Item -LiteralPath $script:S.Base -Recurse -Force }
            break
        } catch {
            Start-Sleep -Milliseconds 250
        }
    }
    $script:S = $null
}

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
        Remove-Sandbox
    }
}

function Skip-Test([string]$reason) {
    $script:SkipReason = $reason
    throw "skip: $reason"
}

# Parity needs sh; the windows CI job requires it.
function Assert-Sh {
    if ($GitSh) { return }
    if ($RequireParity) { throw 'no sh (Git for Windows) found, and CTL_REQUIRE_PARITY=1' }
    Skip-Test 'no sh (Git for Windows) here'
}

# ---- Running the two scripts

function Format-Arg([string]$a) {
    if ($a -cmatch '^[A-Za-z0-9_*.:\\/=-]+\z') { return $a }
    '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Quote-Ps([string]$a) { "'" + $a.Replace("'", "''") + "'" }

function New-Info([string]$file, [string]$arguments, [hashtable]$Env, [string]$shims) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $file
    $psi.Arguments = $arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8
    $psi.StandardErrorEncoding = $Utf8
    $psi.WorkingDirectory = $script:S.Dir
    $ev = $psi.EnvironmentVariables
    $saved = @{}
    foreach ($n in $BaseEnvNames) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
    $ev.Clear()
    foreach ($n in $BaseEnvNames) { if ($null -ne $saved[$n]) { $ev[$n] = $saved[$n] } }
    if ($shims) { $ev['Path'] = "$shims;$($saved['Path'])" }
    $ev['HOME'] = $script:S.Home
    $ev['USERPROFILE'] = $script:S.Home
    $ev['LOCALAPPDATA'] = $script:S.Local
    $ev['APPDATA'] = $script:S.AppData
    $ev['TEMP'] = $script:S.Temp
    $ev['TMP'] = $script:S.Temp
    if ($Env) { foreach ($k in $Env.Keys) { $ev[$k] = [string]$Env[$k] } }
    $psi
}

function Invoke-Proc($psi) {
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $err = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEndAsync()
    if (-not $p.WaitForExit(120000)) {
        try { $p.Kill() } catch { }
        throw "$($psi.FileName) $($psi.Arguments) did not exit in 120 s"
    }
    $p.WaitForExit()
    [pscustomobject]@{ Rc = $p.ExitCode; Out = $out.Result; Err = $err.Result }
}

# Invoke-CtlPs WORDS [-Env] [-DataArg VALUE | -NoData] [-Raw TEXT]: ctl.ps1 -Data <sandbox
# data> WORDS, each word quoted; -Raw puts TEXT after them unquoted, as a person would type it.
function Invoke-CtlPs {
    param([string[]]$Words = @(), [hashtable]$Env = @{}, [string]$DataArg, [switch]$NoData, [string]$Raw)
    $ctl = Join-Path $script:S.Root 'scripts\ctl.ps1'
    $cmd = "& $(Quote-Ps $ctl)"
    if (-not $NoData) {
        $d = $script:S.Data
        if ($PSBoundParameters.ContainsKey('DataArg')) { $d = $DataArg }
        $cmd += " -Data $(Quote-Ps $d)"
    }
    foreach ($w in $Words) { $cmd += " $(Quote-Ps $w)" }
    if ($Raw) { $cmd += " $Raw" }
    # The session's own progress records (module loading) are not ctl.ps1's output, and an
    # exception out of ctl.ps1 must not read as exit 0.
    $cmd = "`$ProgressPreference = 'SilentlyContinue'; try { $cmd } catch { [Console]::Error.WriteLine(`"uncaught: `$_`"); exit 99 }; exit `$LASTEXITCODE"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    Invoke-Proc (New-Info $Exe "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $enc" $Env $script:S.ShimPs)
}

# Invoke-CtlSh WORDS [-Env] [-DataArg VALUE]: ctl.sh --data <sandbox data> WORDS under Git's sh.
function Invoke-CtlSh {
    param([string[]]$Words = @(), [hashtable]$Env = @{}, [string]$DataArg)
    $d = $script:S.Data
    if ($PSBoundParameters.ContainsKey('DataArg')) { $d = $DataArg }
    $all = @((Join-Path $script:S.Root 'scripts\ctl.sh'), '--data', $d) + $Words
    Invoke-Proc (New-Info $GitSh (($all | ForEach-Object { Format-Arg $_ }) -join ' ') $Env $script:S.ShimSh)
}

# ---- State

function Put([string]$file, [string]$text) {
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file))
    [IO.File]::WriteAllBytes($file, $Latin1.GetBytes($text))
}

# New-Wav FILE RATE DATA: a WAV header with byte rate RATE at offset 28, then DATA zero bytes.
function New-Wav([string]$file, [int]$rate, [int]$data) {
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file))
    $ms = New-Object IO.MemoryStream
    $w = New-Object IO.BinaryWriter($ms)
    $a = [Text.Encoding]::ASCII
    $w.Write($a.GetBytes('RIFF')); $w.Write([int](36 + $data)); $w.Write($a.GetBytes('WAVEfmt '))
    $w.Write([int]16); $w.Write([int16]1); $w.Write([int16]1); $w.Write([int]8000); $w.Write([int]$rate)
    $w.Write([int16]1); $w.Write([int16]8); $w.Write($a.GetBytes('data')); $w.Write([int]$data)
    $w.Write((New-Object byte[] $data))
    $w.Flush()
    [IO.File]::WriteAllBytes($file, $ms.ToArray())
}

function Clear-State {
    foreach ($d in $script:S.Data, (Join-Path $script:S.Home '.claude'), $script:S.Bundled) {
        if ([IO.Directory]::Exists($d)) { Remove-Item -LiteralPath $d -Recurse -Force }
    }
    $null = [IO.Directory]::CreateDirectory($script:S.Data)
    if ([IO.File]::Exists($script:S.Log)) { [IO.File]::Delete($script:S.Log) }
}

# What a verb can change: the data dir's files, config's bytes, force-next, the custom folder.
function Get-State {
    $names = @()
    if ([IO.Directory]::Exists($script:S.Data)) {
        $names = @([IO.Directory]::GetFileSystemEntries($script:S.Data) | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object)
    }
    $cfg = Join-Path $script:S.Data 'config'
    $fn = Join-Path $script:S.Data 'force-next'
    [pscustomobject]@{
        Files  = $names -join ' '
        Config = $(if ([IO.File]::Exists($cfg)) { [BitConverter]::ToString([IO.File]::ReadAllBytes($cfg)) } else { '<none>' })
        Force  = $(if ([IO.File]::Exists($fn)) { $Latin1.GetString([IO.File]::ReadAllBytes($fn)) } else { '<none>' })
        Custom = [IO.Directory]::Exists($script:S.Custom)
        Opened = $(if ([IO.File]::Exists($script:S.Log)) { ([IO.File]::ReadAllText($script:S.Log) -replace '^(sh|ps) ', '' -replace '"', '').Trim() } else { '<none>' })
    }
}

# ---- Asserts

function Assert-Eq($expected, $actual, [string]$what) {
    if ("$expected" -cne "$actual") { throw "${what}: expected [$expected], got [$actual]" }
}

function Assert-True($cond, [string]$what) {
    if (-not $cond) { throw $what }
}

function Now { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

# A force-next pair: the same "<epoch> <id>" line, each epoch within its own run's clock
# window. The two sides run one after the other, seconds apart, so their epochs are compared
# with each other in parity_force_next_epochs_agree, where they run at once.
function Assert-Force($a, $b, [string]$what) {
    if ($a.Force -ceq '<none>' -or $b.Force -ceq '<none>') { Assert-Eq $a.Force $b.Force "$what force-next"; return }
    foreach ($x in @(@('sh', $a), @('ps', $b))) {
        $f = $x[1].Force
        Assert-True ($f -cmatch '^([1-9][0-9]*) (\S+)\n\z') "${what}: $($x[0]) force-next [$f]"
        $t = [long]$Matches[1]
        Assert-True ($t -ge $x[1].Before -and $t -le $x[1].After) "${what}: $($x[0]) epoch $t not in $($x[1].Before)..$($x[1].After)"
    }
    Assert-Eq ($a.Force -replace '^\d+', '') ($b.Force -replace '^\d+', '') "$what force-next id"
}

# status: the same facts. Every line but the last must match, and the last's MediaPlayer.
function Assert-SameStatus([string]$a, [string]$b, [string]$what) {
    $la = @($a -split "`n" | Where-Object { $_ -ne '' })
    $lb = @($b -split "`n" | Where-Object { $_ -ne '' })
    Assert-Eq $la.Count $lb.Count "$what status lines"
    for ($i = 0; $i -lt $la.Count - 1; $i++) { Assert-Eq $la[$i] $lb[$i] "$what status line $($i + 1)" }
    $pat = '^Windows: execution policy (\S+); MediaPlayer (yes|no)\.\z'
    Assert-True ($la[-1] -cmatch $pat) "$what sh last line [$($la[-1])]"
    $ma = $Matches[2]
    Assert-True ($lb[-1] -cmatch $pat) "$what ps last line [$($lb[-1])]"
    Assert-Eq $ma $Matches[2] "$what MediaPlayer"
}

# Compare-Verb START WORDS [-Env] [-Status]: ctl.sh and then ctl.ps1 run WORDS from START.
function Compare-Verb([scriptblock]$start, [string[]]$words, [hashtable]$Env = @{}, [switch]$Status) {
    $what = "[$($words -join ' ')]"
    Clear-State; & $start
    $t0 = Now
    $a = Invoke-CtlSh $words -Env $Env
    $sa = Get-State
    $sa | Add-Member NoteProperty Before $t0
    $sa | Add-Member NoteProperty After (Now)
    Clear-State; & $start
    $t0 = Now
    $b = Invoke-CtlPs $words -Env $Env
    $sb = Get-State
    $sb | Add-Member NoteProperty Before $t0
    $sb | Add-Member NoteProperty After (Now)
    Assert-Eq $a.Rc $b.Rc "$what exit code (sh stderr: $($a.Err.Trim()); ps stderr: $($b.Err.Trim()))"
    if ($Status) { Assert-SameStatus $a.Out $b.Out $what } else { Assert-Eq $a.Out $b.Out "$what stdout" }
    Assert-Eq $sa.Files $sb.Files "$what data dir files"
    Assert-Eq $sa.Config $sb.Config "$what config bytes"
    Assert-Force $sa $sb $what
    Assert-Eq $sa.Custom $sb.Custom "$what custom folder made"
    Assert-Eq $sa.Opened $sb.Opened "$what opener calls"
    if ($a.Rc -eq 0) {
        $n = @($a.Out -split "`n" | Where-Object { $_ -ne '' }).Count
        Assert-True ($n -ge 1 -and $n -le 8) "$what gave $n lines"
        Assert-Eq '' $a.Err "$what sh stderr"
        Assert-Eq '' $b.Err "$what ps stderr"
    } else {
        Assert-Eq '' $b.Out "$what stdout when rejected"
    }
}

# ---- Starts

$Empty = {}
$Messy = {
    Put (Join-Path $script:S.Data 'config') ("$([char]0xEF)$([char]0xBB)$([char]0xBF)muted=1`r`nfoo=bar`r`nvolume=5`r`n`r`nvolume=9`r`n# volume=1`r`nvolume =3`r`npauses=off")
}
$MutedAt0 = { Put (Join-Path $script:S.Data 'config') "muted=1`nvolume=0`n" }
$Clips = {
    foreach ($n in 'salawat.wav', 'subhanallah.WAV', 'readme.txt') { Put (Join-Path $script:S.Bundled $n) '' }
    foreach ($n in 'la-hawla.Mp3', 'song.ogg', '.hidden.wav') { Put (Join-Path $script:S.Custom $n) '' }
    New-Wav (Join-Path $script:S.Custom 'long.wav') 1000 20001
    New-Wav (Join-Path $script:S.Custom 'twenty.wav') 1000 20000
    Put (Join-Path $script:S.Data 'last-file') "$(Join-Path $script:S.Custom 'long.wav')`n"
    Put (Join-Path $script:S.Data 'config') "volume=40`nsounds_mode=custom`n"
}

# ---- Parity

Test 'parity_from_an_empty_data_dir' {
    Assert-Sh
    foreach ($w in @('mute'), @('unmute'), @('volume'), @('volume', '0'), @('volume', '40'),
        @('volume', '100'), @('pauses'), @('pauses', 'on'), @('pauses', 'off'), @('sounds'),
        @('sounds', 'mode', 'both'), @('sounds', 'mode', 'bundled'), @('sounds', 'mode', 'custom'),
        @('sounds', 'list'), @('sounds', 'open'), @('test')) {
        Compare-Verb $Empty $w
    }
    Compare-Verb $Empty @('status') -Status
}

Test 'parity_every_id' {
    Assert-Sh
    foreach ($id in 'salawat', 'subhanallah', 'alhamdulillah', 'la-ilaha-illallah', 'allahu-akbar', 'la-hawla') {
        Compare-Verb $Empty @('test', $id)
    }
}

Test 'parity_from_a_bom_crlf_config_with_extra_lines' {
    Assert-Sh
    foreach ($w in @('mute'), @('unmute'), @('volume'), @('volume', '40'), @('pauses'),
        @('pauses', 'on'), @('sounds', 'mode', 'custom'), @('sounds')) {
        Compare-Verb $Messy $w
    }
    Compare-Verb $Messy @('status') -Status
}

Test 'parity_muted_at_volume_0' {
    Assert-Sh
    foreach ($w in @('unmute'), @('volume', '30'), @('volume'), @('mute')) { Compare-Verb $MutedAt0 $w }
    Compare-Verb $MutedAt0 @('status') -Status
}

Test 'parity_with_clips' {
    Assert-Sh
    foreach ($w in @('sounds', 'list'), @('test'), @('test', 'salawat'), @('test', 'la-ilaha-illallah'),
        @('sounds', 'open'), @('sounds')) {
        Compare-Verb $Clips $w
    }
    Compare-Verb $Clips @('status') -Status
}

Test 'parity_with_the_mute_env_var' {
    Assert-Sh
    $env = @{ ISLAMIC_NOTIFIER_MUTE = '1' }
    foreach ($w in @('mute'), @('unmute'), @('volume', '20')) { Compare-Verb $Empty $w -Env $env }
    Compare-Verb $Empty @('status') -Env $env -Status
}

Test 'parity_rejections_change_nothing' {
    Assert-Sh
    foreach ($w in @('volume', '101'), @('volume', '-1'), @('volume', '070'), @('volume', 'abc'),
        @('volume', ''), @('volume', '5', '6'), @('pauses', 'maybe'), @('sounds', 'mode', 'all'),
        @('sounds', 'mode'), @('sounds', 'bogus'), @('frob'), @('test', 'bogus'), @('test', 'SALAWAT'),
        @('mute', 'x'), @('status', 'x')) {
        Compare-Verb $Messy $w
        $st = Get-State
        Assert-True ($st.Config -ne '<none>') "[$($w -join ' ')] removed config"
    }
}

# Started together, each on a data dir of its own: the same force-next line, epochs at most
# 2 s apart.
Test 'parity_force_next_epochs_agree' {
    Assert-Sh
    foreach ($w in @('test'), @('test', 'allahu-akbar')) {
        $dirs = @((Join-Path $script:S.Dir 'data sh'), (Join-Path $script:S.Dir 'data ps'))
        foreach ($d in $dirs) { if ([IO.Directory]::Exists($d)) { Remove-Item -LiteralPath $d -Recurse -Force } }
        $psA = New-Info $GitSh ((@((Join-Path $script:S.Root 'scripts\ctl.sh'), '--data', $dirs[0]) + $w | ForEach-Object { Format-Arg $_ }) -join ' ') @{} $script:S.ShimSh
        $cmd = "& $(Quote-Ps (Join-Path $script:S.Root 'scripts\ctl.ps1')) -Data $(Quote-Ps $dirs[1]) $(($w | ForEach-Object { Quote-Ps $_ }) -join ' '); exit `$LASTEXITCODE"
        $psB = New-Info $Exe "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd)))" @{} $script:S.ShimPs
        $pa = [Diagnostics.Process]::Start($psA)
        $pb = [Diagnostics.Process]::Start($psB)
        foreach ($p in $pa, $pb) {
            $p.StandardInput.Close()
            $null = $p.StandardOutput.ReadToEndAsync()
            $null = $p.StandardError.ReadToEndAsync()
            Assert-True ($p.WaitForExit(120000)) "[$($w -join ' ')] did not exit"
            $p.WaitForExit()
            Assert-Eq 0 $p.ExitCode "[$($w -join ' ')] exit code"
        }
        $fa = [IO.File]::ReadAllText((Join-Path $dirs[0] 'force-next'))
        $fb = [IO.File]::ReadAllText((Join-Path $dirs[1] 'force-next'))
        Assert-True ($fa -cmatch '^(\d+) (\S+)\n\z') "sh force-next [$fa]"
        $ta = [long]$Matches[1]; $ia = $Matches[2]
        Assert-True ($fb -cmatch '^(\d+) (\S+)\n\z') "ps force-next [$fb]"
        Assert-Eq $ia $Matches[2] "[$($w -join ' ')] id"
        Assert-True ([Math]::Abs($ta - [long]$Matches[1]) -le 2) "[$($w -join ' ')] epochs $ta and $($Matches[1])"
    }
}

# Each script reads what the other wrote: config through the verbs, force-next through the
# other side's hook script (play.ps1 or notify.sh -DryRun).
Test 'parity_each_reads_the_others_writes' {
    Assert-Sh
    $r = Invoke-CtlSh 'volume', '40'
    Assert-Eq 0 $r.Rc 'sh volume 40'
    Assert-Eq 'Volume: 40 (config), on a scale of 0 to 100.' (Invoke-CtlPs 'volume').Out.Trim() 'ps reads sh'
    $r = Invoke-CtlPs 'pauses', 'off'
    Assert-Eq 0 $r.Rc 'ps pauses off'
    Assert-Eq 'Pauses: off (config): no clip when Claude stops to wait for background work.' (Invoke-CtlSh 'pauses').Out.Trim() 'sh reads ps'
    Assert-Eq 0 (Invoke-CtlSh 'test', 'salawat').Rc 'sh test salawat'
    $env = @{ CLAUDE_PLUGIN_DATA = $script:S.Data; CLAUDE_PLUGIN_ROOT = $script:S.Root }
    $play = Join-Path $script:S.Root 'scripts\play.ps1'
    $r = Invoke-Proc (New-Info $Exe "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File $(Format-Arg $play) -DryRun" $env)
    Assert-True ($r.Out -cmatch '(?m)^force=salawat\r?$') "play.ps1 after ctl.sh test: $($r.Out)"
    Assert-Eq 0 (Invoke-CtlPs 'test', 'subhanallah').Rc 'ps test subhanallah'
    $notify = Join-Path $script:S.Root 'scripts\notify.sh'
    $r = Invoke-Proc (New-Info $GitSh "$(Format-Arg $notify) --dry-run" $env)
    Assert-True ($r.Out -cmatch '(?m)^force=subhanallah$') "notify.sh after ctl.ps1 test: $($r.Out)"
}

# ---- ctl.ps1 on its own

Test 'ps_output_is_utf8_without_a_bom' {
    $r = Invoke-CtlPs 'test', 'salawat'
    Assert-Eq 0 $r.Rc 'exit code'
    $tsv = [IO.File]::ReadAllText((Join-Path $Plugin 'data\adhkar.tsv'), $Utf8)
    $arabic = ($tsv.Split("`n")[1]).Split("`t")[1]
    Assert-True ($r.Out.StartsWith("Next: $arabic`n", [StringComparison]::Ordinal)) "stdout: $($r.Out)"
}

Test 'ps_rejects_bad_data' {
    $before = Get-State
    foreach ($c in @(@('', '-Data is empty'), @('${CLAUDE_PLUGIN_DATA}', '-Data still holds ${: ${CLAUDE_PLUGIN_DATA}'),
            @("$($script:S.Dir)\x`${y}", '-Data still holds ${'))) {
        $r = Invoke-CtlPs 'volume', '5' -DataArg $c[0]
        Assert-Eq 2 $r.Rc "exit code for -Data [$($c[0])]"
        Assert-Eq '' $r.Out "stdout for -Data [$($c[0])]"
        Assert-True ($r.Err.Contains("ctl.ps1: $($c[1])") -and $r.Err.Contains('usage: ctl.ps1 -Data <dir>')) "stderr: $($r.Err)"
    }
    $r = Invoke-CtlPs 'volume', '5' -NoData
    Assert-Eq 2 $r.Rc 'exit code without -Data'
    Assert-True ($r.Err.Contains('ctl.ps1: -Data is required')) "stderr: $($r.Err)"
    $r = Invoke-CtlPs @()
    Assert-Eq 2 $r.Rc 'exit code with no verb'
    Assert-True ($r.Err.Contains('ctl.ps1: no verb')) "stderr: $($r.Err)"
    $after = Get-State
    Assert-Eq "$($before.Files) $($before.Custom)" "$($after.Files) $($after.Custom)" 'sandbox changed'
}

# The PowerShell tool reads an unquoted 070 as the number 70 before ctl.ps1 sees it.
Test 'ps_unquoted_numbers_are_read_by_powershell' {
    $r = Invoke-CtlPs 'volume' -Raw '070'
    Assert-Eq 0 $r.Rc 'exit code'
    Assert-Eq "volume=70`n" ([IO.File]::ReadAllText((Join-Path $script:S.Data 'config'))) 'config'
}

Test 'ps_write_fails_when_data_is_a_file' {
    $f = Join-Path $script:S.Dir 'a file'
    Put $f ''
    foreach ($w in @('mute'), @('volume', '5'), @('sounds', 'mode', 'custom'), @('test'), @('test', 'salawat')) {
        $r = Invoke-CtlPs $w -DataArg $f
        Assert-Eq 1 $r.Rc "exit code for $w"
        Assert-Eq '' $r.Out "stdout for $w"
        Assert-Eq "config not writable (sandbox?) - add $f $MsgTail" $r.Err.Trim() "stderr for $w"
        Assert-Eq 0 ([IO.FileInfo]$f).Length "the file was written for $w"
    }
}

# Denials by icacls, each removed afterwards. Each side is its own test and probes the denial
# its own way first: a process that can still get past it (Git's sh in an elevated session,
# where Cygwin opens files with backup privileges) skips, with the reason.

# $true if Git's sh, in the sandbox environment, can run SCRIPT with $1 = ARG.
function Test-ShCan([string]$script, [string]$arg) {
    $r = Invoke-Proc (New-Info $GitSh ((@('-c', $script, '_', $arg) | ForEach-Object { Format-Arg $_ }) -join ' ') @{} $null)
    $r.Rc -eq 0
}

# Invoke-Denied TARGET RIGHTS BODY: BODY with an icacls deny of RIGHTS on TARGET for this user.
function Invoke-Denied([string]$target, [string]$rights, [scriptblock]$body) {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $out = & icacls.exe $target /deny "${user}:($rights)" 2>&1
    Assert-Eq 0 $LASTEXITCODE "icacls /deny: $out"
    try {
        & $body
    } finally {
        $null = & icacls.exe $target /remove:d $user 2>&1
    }
}

# A data dir this user may not add files to: a deny of write data and append data on the dir
# alone. The config and the data dir's files stay as they were.
function Test-DeniedDir([string]$side) {
    Put (Join-Path $script:S.Data 'config') "volume=10`n"
    Invoke-Denied $script:S.Data 'WD,AD' {
        if ($side -eq 'ps') {
            $can = $true
            try { [IO.File]::WriteAllText((Join-Path $script:S.Data 'probe'), '') } catch { $can = $false }
            if ($can) { Skip-Test 'this user can still add files to the data dir after an icacls deny' }
        } elseif (Test-ShCan 'true > "$1/probe" && rm -f "$1/probe"' $script:S.Data) {
            Skip-Test "Git's sh can still add files to the data dir after an icacls deny (an elevated session: Cygwin opens files with backup privileges)"
        }
        foreach ($w in @('volume', '40'), @('test')) {
            if ($side -eq 'ps') { $r = Invoke-CtlPs $w } else { $r = Invoke-CtlSh $w }
            Assert-Eq 1 $r.Rc "$side exit code for $w"
            Assert-Eq "config not writable (sandbox?) - add $($script:S.Data) $MsgTail" $r.Err.Trim() "$side stderr for $w"
        }
    }
    Assert-Eq "volume=10`n" ([IO.File]::ReadAllText((Join-Path $script:S.Data 'config'))) 'config'
    Assert-Eq 'config' (@([IO.Directory]::GetFileSystemEntries($script:S.Data) | ForEach-Object { [IO.Path]::GetFileName($_) }) -join ' ') 'data dir files'
}

# A config this user may not read (a deny of read data) is not rewritten, which would lose
# its other lines.
function Test-UnreadableConfig([string]$side) {
    $cfg = Join-Path $script:S.Data 'config'
    Put $cfg "volume=10`nfoo=bar`n"
    Invoke-Denied $cfg 'RD' {
        if ($side -eq 'ps') {
            $can = $true
            try { $null = [IO.File]::ReadAllBytes($cfg) } catch { $can = $false }
            if ($can) { Skip-Test 'this user can still read the config after an icacls deny' }
        } elseif (Test-ShCan 'true < "$1"' $cfg) {
            Skip-Test "Git's sh can still read the config after an icacls deny (an elevated session: Cygwin opens files with backup privileges)"
        }
        if ($side -eq 'ps') { $r = Invoke-CtlPs 'volume', '40' } else { $r = Invoke-CtlSh 'volume', '40' }
        Assert-Eq 1 $r.Rc "$side exit code"
        Assert-Eq "config not writable (sandbox?) - add $($script:S.Data) $MsgTail" $r.Err.Trim() "$side stderr"
    }
    Assert-Eq "volume=10`nfoo=bar`n" ([IO.File]::ReadAllText($cfg)) 'config'
}

Test 'ps_write_fails_on_an_icacls_deny' { Test-DeniedDir 'ps' }
Test 'sh_write_fails_on_an_icacls_deny' { Assert-Sh; Test-DeniedDir 'sh' }
Test 'ps_write_refuses_an_unreadable_config' { Test-UnreadableConfig 'ps' }
Test 'sh_write_refuses_an_unreadable_config' { Assert-Sh; Test-UnreadableConfig 'sh' }

Test 'ps_bom_and_crlf_in_clean_out' {
    & $Messy
    $r = Invoke-CtlPs 'volume', '40'
    Assert-Eq 0 $r.Rc 'exit code'
    Assert-Eq "muted=1`nfoo=bar`nvolume=40`n`n# volume=1`nvolume =3`npauses=off`n" ([IO.File]::ReadAllText((Join-Path $script:S.Data 'config'))) 'config'
}

[Console]::Out.WriteLine("pass=$($script:Pass) fail=$($script:Fail) skip=$($script:Skip)")
if ($script:Fail -gt 0) { exit 1 }
exit 0
