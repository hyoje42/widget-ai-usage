<#
.SYNOPSIS
    Always-on-top desktop widget showing remaining Claude Code / Codex usage.

.DESCRIPTION
    Reads OAuth tokens from the WSL home directory (read-only, via UNC path),
    calls the unofficial usage endpoints, and renders remaining percentage for
    the 5-hour and 7-day windows of each service.

    Requires Windows PowerShell 5.1 with -STA (WPF). See AGENTS.md for the
    architecture decisions and security rules this script must follow.

.PARAMETER FetchOnly
    Fetch usage once, print JSON to stdout (no tokens), and exit. No UI,
    no token refresh side effects.

.PARAMETER Stop
    Stop a running widget instance and exit.

.PARAMETER IntervalMinutes
    Override the fetch interval for this run (persisted to state.json).
#>
[CmdletBinding()]
param(
    [switch]$FetchOnly,
    [switch]$Stop,
    [int]$IntervalMinutes = 0
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$script:Config = @{
    WslDistro              = 'Ubuntu'
    WslUser                = 'hyoje'
    WslHome                = '\\wsl.localhost\Ubuntu\home\hyoje'
    WindowTitle            = 'AI Usage Widget'
    StateDir               = (Join-Path $env:LOCALAPPDATA 'ai-usage-widget')
    DefaultIntervalMinutes = 2
    IntervalChoices        = @(1, 2, 5, 10)
    HttpTimeoutSec         = 15
    RefreshCooldownMinutes = 15
    BarWidth               = 140.0
    ClaudeUsageUrl         = 'https://api.anthropic.com/api/oauth/usage'
    CodexUsageUrl          = 'https://chatgpt.com/backend-api/wham/usage'
}
$script:Config.ClaudeCredentials = Join-Path $script:Config.WslHome '.claude\.credentials.json'
$script:Config.CodexAuth         = Join-Path $script:Config.WslHome '.codex\auth.json'
$script:Config.StateFile         = Join-Path $script:Config.StateDir 'state.json'
$script:Config.PidFile           = Join-Path $script:Config.StateDir 'widget.pid'
$script:Config.LogFile           = Join-Path $script:Config.StateDir 'widget.log'

$script:LastRefreshAttempt = [DateTimeOffset]::MinValue

# ---------------------------------------------------------------------------
# Logging (never log tokens, emails or account ids)
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message)
    try {
        if (-not (Test-Path $script:Config.StateDir)) {
            New-Item -ItemType Directory -Path $script:Config.StateDir -Force | Out-Null
        }
        $log = $script:Config.LogFile
        if ((Test-Path $log) -and ((Get-Item $log).Length -gt 200KB)) {
            Remove-Item $log -Force
        }
        $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -Path $log -Value $line -Encoding UTF8
    } catch {
        # Logging must never break the widget.
    }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
}

function Get-HttpStatusCode {
    param($ErrorRecord)
    try {
        $resp = $ErrorRecord.Exception.Response
        if ($null -ne $resp) { return [int]$resp.StatusCode }
    } catch { }
    return 0
}

function Get-PropertyOrNull {
    # Safe property access under StrictMode for PSCustomObject results.
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function New-UsageResult {
    param([string]$Name)
    return [ordered]@{
        Name      = $Name
        Status    = 'error'     # ok | expired | error
        Message   = ''
        FiveHour  = [ordered]@{ Remaining = $null; ResetsAt = $null }
        SevenDay  = [ordered]@{ Remaining = $null; ResetsAt = $null }
        FetchedAt = $null
    }
}

function ConvertTo-Remaining {
    param($UsedPercent)
    if ($null -eq $UsedPercent) { return $null }
    $used = [double]$UsedPercent
    $remaining = [math]::Round(100.0 - $used)
    if ($remaining -lt 0) { $remaining = 0 }
    if ($remaining -gt 100) { $remaining = 100 }
    return [int]$remaining
}

function Format-Countdown {
    param($ResetsAt)
    if ($null -eq $ResetsAt) { return '' }
    $span = $ResetsAt - [DateTimeOffset]::UtcNow
    if ($span.TotalSeconds -le 0) { return 'reset' }
    if ($span.TotalDays -ge 1) {
        return ('{0}d {1}h' -f [int][math]::Floor($span.TotalDays), $span.Hours)
    }
    if ($span.TotalHours -ge 1) {
        return ('{0}h {1}m' -f $span.Hours, $span.Minutes)
    }
    if ($span.TotalMinutes -ge 1) {
        return ('{0}m' -f $span.Minutes)
    }
    return '<1m'
}

# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------
function Test-ClaudeTokenValid {
    # Returns $true when the stored access token is not yet expired.
    $cred = Read-JsonFile $script:Config.ClaudeCredentials
    $oauth = Get-PropertyOrNull $cred 'claudeAiOauth'
    if ($null -eq $oauth) { return $false }
    $expiresMs = Get-PropertyOrNull $oauth 'expiresAt'
    if ($null -eq $expiresMs) { return $false }
    $expiresAt = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$expiresMs)
    return ($expiresAt -gt [DateTimeOffset]::UtcNow.AddMinutes(1))
}

