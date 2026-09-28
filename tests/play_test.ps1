# Tests for plugins/islamic-notifier/scripts/play.ps1 (docs/PLAN.md, section 10). Plain
# PowerShell with no framework, for Windows PowerShell 5.1 and PowerShell 7. Prints
# "pass=N fail=M" and exits non-zero if any test fails; each failure is explained on stderr.
#
# Usage, from the repo root:
#   powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests/play_test.ps1
#
# Every test gets a sandbox whose paths contain spaces. play.ps1 runs in a child process of
# this same PowerShell, with an environment built from scratch: USERPROFILE, LOCALAPPDATA,
# APPDATA, TEMP, TMP, CLAUDE_PLUGIN_DATA and CLAUDE_PLUGIN_ROOT point into the sandbox, and
# no host variable such as SSH_* or CLAUDE_* comes through. No test is audible: a real play
# is always at volume 0, or of a WAV with no samples.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$Repo = Split-Path -Parent $PSScriptRoot
$Play = Join-Path $Repo 'plugins\islamic-notifier\scripts\play.ps1'
$Notify = Join-Path $Repo 'plugins\islamic-notifier\scripts\notify.sh'
$Fixtures = Join-Path $PSScriptRoot 'fixtures'
$Exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$script:Pass = 0
$script:Fail = 0
$script:S = $null

# The only host variables a child sees; everything else is the sandbox's.
$BaseEnvNames = @(
    'SystemRoot', 'SystemDrive', 'windir', 'ComSpec', 'PATHEXT', 'Path', 'ProgramFiles',
    'ProgramFiles(x86)', 'ProgramW6432', 'CommonProgramFiles', 'CommonProgramFiles(x86)',
    'CommonProgramW6432', 'ProgramData', 'ALLUSERSPROFILE', 'PUBLIC', 'PROCESSOR_ARCHITECTURE',
    'NUMBER_OF_PROCESSORS', 'OS', 'USERNAME', 'USERDOMAIN', 'COMPUTERNAME'
)

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
    foreach ($d in $s.Home, $s.Root, $s.Data, $s.Local, $s.AppData, $s.Temp) {
        $null = [IO.Directory]::CreateDirectory($d)
    }
    $s
}

# Wait for every worker the sandbox's debug.log names, so the sandbox can go.
function Wait-Workers {
    foreach ($id in (Get-WorkerPids)) {
        try { $null = (Get-Process -Id $id -ErrorAction Stop).WaitForExit(20000) } catch { }
    }
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

# Test NAME BODY: run BODY with a fresh sandbox in $S. A thrown error fails the test.
function Test([string]$name, [scriptblock]$body) {
    $script:S = New-Sandbox
    try {
        & $body
        $script:Pass++
    } catch {
        $script:Fail++
        [Console]::Error.WriteLine("FAIL ${name}: $($_.Exception.Message)")
    } finally {
        Wait-Workers
        Remove-Sandbox
    }
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

function Get-Log {
    $f = Join-Path $script:S.Data 'debug.log'
    if (-not [IO.File]::Exists($f)) { return @() }
    @([IO.File]::ReadAllLines($f))
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

# ---- Report

# The report's keys, as notify.sh's report() prints them, in order.
function Get-NotifyKeys {
    $text = [IO.File]::ReadAllText($Notify)
    $block = [regex]::Match($text, '(?s)\nreport\(\) \{(.*?)\n\}').Groups[1].Value
    @([regex]::Matches($block, '"([a-z_]+)=') | ForEach-Object { $_.Groups[1].Value })
}

Test 'report_keys_match_notify_sh' {
    $keys = Get-NotifyKeys
    Assert-Eq 20 $keys.Count 'keys found in notify.sh'
    $rep = Dry
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
    Assert-True ($rep.media_player -ceq 'yes' -or $rep.media_player -ceq 'no') "media_player: $($rep.media_player)"
    if ($rep.media_player -eq 'yes') {
        Assert-Eq 'MediaPlayer none 0.70' "$($rep.player) $($rep.fallback) $($rep.player_volume)" 'player'
    }
}

Test 'report_dry_run_env_var_starts_nothing' {
    $r = Invoke-Play -Arguments '-Hook' -Env @{ ISLAMIC_NOTIFIER_DRY_RUN = '1' } -Stdin (Get-Fixture 'stop-idle.json')
    Assert-Eq 0 $r.Rc 'exit code'
    $rep = ConvertFrom-Report $r.Out
    Assert-Eq 'idle skip-no-clip' "$($rep.input) $($rep.decision)" 'input decision'
    Assert-Eq '' (Get-DataFiles) 'data dir files'
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
    Assert-Eq 0 (Dry -Env @{ ISLAMIC_NOTIFIER_MUTE = 'yes' }).muted 'env not 0 or 1'
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
    Assert-True (Get-Log | Where-Object { $_ -match 'worker done' }) 'the worker did not run'
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

[Console]::Out.WriteLine("pass=$($script:Pass) fail=$($script:Fail)")
if ($script:Fail -gt 0) { exit 1 }
exit 0
