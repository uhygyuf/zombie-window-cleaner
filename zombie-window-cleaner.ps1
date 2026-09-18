<#
.SYNOPSIS
    Closes orphaned console windows left behind by long-running service launchers.

.DESCRIPTION
    Windows launcher scripts (.bat/.cmd) that start a service and then exit - or that
    end with "pause" - leave their console window behind forever once the service
    dies. Restart such a launcher a few times and the taskbar fills with dead windows.

    This script finds those windows and closes them, while never touching the
    launcher that currently owns the running service. Two independent safety nets
    protect the live instance:

      1. KEEP-SET  - the process listening on each configured liveness port, plus
                     every ancestor of that process, is never touched.
      2. WORKERS   - a launcher window is only a candidate when nothing in its
                     process tree is a configured worker process (node.exe,
                     cloudflared.exe, python.exe, ...).

    A launcher is matched by its command line (default: the configured patterns) or
    by its window title.

.PARAMETER Config
    Path to a JSON config file. Missing keys fall back to the built-in defaults.

.PARAMETER DryRun
    Report what would be killed without killing anything.

.PARAMETER LogFile
    Override the log path from the config.

.EXAMPLE
    .\zombie-window-cleaner.ps1 -DryRun -Verbose

.EXAMPLE
    .\zombie-window-cleaner.ps1 -Config .\my-config.json

.NOTES
    Tested on Windows 10/11 with Windows PowerShell 5.1 and PowerShell 7.
    Never name a parameter $pid in PowerShell: it collides with the automatic
    variable and silently gives your functions the wrong process id.
#>
[CmdletBinding()]
param(
    [string]$Config = '',
    [switch]$DryRun,
    [string]$LogFile
)

$ErrorActionPreference = 'SilentlyContinue'

# $PSScriptRoot is not reliably populated while param() defaults are evaluated,
# so resolve the script directory (and the default config path) here instead.
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Config) { $Config = Join-Path $scriptDir 'cleanup-config.json' }

# ---------------------------------------------------------------- configuration
$defaults = [ordered]@{
    launcherMatch    = @('n8n-serve', 'n8n start', 'start-public')
    workerProcesses  = @('node.exe', 'cloudflared.exe')
    livenessPorts    = @(5678)
    graceSeconds     = 60
    logFile          = (Join-Path $scriptDir 'cleanup.log')
    maxLogBytes      = 204800
}

$cfg = New-Object System.Collections.Specialized.OrderedDictionary
foreach ($k in @($defaults.Keys)) { $cfg[$k] = $defaults[$k] }

if (Test-Path -LiteralPath $Config) {
    try {
        $user = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json
        foreach ($k in @($defaults.Keys)) {
            if ($null -ne $user.$k) { $cfg[$k] = $user.$k }
        }
    } catch {
        Write-Warning "Could not read config '$Config': $($_.Exception.Message). Using defaults."
    }
} else {
    Write-Warning "Config '$Config' not found - using built-in defaults."
}
if ($LogFile) { $cfg['logFile'] = $LogFile }

function Write-Log([string]$Message) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    if ($VerbosePreference -ne 'SilentlyContinue') { Write-Verbose $line }
    $path = $cfg['logFile']
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Length -gt $cfg['maxLogBytes'])) {
        Get-Content -LiteralPath $path -Tail 200 | Set-Content -LiteralPath $path
    }
    Add-Content -LiteralPath $path -Value $line -Encoding UTF8
}

function Get-ChildProcesses([int]$RootId) {
    $out = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($RootId)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        foreach ($child in (Get-CimInstance Win32_Process -Filter "ParentProcessId=$current")) {
            [void]$out.Add($child)
            $queue.Enqueue([int]$child.ProcessId)
        }
    }
    return ,$out
}

# ---------------------------------------------------------------- safety net 1
$keep = New-Object System.Collections.ArrayList
foreach ($port in $cfg['livenessPorts']) {
    $listener = (Get-NetTCPConnection -LocalPort ([int]$port) -State Listen |
                 Select-Object -First 1).OwningProcess
    if ($listener) {
        $cursor = [int]$listener
        while ($cursor -gt 0) {
            if ($keep -contains $cursor) { break }
            [void]$keep.Add($cursor)
            $parent = (Get-CimInstance Win32_Process -Filter "ProcessId=$cursor").ParentProcessId
            if (-not $parent) { break }
            $cursor = [int]$parent
        }
    }
}
if ($keep.Count -gt 0) { Write-Log ("keep-set (live chain): " + ($keep -join ',')) }

# ---------------------------------------------------------------- candidates
$pattern = ($cfg['launcherMatch'] | ForEach-Object { [regex]::Escape([string]$_) }) -join '|'
$candidates = Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" | Where-Object {
    $cmdLine = [string]$_.CommandLine
    $title = [string](Get-Process -Id ([int]$_.ProcessId) -ErrorAction SilentlyContinue).MainWindowTitle
    ($cmdLine -match $pattern) -or ($title -match $pattern)
}

$killed = 0
$skipped = 0
foreach ($candidate in $candidates) {
    $candidateId = [int]$candidate.ProcessId
    $why = $null

    if ($keep -contains $candidateId) { $why = 'in keep-set (live service chain)' }
    else {
        $descendants = Get-ChildProcesses $candidateId
        $descendantIds = @($descendants | ForEach-Object { [int]$_.ProcessId })
        if (@($descendantIds | Where-Object { $keep -contains $_ }).Count -gt 0) {
            $why = 'descendant belongs to the keep-set'
        } else {
            # safety net 2
            $workers = @($descendants | Where-Object { $cfg['workerProcesses'] -contains $_.Name })
            if ($workers.Count -gt 0) { $why = "alive: worker process $($workers[0].Name)" }
            else {
                $age = ((Get-Date) - $candidate.CreationDate).TotalSeconds
                if ($age -lt [double]$cfg['graceSeconds']) {
                    $why = "started {0:N0}s ago (within grace period)" -f $age
                } else {
                    if ($DryRun) {
                        Write-Log "DRY-RUN would kill launcher window PID $candidateId"
                        Write-Host "would kill: PID $candidateId"
                    } else {
                        foreach ($d in $descendants) { Stop-Process -Id ([int]$d.ProcessId) -Force }
                        Stop-Process -Id $candidateId -Force
                        Write-Log "killed orphaned launcher window PID $candidateId"
                        Write-Host "killed: PID $candidateId"
                    }
                    $killed++
                    continue
                }
            }
        }
    }
    $skipped++
    Write-Log "kept PID $candidateId - $why"
}

if ($killed -eq 0) { Write-Log "scan complete: no orphaned launcher windows ($skipped checked)" }
else { Write-Log "scan complete: removed $killed orphaned window(s), $skipped kept" }

if ($DryRun) { Write-Host "dry run: $skipped kept, $killed would be removed" }