function Get-ClaudeUsage {
    $result = New-UsageResult -Name 'Claude'
    try {
        $cred = Read-JsonFile $script:Config.ClaudeCredentials
        $oauth = Get-PropertyOrNull $cred 'claudeAiOauth'
        if ($null -eq $oauth) {
            $result.Message = 'credentials not found'
            return $result
        }
        if (-not (Test-ClaudeTokenValid)) {
            $result.Status = 'expired'
            $result.Message = 'token expired'
            return $result
        }
        $headers = @{
            'Authorization'  = 'Bearer ' + $oauth.accessToken
            'anthropic-beta' = 'oauth-2025-04-20'
            'Content-Type'   = 'application/json'
        }
        $resp = Invoke-RestMethod -Uri $script:Config.ClaudeUsageUrl -Headers $headers `
            -Method Get -TimeoutSec $script:Config.HttpTimeoutSec

        $five  = Get-PropertyOrNull $resp 'five_hour'
        $seven = Get-PropertyOrNull $resp 'seven_day'
        if ($null -eq $five -or $null -eq $seven) {
            $result.Message = 'unexpected response shape'
            return $result
        }
        $result.FiveHour.Remaining = ConvertTo-Remaining (Get-PropertyOrNull $five 'utilization')
        $result.SevenDay.Remaining = ConvertTo-Remaining (Get-PropertyOrNull $seven 'utilization')
        $r5 = Get-PropertyOrNull $five 'resets_at'
        $r7 = Get-PropertyOrNull $seven 'resets_at'
        if ($r5) { $result.FiveHour.ResetsAt = [DateTimeOffset]::Parse($r5) }
        if ($r7) { $result.SevenDay.ResetsAt = [DateTimeOffset]::Parse($r7) }
        $result.Status = 'ok'
        $result.FetchedAt = [DateTimeOffset]::UtcNow
    } catch {
        $code = Get-HttpStatusCode $_
        if ($code -eq 401) {
            $result.Status = 'expired'
            $result.Message = 'token rejected (401)'
        } else {
            $result.Message = if ($code -gt 0) { "http $code" } else { $_.Exception.Message }
        }
    }
    return $result
}

function Get-CodexUsage {
    $result = New-UsageResult -Name 'Codex'
    try {
        $auth = Read-JsonFile $script:Config.CodexAuth
        $tokens = Get-PropertyOrNull $auth 'tokens'
        if ($null -eq $tokens) {
            $result.Message = 'auth not found'
            return $result
        }
        $headers = @{
            'Authorization'      = 'Bearer ' + $tokens.access_token
            'ChatGPT-Account-ID' = [string]$tokens.account_id
            'User-Agent'         = 'codex-cli'
        }
        $resp = Invoke-RestMethod -Uri $script:Config.CodexUsageUrl -Headers $headers `
            -Method Get -TimeoutSec $script:Config.HttpTimeoutSec

        $rl = Get-PropertyOrNull $resp 'rate_limit'
        $primary   = Get-PropertyOrNull $rl 'primary_window'
        $secondary = Get-PropertyOrNull $rl 'secondary_window'
        if ($null -eq $primary -or $null -eq $secondary) {
            $result.Message = 'unexpected response shape'
            return $result
        }
        $result.FiveHour.Remaining = ConvertTo-Remaining (Get-PropertyOrNull $primary 'used_percent')
        $result.SevenDay.Remaining = ConvertTo-Remaining (Get-PropertyOrNull $secondary 'used_percent')
        $r5 = Get-PropertyOrNull $primary 'reset_at'
        $r7 = Get-PropertyOrNull $secondary 'reset_at'
        if ($r5) { $result.FiveHour.ResetsAt = [DateTimeOffset]::FromUnixTimeSeconds([int64]$r5) }
        if ($r7) { $result.SevenDay.ResetsAt = [DateTimeOffset]::FromUnixTimeSeconds([int64]$r7) }
        $result.Status = 'ok'
        $result.FetchedAt = [DateTimeOffset]::UtcNow
    } catch {
        $code = Get-HttpStatusCode $_
        if ($code -eq 401) {
            $result.Status = 'expired'
            $result.Message = 'token rejected (run codex)'
        } else {
            $result.Message = if ($code -gt 0) { "http $code" } else { $_.Exception.Message }
        }
    }
    return $result
}

