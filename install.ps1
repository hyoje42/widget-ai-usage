<#
.SYNOPSIS
    Install or update the AI Usage Widget for the current Windows user.

.DESCRIPTION
    Idempotent. Copies the widget script to %LOCALAPPDATA%\ai-usage-widget,
    registers a Startup shortcut so the widget launches at login, stops any
    running instance, and starts the freshly installed version.

.PARAMETER NoStart
    Install without launching the widget.
#>
[CmdletBinding()]
param(
    [switch]$NoStart
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$source     = $PSScriptRoot
$installDir = Join-Path $env:LOCALAPPDATA 'ai-usage-widget'
$widget     = Join-Path $installDir 'ai-usage-widget.ps1'
$startup    = [Environment]::GetFolderPath('Startup')
$programs   = [Environment]::GetFolderPath('Programs')
$icon       = Join-Path $installDir 'ai-usage-widget.ico'
$shortcut   = Join-Path $startup 'AI Usage Widget.lnk'
$menuLink   = Join-Path $programs 'AI Usage Widget.lnk'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$launchArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "{0}"' -f $widget
# Shortcuts stay without -Force so clicking one while the widget runs is a
# no-op; only this installer replaces a running instance.
$startArgs  = '{0} -Force' -f $launchArgs

Write-Output "Source:  $source"
Write-Output "Install: $installDir"

if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}

# Stop the running instance before overwriting the script.
if (Test-Path $widget) {
    $stopResult = & $powershell -NoProfile -ExecutionPolicy Bypass -File $widget -Stop
    Write-Output "Previous instance: $stopResult"
}

foreach ($file in @('ai-usage-widget.ps1', 'uninstall.ps1', 'ai-usage-widget.ico')) {
    Copy-Item -LiteralPath (Join-Path $source $file) -Destination (Join-Path $installDir $file) -Force
    Write-Output "Copied:  $file"
}

# Shortcuts (overwritten on every install so argument changes propagate):
# one in Startup for auto-launch at login, one in the Start Menu so the
# widget can be found by typing its name. Clicking one while the widget
# already runs does nothing, since neither carries -Force.
$shell = New-Object -ComObject WScript.Shell
foreach ($path in @($shortcut, $menuLink)) {
    $lnk = $shell.CreateShortcut($path)
    $lnk.TargetPath = $powershell
    $lnk.Arguments = $launchArgs
    $lnk.WorkingDirectory = $installDir
    $lnk.WindowStyle = 7   # Minimized; the console is hidden by -WindowStyle Hidden anyway.
    $lnk.Description = 'AI Usage Widget (Claude Code / Codex remaining usage)'
    if (Test-Path $icon) { $lnk.IconLocation = "$icon,0" }
    $lnk.Save()
    Write-Output "Shortcut: $path"
}

if (-not $NoStart) {
    Start-Process -FilePath $powershell -ArgumentList $startArgs -WorkingDirectory $installDir -WindowStyle Hidden
    Write-Output 'Started widget.'
}
Write-Output 'Done.'
