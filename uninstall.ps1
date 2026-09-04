<#
.SYNOPSIS
    Remove the AI Usage Widget: stop it, delete the Startup shortcut and the
    install directory (including state and log files).
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

$installDir = Join-Path $env:LOCALAPPDATA 'ai-usage-widget'
$widget     = Join-Path $installDir 'ai-usage-widget.ps1'
$shortcut   = Join-Path ([Environment]::GetFolderPath('Startup')) 'AI Usage Widget.lnk'
$menuLink   = Join-Path ([Environment]::GetFolderPath('Programs')) 'AI Usage Widget.lnk'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (Test-Path $widget) {
    $stopResult = & $powershell -NoProfile -ExecutionPolicy Bypass -File $widget -Stop
    Write-Output "Widget: $stopResult"
}
foreach ($path in @($shortcut, $menuLink)) {
    if (Test-Path $path) {
        Remove-Item -LiteralPath $path -Force
        Write-Output "Removed shortcut: $path"
    }
}
if (Test-Path $installDir) {
    Remove-Item -LiteralPath $installDir -Recurse -Force
    Write-Output "Removed $installDir"
}
Write-Output 'Done.'