# ---------------------------------------------------------------------------
# Claude token refresh: only when expired, at most once per cooldown window.
# Never touches the credential file directly; lets the Claude CLI do it.
# ---------------------------------------------------------------------------
function Invoke-WslCommand {
    param([string]$BashCommand, [int]$TimeoutSec = 120)
    $argList = '-d {0} -u {1} -- bash -lc "{2}"' -f $script:Config.WslDistro, $script:Config.WslUser, $BashCommand
    $proc = Start-Process -FilePath 'wsl.exe' -ArgumentList $argList -WindowStyle Hidden -PassThru
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill() } catch { }
        return -1
    }
    return $proc.ExitCode
}

function Invoke-ClaudeTokenRefresh {
    $now = [DateTimeOffset]::UtcNow
    if (($now - $script:LastRefreshAttempt).TotalMinutes -lt $script:Config.RefreshCooldownMinutes) {
        return $false
    }
    $script:LastRefreshAttempt = $now

    Write-Log 'claude token expired; trying "claude auth status"'
    $code = Invoke-WslCommand -BashCommand 'claude auth status' -TimeoutSec 60
    Write-Log ("claude auth status exit={0}" -f $code)
    if (Test-ClaudeTokenValid) {
        Write-Log 'claude token refreshed by auth status'
        return $true
    }

    Write-Log 'still expired; sending one minimal headless message'
    $code = Invoke-WslCommand -BashCommand 'claude -p ok --model haiku' -TimeoutSec 180
    Write-Log ("claude -p exit={0}" -f $code)
    $ok = Test-ClaudeTokenValid
    Write-Log ("claude token valid after ping={0}" -f $ok)
    return $ok
}

# ---------------------------------------------------------------------------
# Service state (merged results, survives failed fetches)
# ---------------------------------------------------------------------------
function New-ServiceState {
    return @{
        Remaining5 = $null; Reset5 = $null
        Remaining7 = $null; Reset7 = $null
        UpdatedAt  = $null
        Status     = 'init'
        Message    = ''
    }
}

$script:Services = @{
    Claude = New-ServiceState
    Codex  = New-ServiceState
}

function Merge-UsageResult {
    param([hashtable]$State, $Result)
    $State.Status  = $Result.Status
    $State.Message = $Result.Message
    if ($Result.Status -eq 'ok') {
        $State.Remaining5 = $Result.FiveHour.Remaining
        $State.Reset5     = $Result.FiveHour.ResetsAt
        $State.Remaining7 = $Result.SevenDay.Remaining
        $State.Reset7     = $Result.SevenDay.ResetsAt
        $State.UpdatedAt  = $Result.FetchedAt
        return
    }
    Update-LocalResets -State $State
}

function Update-LocalResets {
    # Stale data: if a window has already reset, assume it is fully available.
    # Fresh data is left untouched because the API already reflects the reset.
    param([hashtable]$State)
    if ($State.Status -eq 'ok') { return }
    $now = [DateTimeOffset]::UtcNow
    if ($null -ne $State.Reset5 -and $State.Reset5 -le $now) { $State.Remaining5 = 100 }
    if ($null -ne $State.Reset7 -and $State.Reset7 -le $now) { $State.Remaining7 = 100 }
}

# ---------------------------------------------------------------------------
# Persistent state (window position, interval, last known values)
# ---------------------------------------------------------------------------
$script:Settings = @{
    Left            = $null
    Top             = $null
    IntervalMinutes = $script:Config.DefaultIntervalMinutes
}

function ConvertTo-IsoOrNull { param($Value) if ($null -eq $Value) { $null } else { $Value.ToString('o') } }
function ConvertFrom-IsoOrNull { param($Value) if ([string]::IsNullOrEmpty($Value)) { $null } else { [DateTimeOffset]::Parse($Value) } }

