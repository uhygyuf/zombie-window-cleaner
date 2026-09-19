<#
.SYNOPSIS
    Installs or removes the scheduled task that runs zombie-window-cleaner.

.DESCRIPTION
    Registers a Windows scheduled task that runs the cleaner in the background at a
    fixed interval (default: every 15 minutes), so orphaned console windows are
    cleaned up without anyone thinking about it.

    Use -Uninstall to remove the task again. Nothing is written to the registry and
    no files are copied: the task simply runs the script where it lives.

.PARAMETER IntervalMinutes
    How often to run the cleaner (default 15).

.PARAMETER TaskName
    Name of the scheduled task (default "zombie window cleaner").

.PARAMETER Config
    Config file the task should pass to the script.

.PARAMETER Uninstall
    Remove the scheduled task instead of creating it.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install.ps1 -IntervalMinutes 5

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [int]$IntervalMinutes = 15,
    [string]$TaskName = 'zombie window cleaner',
    [string]$Config = '',
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$script = Join-Path $scriptDir 'zombie-window-cleaner.ps1'

if (-not (Test-Path -LiteralPath $script)) {
    throw "Cannot find the cleaner next to this installer: $script"
}

if ($Uninstall) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-Host "Task '$TaskName' is not installed - nothing to remove."
        return
    }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed scheduled task '$TaskName'."
    return
}

# Run through the windowless VBS launcher: on Windows 11 (where Windows Terminal is the
# default terminal host) "powershell -WindowStyle Hidden" still flashes a terminal window on
# every run - one window per interval, forever. wscript has no console of its own and hides
# the child's console window, so the task stays invisible.
$runner = Join-Path $scriptDir 'hidden-runner.vbs'
if (-not (Test-Path -LiteralPath $runner)) { throw "hidden-runner.vbs is missing next to this installer: $runner" }
$parts = @('"{0}"' -f $runner, '"{0}"' -f $script)
if ($Config) {
    if (-not (Test-Path -LiteralPath $Config)) { throw "Config not found: $Config" }
    $parts += '-Config'
    $parts += '"{0}"' -f (Resolve-Path -LiteralPath $Config).Path
}
$arguments = $parts -join ' '

$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument $arguments
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
                                   -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                                         -StartWhenAvailable -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
                       -Settings $settings -Description `
                       'Closes orphaned console windows left behind by service launchers.' `
                       -Force | Out-Null

Write-Host "Installed scheduled task '$TaskName' - runs every $IntervalMinutes minute(s)."
Write-Host "  script : $script"
if ($Config) { Write-Host "  config : $Config" }
Write-Host ''
Write-Host 'Run it once now with:  Start-ScheduledTask -TaskName "' + $TaskName + '"'
Write-Host 'Check results in   :  <script folder>\cleanup.log'
Write-Host 'Remove it with     :  .\install.ps1 -Uninstall'
