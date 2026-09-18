# Self-tests for zombie-window-cleaner.
# Each test fabricates real console windows and asserts what the cleaner does with
# them. No Pester dependency, no network: plain PowerShell + real processes.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
#
# Exit code 0 = all tests passed.

$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'zombie-window-cleaner.ps1'
$work   = Join-Path $env:TEMP ('zwc-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null

$results = New-Object System.Collections.ArrayList

function Record([string]$name, [bool]$ok, [string]$detail) {
    [void]$results.Add([pscustomobject]@{ test = $name; ok = $ok; detail = $detail })
    $mark = if ($ok) { 'PASS' } else { 'FAIL' }
    Write-Host ("  {0}  {1,-46} {2}" -f $mark, $name, $detail)
}

function Write-Config([string]$name, [hashtable]$values) {
    $path = Join-Path $work "$name.json"
    ($values | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Start-FakeLauncher([string]$marker, [string]$body) {
    $bat = Join-Path $work "$marker.bat"
    "@echo off`r`n$body`r`n" | Set-Content -LiteralPath $bat -Encoding ASCII
    Start-Process -FilePath $bat -WindowStyle Minimized | Out-Null
    for ($i = 0; $i -lt 30; $i++) {
        $p = Get-FakeLauncher $marker
        if ($p) { return $p }
        Start-Sleep -Milliseconds 300
    }
    throw "fake launcher '$marker' did not start"
}

function Get-FakeLauncher([string]$marker) {
    Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" |
        Where-Object { ([string]$_.CommandLine) -match [regex]::Escape($marker) } |
        Select-Object -First 1
}

function Wait-Gone([string]$marker, [int]$seconds = 15) {
    for ($i = 0; $i -lt ($seconds * 2); $i++) {
        if (-not (Get-FakeLauncher $marker)) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Stop-Fake([string]$marker) {
    $p = Get-FakeLauncher $marker
    if ($p) {
        foreach ($c in (Get-CimInstance Win32_Process -Filter "ParentProcessId=$($p.ProcessId)")) {
            Stop-Process -Id ([int]$c.ProcessId) -Force -ErrorAction SilentlyContinue
        }
        Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue
    }
}

# Runs the cleaner with a config; reports whether that config was really loaded
# (its log file must exist afterwards).
function Invoke-Cleaner([string]$cfgPath, [string]$logPath, [switch]$DryRun) {
    if ($DryRun) { & $script -Config $cfgPath -DryRun *> $null }
    else { & $script -Config $cfgPath *> $null }
    return (Test-Path -LiteralPath $logPath)
}

Write-Host ''
Write-Host 'zombie-window-cleaner - self tests'
Write-Host ("=" * 68)

# --- T1: an orphaned launcher (nothing alive underneath) is closed ----------
$m1 = 'zwc-fake-orphan'
Start-FakeLauncher $m1 'ping -n 300 127.0.0.1 > nul' | Out-Null
$log1 = Join-Path $work 't1.log'
$cfg1 = Write-Config 't1' @{ launcherMatch = @($m1); workerProcesses = @('node.exe');
                             livenessPorts = @(); graceSeconds = 0; logFile = $log1 }
$used1 = Invoke-Cleaner $cfg1 $log1
Record 'orphaned launcher window is closed' ((Wait-Gone $m1) -and $used1) `
       ('window removed; test config used: ' + $used1)

# --- T2: a launcher that still has a live worker is kept --------------------
$m2 = 'zwc-fake-worker'
Start-FakeLauncher $m2 'powershell -NoProfile -Command "Start-Sleep -Seconds 120"' | Out-Null
Start-Sleep -Seconds 2
$log2 = Join-Path $work 't2.log'
$cfg2 = Write-Config 't2' @{ launcherMatch = @($m2); workerProcesses = @('powershell.exe');
                             livenessPorts = @(); graceSeconds = 0; logFile = $log2 }
$used2 = Invoke-Cleaner $cfg2 $log2
Record 'launcher with a live worker survives' (([bool](Get-FakeLauncher $m2)) -and $used2) `
       ('worker process detection; test config used: ' + $used2)

# --- T3: the keep-set protects the process holding the liveness port --------
$m3 = 'zwc-fake-listener'
$listen = '$l=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,45678);' +
          '$l.Start();Start-Sleep -Seconds 120'
Start-FakeLauncher $m3 ("powershell -NoProfile -Command `"$listen`"") | Out-Null
Start-Sleep -Seconds 3
$log3 = Join-Path $work 't3.log'
$cfg3 = Write-Config 't3' @{ launcherMatch = @($m3); workerProcesses = @('node.exe');
                             livenessPorts = @(45678); graceSeconds = 0; logFile = $log3 }
$used3 = Invoke-Cleaner $cfg3 $log3
Record 'live service chain (port listener) survives' (([bool](Get-FakeLauncher $m3)) -and $used3) `
       ('keep-set protection; test config used: ' + $used3)

# --- T4: the grace period protects a just-started launcher ------------------
$m4 = 'zwc-fake-grace'
Start-FakeLauncher $m4 'ping -n 300 127.0.0.1 > nul' | Out-Null
$log4 = Join-Path $work 't4.log'
$cfg4 = Write-Config 't4' @{ launcherMatch = @($m4); workerProcesses = @('node.exe');
                             livenessPorts = @(); graceSeconds = 600; logFile = $log4 }
$used4 = Invoke-Cleaner $cfg4 $log4
Record 'just-started launcher is inside the grace period' (([bool](Get-FakeLauncher $m4)) -and $used4) `
       ('graceSeconds protection; test config used: ' + $used4)

# --- T5: -DryRun reports but never kills -----------------------------------
$log5 = Join-Path $work 't5.log'
$cfg5 = Write-Config 't5' @{ launcherMatch = @($m4); workerProcesses = @('node.exe');
                             livenessPorts = @(); graceSeconds = 0; logFile = $log5 }
$used5 = Invoke-Cleaner $cfg5 $log5 -DryRun
Record '-DryRun removes nothing' (([bool](Get-FakeLauncher $m4)) -and $used5) `
       ('dry-run safety; test config used: ' + $used5)

# --- T6: the dry-run log says what it would do, the real run does it --------
$logged = $false
if (Test-Path -LiteralPath $log5) {
    $logged = ((Get-Content -LiteralPath $log5 -Raw) -match 'DRY-RUN would kill')
}
Record 'dry run is recorded in the log' $logged 'audit trail'

# --- T7: with no -Config argument the script uses the config next to it -----
# (regression guard: $PSScriptRoot is empty while param() defaults are evaluated,
#  so a default computed there silently points at nothing)
$deploy = Join-Path $work 'deploy'
New-Item -ItemType Directory -Path $deploy -Force | Out-Null
Copy-Item -LiteralPath $script -Destination (Join-Path $deploy 'zombie-window-cleaner.ps1')
$deployLog = Join-Path $deploy 'default-run.log'
$m7 = 'zwc-fake-default'
Start-FakeLauncher $m7 'ping -n 300 127.0.0.1 > nul' | Out-Null
@{ launcherMatch = @($m7); workerProcesses = @('node.exe'); livenessPorts = @();
   graceSeconds = 0; logFile = $deployLog } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $deploy 'cleanup-config.json') -Encoding UTF8
& (Join-Path $deploy 'zombie-window-cleaner.ps1') *> $null
$defaultOk = (Test-Path -LiteralPath $deployLog)
Record 'default config next to the script is used' ((Wait-Gone $m7) -and $defaultOk) `
       ('no -Config argument; log written: ' + $defaultOk)

# --- cleanup ---------------------------------------------------------------
foreach ($m in @($m1, $m2, $m3, $m4, $m7)) { Stop-Fake $m }
Start-Sleep -Seconds 1
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

$failed = @($results | Where-Object { -not $_.ok })
Write-Host ("=" * 68)
Write-Host ("RESULT: {0} ({1}/{2} passed)" -f $(if ($failed.Count -eq 0) { 'ALL PASS' } else { "$($failed.Count) FAILED" }),
            ($results.Count - $failed.Count), $results.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