function Save-State {
    try {
        if (-not (Test-Path $script:Config.StateDir)) {
            New-Item -ItemType Directory -Path $script:Config.StateDir -Force | Out-Null
        }
        $services = @{}
        foreach ($name in $script:Services.Keys) {
            $s = $script:Services[$name]
            $services[$name] = @{
                Remaining5 = $s.Remaining5; Reset5 = (ConvertTo-IsoOrNull $s.Reset5)
                Remaining7 = $s.Remaining7; Reset7 = (ConvertTo-IsoOrNull $s.Reset7)
                UpdatedAt  = (ConvertTo-IsoOrNull $s.UpdatedAt)
            }
        }
        $state = @{
            Left            = $script:Settings.Left
            Top             = $script:Settings.Top
            IntervalMinutes = $script:Settings.IntervalMinutes
            Services        = $services
        }
        $json = $state | ConvertTo-Json -Depth 5
        Set-Content -Path $script:Config.StateFile -Value $json -Encoding UTF8
    } catch {
        Write-Log ("save state failed: {0}" -f $_.Exception.Message)
    }
}

function Load-State {
    try {
        $state = Read-JsonFile $script:Config.StateFile
        if ($null -eq $state) { return }
        $left = Get-PropertyOrNull $state 'Left'
        $top  = Get-PropertyOrNull $state 'Top'
        if ($null -ne $left) { $script:Settings.Left = [double]$left }
        if ($null -ne $top)  { $script:Settings.Top  = [double]$top }
        $iv = Get-PropertyOrNull $state 'IntervalMinutes'
        if ($null -ne $iv -and [int]$iv -gt 0) { $script:Settings.IntervalMinutes = [int]$iv }

        $services = Get-PropertyOrNull $state 'Services'
        foreach ($name in @('Claude', 'Codex')) {
            $saved = Get-PropertyOrNull $services $name
            if ($null -eq $saved) { continue }
            $s = $script:Services[$name]
            $s.Remaining5 = Get-PropertyOrNull $saved 'Remaining5'
            $s.Remaining7 = Get-PropertyOrNull $saved 'Remaining7'
            $s.Reset5     = ConvertFrom-IsoOrNull (Get-PropertyOrNull $saved 'Reset5')
            $s.Reset7     = ConvertFrom-IsoOrNull (Get-PropertyOrNull $saved 'Reset7')
            $s.UpdatedAt  = ConvertFrom-IsoOrNull (Get-PropertyOrNull $saved 'UpdatedAt')
            $s.Status     = 'stale'
            $s.Message    = 'from cache'
        }
    } catch {
        Write-Log ("load state failed: {0}" -f $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
# Process management
# ---------------------------------------------------------------------------
function Stop-ExistingInstance {
    $stopped = $false
    try {
        if (Test-Path $script:Config.PidFile) {
            $oldPid = [int](Get-Content $script:Config.PidFile -Raw).Trim()
            if ($oldPid -ne $PID) {
                $proc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
                if ($null -ne $proc -and $proc.ProcessName -like 'powershell*') {
                    Stop-Process -Id $oldPid -Force
                    $stopped = $true
                }
            }
            Remove-Item $script:Config.PidFile -Force -ErrorAction SilentlyContinue
        }
    } catch { }
    # Fallback: find by window title.
    try {
        Get-Process -Name 'powershell' -ErrorAction SilentlyContinue |
            Where-Object { $_.Id -ne $PID -and $_.MainWindowTitle -eq $script:Config.WindowTitle } |
            ForEach-Object { Stop-Process -Id $_.Id -Force; $stopped = $true }
    } catch { }
    return $stopped
}

function Write-PidFile {
    if (-not (Test-Path $script:Config.StateDir)) {
        New-Item -ItemType Directory -Path $script:Config.StateDir -Force | Out-Null
    }
    Set-Content -Path $script:Config.PidFile -Value $PID -Encoding ASCII
}

# ---------------------------------------------------------------------------
# Fetch orchestration
# ---------------------------------------------------------------------------
function Update-AllServices {
    param([switch]$AllowRefresh)

    $claude = Get-ClaudeUsage
    if ($AllowRefresh -and $claude.Status -eq 'expired') {
        if (Invoke-ClaudeTokenRefresh) {
            $claude = Get-ClaudeUsage
        }
    }
    Merge-UsageResult -State $script:Services.Claude -Result $claude

    $codex = Get-CodexUsage
    Merge-UsageResult -State $script:Services.Codex -Result $codex

    Write-Log ("fetch claude={0}{1} codex={2}{3}" -f $claude.Status,
        $(if ($claude.Message) { " ($($claude.Message))" } else { '' }),
        $codex.Status,
        $(if ($codex.Message) { " ($($codex.Message))" } else { '' }))

    return @{ Claude = $claude; Codex = $codex }
}

# ---------------------------------------------------------------------------
# Mode: -Stop
# ---------------------------------------------------------------------------
if ($Stop) {
    $stopped = Stop-ExistingInstance
    if ($stopped) { Write-Output 'stopped' } else { Write-Output 'not running' }
    exit 0
}

# ---------------------------------------------------------------------------
# Mode: -FetchOnly (no UI, no refresh side effects, no tokens in output)
# ---------------------------------------------------------------------------
if ($FetchOnly) {
    $results = Update-AllServices
    $out = [ordered]@{}
    foreach ($name in @('Claude', 'Codex')) {
        $r = $results[$name]
        $out[$name] = [ordered]@{
            status    = $r.Status
            message   = $r.Message
            five_hour = [ordered]@{
                remaining = $r.FiveHour.Remaining
                resets_at = (ConvertTo-IsoOrNull $r.FiveHour.ResetsAt)
                resets_in = (Format-Countdown $r.FiveHour.ResetsAt)
            }
            seven_day = [ordered]@{
                remaining = $r.SevenDay.Remaining
                resets_at = (ConvertTo-IsoOrNull $r.SevenDay.ResetsAt)
                resets_in = (Format-Countdown $r.SevenDay.ResetsAt)
            }
        }
    }
    $out | ConvertTo-Json -Depth 5
    exit 0
}

# ---------------------------------------------------------------------------
# Mode: widget UI
# ---------------------------------------------------------------------------
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Error 'WPF requires an STA thread. Run with: powershell.exe -STA -File ai-usage-widget.ps1'
    exit 1
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Hide the window from Alt+Tab by setting WS_EX_TOOLWINDOW.
Add-Type -Namespace WidgetNative -Name Win32 -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true)]
public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
[DllImport("user32.dll", SetLastError = true)]
public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
'@

Stop-ExistingInstance | Out-Null
Write-PidFile
Load-State
if ($IntervalMinutes -gt 0) { $script:Settings.IntervalMinutes = $IntervalMinutes }
Write-Log ("widget starting pid={0} interval={1}m" -f $PID, $script:Settings.IntervalMinutes)

$script:BrushConverter = New-Object System.Windows.Media.BrushConverter
function New-Brush { param([string]$Hex) return $script:BrushConverter.ConvertFromString($Hex) }

$script:Colors = @{
    Background = New-Brush '#E61C1C1E'
    Border     = New-Brush '#40FFFFFF'
    Text       = New-Brush '#F0F0F0'
    Dim        = New-Brush '#9A9A9A'
    Track      = New-Brush '#33FFFFFF'
    Good       = New-Brush '#4CAF50'
    Warn       = New-Brush '#FFC107'
    Bad        = New-Brush '#F44336'
    Stale      = New-Brush '#707070'
}

function New-TextBlock {
    param([string]$Text = '', $Brush, [double]$Size = 12, [string]$Weight = 'Normal',
          [string]$HAlign = 'Left', [double]$Width = 0)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.Foreground = $Brush
    $tb.FontSize = $Size
    $tb.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe UI'
    $tb.FontWeight = [System.Windows.FontWeight]::FromOpenTypeWeight($(if ($Weight -eq 'Bold') { 700 } else { 400 }))
    $tb.VerticalAlignment = 'Center'
    $tb.TextAlignment = $(if ($HAlign -eq 'Right') { 'Right' } else { 'Left' })
    if ($Width -gt 0) { $tb.Width = $Width }
    $tb.Margin = New-Object System.Windows.Thickness 0, 0, 6, 0
    return $tb
}

function Add-ToGrid {
    param($Grid, $Element, [int]$Row, [int]$Column, [int]$ColumnSpan = 1)
    [System.Windows.Controls.Grid]::SetRow($Element, $Row)
    [System.Windows.Controls.Grid]::SetColumn($Element, $Column)
    [System.Windows.Controls.Grid]::SetColumnSpan($Element, $ColumnSpan)
    $Grid.Children.Add($Element) | Out-Null
}

function New-UsageBar {
    # Returns a hashtable with the container and the fill element.
    $track = New-Object System.Windows.Controls.Border
    $track.Width = $script:Config.BarWidth
    $track.Height = 8
    $track.CornerRadius = New-Object System.Windows.CornerRadius 4
    $track.Background = $script:Colors.Track
    $track.VerticalAlignment = 'Center'
    $track.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0

    $fill = New-Object System.Windows.Controls.Border
    $fill.Height = 8
    $fill.Width = 0
    $fill.CornerRadius = New-Object System.Windows.CornerRadius 4
    $fill.HorizontalAlignment = 'Left'
    $fill.Background = $script:Colors.Stale
    $track.Child = $fill
    return @{ Track = $track; Fill = $fill }
}

# Build the layout: one grid, three rows per service, one footer row.
$grid = New-Object System.Windows.Controls.Grid
foreach ($w in @('Auto', 'Auto', 'Auto', 'Auto')) {
    $col = New-Object System.Windows.Controls.ColumnDefinition
    $col.Width = [System.Windows.GridLength]::Auto
    $grid.ColumnDefinitions.Add($col) | Out-Null
}
for ($i = 0; $i -lt 7; $i++) {
    $row = New-Object System.Windows.Controls.RowDefinition
    $row.Height = [System.Windows.GridLength]::Auto
    $grid.RowDefinitions.Add($row) | Out-Null
}

$script:Views = @{}
$rowIndex = 0
foreach ($name in @('Claude', 'Codex')) {
    $view = @{}
    $view.Name   = New-TextBlock -Text $name -Brush $script:Colors.Text -Size 13 -Weight Bold
    $view.Status = New-TextBlock -Text '' -Brush $script:Colors.Dim -Size 10 -HAlign Right
    $view.Name.Margin = New-Object System.Windows.Thickness 0, $(if ($rowIndex -eq 0) { 0 } else { 6 }), 6, 2
    $view.Status.Margin = New-Object System.Windows.Thickness 0, $(if ($rowIndex -eq 0) { 0 } else { 6 }), 0, 2
    Add-ToGrid $grid $view.Name   $rowIndex 0
    Add-ToGrid $grid $view.Status $rowIndex 1 3
    $rowIndex++

    foreach ($win in @('5h', '7d')) {
        $label = New-TextBlock -Text $win -Brush $script:Colors.Dim -Size 11 -Width 22
        $bar   = New-UsageBar
        $pct   = New-TextBlock -Text '--' -Brush $script:Colors.Text -Size 12 -HAlign Right -Width 36
        $reset = New-TextBlock -Text '' -Brush $script:Colors.Dim -Size 10 -HAlign Right -Width 58
        $reset.Margin = New-Object System.Windows.Thickness 0
        $label.Margin = New-Object System.Windows.Thickness 0, 2, 6, 2
        Add-ToGrid $grid $label     $rowIndex 0
        Add-ToGrid $grid $bar.Track $rowIndex 1
        Add-ToGrid $grid $pct       $rowIndex 2
        Add-ToGrid $grid $reset     $rowIndex 3
        $view["Fill$win"]  = $bar.Fill
        $view["Pct$win"]   = $pct
        $view["Reset$win"] = $reset
        $rowIndex++
    }
    $script:Views[$name] = $view
}
$script:Views.Footer = New-TextBlock -Text 'starting...' -Brush $script:Colors.Dim -Size 9 -HAlign Right
$script:Views.Footer.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
Add-ToGrid $grid $script:Views.Footer $rowIndex 0 4

$root = New-Object System.Windows.Controls.Border
$root.Background = $script:Colors.Background
$root.BorderBrush = $script:Colors.Border
$root.BorderThickness = New-Object System.Windows.Thickness 1
$root.CornerRadius = New-Object System.Windows.CornerRadius 8
$root.Padding = New-Object System.Windows.Thickness 12, 9, 12, 9
$root.Child = $grid

$script:Window = New-Object System.Windows.Window
$script:Window.Title = $script:Config.WindowTitle
$script:Window.WindowStyle = 'None'
$script:Window.AllowsTransparency = $true
$script:Window.Background = [System.Windows.Media.Brushes]::Transparent
$script:Window.Topmost = $true
$script:Window.ShowInTaskbar = $false
$script:Window.ResizeMode = 'NoResize'
$script:Window.SizeToContent = 'WidthAndHeight'
$script:Window.WindowStartupLocation = 'Manual'
$script:Window.Content = $root

# Initial position is applied after the first render, when ActualWidth and
# ActualHeight are known (SizeToContent). See Set-InitialPosition.
$script:HasSavedPosition = ($null -ne $script:Settings.Left -and $null -ne $script:Settings.Top)
$script:Window.Left = 0
$script:Window.Top  = 0

function Set-InitialPosition {
    $work = [System.Windows.SystemParameters]::WorkArea
    $w = $script:Window.ActualWidth
    $h = $script:Window.ActualHeight
    $margin = 12
    if ($script:HasSavedPosition) {
        $left = [double]$script:Settings.Left
        $top  = [double]$script:Settings.Top
    } else {
        $left = $work.Right - $w - $margin
        $top  = $work.Bottom - $h - $margin
    }
    # Clamp into the virtual screen so a saved position from a detached
    # monitor never leaves the widget unreachable.
    $vLeft   = [System.Windows.SystemParameters]::VirtualScreenLeft
    $vTop    = [System.Windows.SystemParameters]::VirtualScreenTop
    $vRight  = $vLeft + [System.Windows.SystemParameters]::VirtualScreenWidth
    $vBottom = $vTop + [System.Windows.SystemParameters]::VirtualScreenHeight
    if ($left + $w -gt $vRight) { $left = $vRight - $w }
    if ($top + $h -gt $vBottom) { $top = $vBottom - $h }
    if ($left -lt $vLeft) { $left = $vLeft }
    if ($top -lt $vTop) { $top = $vTop }
    $script:Window.Left = $left
    $script:Window.Top  = $top
    $script:Settings.Left = $left
    $script:Settings.Top  = $top
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------
function Get-BarBrush {
    param($Remaining, [bool]$Fresh)
    if ($null -eq $Remaining) { return $script:Colors.Stale }
    if (-not $Fresh) { return $script:Colors.Stale }
    if ($Remaining -ge 50) { return $script:Colors.Good }
    if ($Remaining -ge 20) { return $script:Colors.Warn }
    return $script:Colors.Bad
}

function Update-ServiceView {
    param([string]$Name)
    $s = $script:Services[$Name]
    $view = $script:Views[$Name]
    $fresh = ($s.Status -eq 'ok')

    foreach ($pair in @(@('5h', 'Remaining5', 'Reset5'), @('7d', 'Remaining7', 'Reset7'))) {
        $win = $pair[0]; $remaining = $s[$pair[1]]; $resetAt = $s[$pair[2]]
        $fill = $view["Fill$win"]
        if ($null -eq $remaining) {
            $fill.Width = 0
            $view["Pct$win"].Text = '--'
        } else {
            $fill.Width = [math]::Max(0.0, $script:Config.BarWidth * ([double]$remaining / 100.0))
            $view["Pct$win"].Text = ('{0}%' -f [int]$remaining)
        }
        $fill.Background = Get-BarBrush -Remaining $remaining -Fresh $fresh
        $view["Reset$win"].Text = Format-Countdown $resetAt
    }

    switch ($s.Status) {
        'ok'      { $view.Status.Text = '' }
        'expired' { $view.Status.Text = 'token expired' }
        'stale'   { $view.Status.Text = 'cached' }
        'init'    { $view.Status.Text = '' }
        default   { $view.Status.Text = 'error: ' + $s.Message }
    }
    $view.Status.Foreground = $(if ($s.Status -eq 'ok' -or $s.Status -eq 'init') { $script:Colors.Dim } else { $script:Colors.Warn })
}

function Update-View {
    Update-ServiceView 'Claude'
    Update-ServiceView 'Codex'
    $times = @()
    foreach ($name in @('Claude', 'Codex')) {
        $u = $script:Services[$name].UpdatedAt
        if ($null -ne $u) { $times += $u }
    }
    if ($times.Count -gt 0) {
        $latest = ($times | Sort-Object)[-1]
        $script:Views.Footer.Text = ('updated {0}  |  every {1}m' -f $latest.ToLocalTime().ToString('HH:mm'), $script:Settings.IntervalMinutes)
    } else {
        $script:Views.Footer.Text = ('no data yet  |  every {0}m' -f $script:Settings.IntervalMinutes)
    }
}

function Invoke-FetchAndRender {
    $script:Views.Footer.Text = 'updating...'
    # Flush the render queue so the "updating..." text is visible during the fetch.
    $script:Window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    try {
        Update-AllServices -AllowRefresh | Out-Null
    } catch {
        Write-Log ("fetch failed: {0}" -f $_.Exception.Message)
    }
    try {
        Update-View
        Save-State
    } catch {
        Write-Log ("render failed: {0}" -f $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
# Timers
# ---------------------------------------------------------------------------
$script:FetchTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:FetchTimer.Interval = [TimeSpan]::FromMinutes($script:Settings.IntervalMinutes)
$script:FetchTimer.Add_Tick({
    try { Invoke-FetchAndRender } catch { Write-Log ("fetch tick failed: {0}" -f $_.Exception.Message) }
})

$script:TickTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:TickTimer.Interval = [TimeSpan]::FromSeconds(30)
$script:TickTimer.Add_Tick({
    try {
        foreach ($name in @('Claude', 'Codex')) {
            Update-LocalResets -State $script:Services[$name]
        }
        Update-View
    } catch {
        Write-Log ("tick failed: {0}" -f $_.Exception.Message)
    }
})

function Set-FetchInterval {
    param([int]$Minutes)
    $script:Settings.IntervalMinutes = $Minutes
    $script:FetchTimer.Interval = [TimeSpan]::FromMinutes($Minutes)
    foreach ($item in $script:IntervalItems) { $item.IsChecked = ([int]$item.Tag -eq $Minutes) }
    Update-View
    Save-State
    Write-Log ("interval set to {0}m" -f $Minutes)
}

# ---------------------------------------------------------------------------
# Context menu
# ---------------------------------------------------------------------------
$menu = New-Object System.Windows.Controls.ContextMenu

$miRefresh = New-Object System.Windows.Controls.MenuItem
$miRefresh.Header = 'Refresh now'
$miRefresh.Add_Click({
    try { Invoke-FetchAndRender } catch { Write-Log ("manual refresh failed: {0}" -f $_.Exception.Message) }
})
$menu.Items.Add($miRefresh) | Out-Null

$miInterval = New-Object System.Windows.Controls.MenuItem
$miInterval.Header = 'Update interval'
$script:IntervalItems = @()
foreach ($m in $script:Config.IntervalChoices) {
    $item = New-Object System.Windows.Controls.MenuItem
    $item.Header = ('{0} min' -f $m)
    $item.Tag = $m
    $item.IsCheckable = $true
    $item.IsChecked = ($m -eq $script:Settings.IntervalMinutes)
    $item.Add_Click({
        param($sender, $e)
        try { Set-FetchInterval -Minutes ([int]$sender.Tag) } catch { Write-Log ("set interval failed: {0}" -f $_.Exception.Message) }
    })
    $miInterval.Items.Add($item) | Out-Null
    $script:IntervalItems += $item
}
$menu.Items.Add($miInterval) | Out-Null

$menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null

$miExit = New-Object System.Windows.Controls.MenuItem
$miExit.Header = 'Exit'
$miExit.Add_Click({ $script:Window.Close() })
$menu.Items.Add($miExit) | Out-Null

$root.ContextMenu = $menu

# ---------------------------------------------------------------------------
# Window events
# ---------------------------------------------------------------------------
$root.Add_MouseLeftButtonDown({
    try { $script:Window.DragMove() } catch { }
})
$root.Add_MouseLeftButtonUp({
    $script:Settings.Left = $script:Window.Left
    $script:Settings.Top  = $script:Window.Top
    Save-State
})

$script:Window.Add_SourceInitialized({
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper $script:Window
        $GWL_EXSTYLE = -20
        $WS_EX_TOOLWINDOW = 0x00000080
        $style = [WidgetNative.Win32]::GetWindowLong($helper.Handle, $GWL_EXSTYLE)
        [WidgetNative.Win32]::SetWindowLong($helper.Handle, $GWL_EXSTYLE, $style -bor $WS_EX_TOOLWINDOW) | Out-Null
    } catch { }
})

$script:Window.Add_ContentRendered({
    Set-InitialPosition
    Update-View
    Invoke-FetchAndRender
    $script:FetchTimer.Start()
    $script:TickTimer.Start()
})

$script:Window.Add_Closing({
    $script:FetchTimer.Stop()
    $script:TickTimer.Stop()
    $script:Settings.Left = $script:Window.Left
    $script:Settings.Top  = $script:Window.Top
    Save-State
    Remove-Item $script:Config.PidFile -Force -ErrorAction SilentlyContinue
    Write-Log 'widget closed'
})

# Last line of defence: log unhandled dispatcher exceptions instead of exiting.
[System.Windows.Threading.Dispatcher]::CurrentDispatcher.Add_UnhandledException({
    param($sender, $e)
    try { Write-Log ("unhandled: {0}" -f $e.Exception.Message) } catch { }
    $e.Handled = $true
})

Update-View
$script:Window.ShowDialog() | Out-Null
