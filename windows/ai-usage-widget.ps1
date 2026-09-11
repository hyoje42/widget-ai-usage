<#
.SYNOPSIS
    Always-on-top desktop widget showing remaining Claude Code / Codex usage.

.DESCRIPTION
    Reads OAuth tokens read-only from wherever each CLI keeps them (a WSL home
    over a UNC path, or the Windows user profile), calls the unofficial usage
    endpoints, and renders remaining percentage for the 5-hour and 7-day
    windows of each service.

    No host detail is hardcoded: the token locations are detected on first run
    and cached in config.json next to the state file.

    Requires Windows PowerShell 5.1 with -STA (WPF). See AGENTS.md for the
    architecture decisions and security rules this script must follow.

.PARAMETER FetchOnly
    Fetch usage once, print JSON to stdout (no tokens), and exit. No UI,
    no token refresh side effects.

.PARAMETER Stop
    Stop a running widget instance and exit.

.PARAMETER IntervalMinutes
    Override the fetch interval for this run (persisted to state.json).

.PARAMETER Force
    Replace a running instance instead of exiting. Without it, launching the
    widget while it already runs is a no-op, so repeated Start Menu clicks do
    not restart it (each restart fetches immediately and can trip HTTP 429).

.PARAMETER Configure
    Detect where each service keeps its tokens, write the result to config.json,
    print it and exit. Run it after installing on a new machine, or whenever the
    CLIs move (a different WSL distribution, a switch to a Windows install).

.PARAMETER WslDistro
    Name of the WSL distribution holding the CLI tokens. Detected when omitted.

.PARAMETER WslUser
    Linux user whose home holds the CLI tokens. Detected when omitted.
#>
[CmdletBinding()]
param(
    [switch]$FetchOnly,
    [switch]$Stop,
    [int]$IntervalMinutes = 0,
    [switch]$Force,
    [switch]$Configure,
    [string]$WslDistro = '',
    [string]$WslUser = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$script:Config = @{
    WindowTitle            = 'AI Usage Widget'
    StateDir               = (Join-Path $env:LOCALAPPDATA 'ai-usage-widget')
    DefaultIntervalMinutes = 5
    IntervalChoices        = @(2, 5, 10)
    # Window transparency in percent. 0 is fully opaque; the highest choice
    # still has to stay readable over a bright desktop background.
    DefaultTransparency    = 0
    TransparencyChoices    = @(0, 15, 30, 45)
    HttpTimeoutSec         = 15
    RefreshCooldownMinutes = 15
    # After an HTTP 429 a service is skipped for this long, doubling per repeat.
    # Timers fire a little early; a fetch due within the slack is not skipped.
    BackoffMinMinutes      = 10
    BackoffMaxMinutes      = 30
    BackoffSlackSeconds    = 30
    BarWidth               = 150.0
    BarHeight              = 14.0
    LowRemaining           = 20
    # 리셋 카운트다운 색상 임계값(분). 창마다 전체 주기가 달라 따로 잡습니다.
    #   Soon 이하 -> 초록, Far 초과 -> 빨강, 그 사이 -> 기본 텍스트 색.
    ResetThresholds        = @{
        '5h' = @{ Soon = 30;  Far = 120 }   # 30분 / 2시간
        '7d' = @{ Soon = 720; Far = 4320 }  # 12시간 / 3일
    }
    ClaudeUsageUrl         = 'https://api.anthropic.com/api/oauth/usage'
    CodexUsageUrl          = 'https://chatgpt.com/backend-api/wham/usage'
}
$script:Config.ConfigFile        = Join-Path $script:Config.StateDir 'config.json'
$script:Config.StateFile         = Join-Path $script:Config.StateDir 'state.json'
$script:Config.PidFile           = Join-Path $script:Config.StateDir 'widget.pid'
$script:Config.LogFile           = Join-Path $script:Config.StateDir 'widget.log'

$script:LastRefreshAttempt = @{
    Claude = [DateTimeOffset]::MinValue
    Codex  = [DateTimeOffset]::MinValue
}

# HTTP 429 backoff per service: no fetch before Until; Minutes is the last delay.
$script:Backoff = @{
    Claude = @{ Until = [DateTimeOffset]::MinValue; Minutes = 0 }
    Codex  = @{ Until = [DateTimeOffset]::MinValue; Minutes = 0 }
}

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
function Test-PathSafe {
    # Test-Path throws UnauthorizedAccessException on a path the process may not
    # look at (a WSL home owned by another linux user, for one), and
    # $ErrorActionPreference is Stop, so every probe of a path this widget does
    # not own goes through here.
    param([string]$Path)
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
        return [bool](Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)
    } catch {
        return $false
    }
}

function Get-FileWrittenAt {
    # Last write time of a file, or $null when it cannot be inspected.
    param([string]$Path)
    try {
        return (Get-Item -LiteralPath $Path -ErrorAction Stop).LastWriteTimeUtc
    } catch {
        return $null
    }
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-PathSafe $Path)) { return $null }
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

function Get-JwtExpiry {
    # Decodes the "exp" claim of a JWT without validating the signature.
    # Returns $null when the token is not a JWT or has no exp claim.
    param([string]$Jwt)
    try {
        if ([string]::IsNullOrWhiteSpace($Jwt)) { return $null }
        $parts = $Jwt.Split('.')
        if ($parts.Length -lt 2) { return $null }
        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        switch ($payload.Length % 4) {
            2 { $payload += '==' }
            3 { $payload += '=' }
        }
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
        $exp = Get-PropertyOrNull ($json | ConvertFrom-Json) 'exp'
        if ($null -eq $exp) { return $null }
        return [DateTimeOffset]::FromUnixTimeSeconds([int64]$exp)
    } catch {
        return $null
    }
}

# ---------------------------------------------------------------------------
# Token locations
#
# Where the CLIs keep their tokens differs per machine, so no path, distribution
# or user name is hardcoded. Each service resolves to one of three sources:
#   wsl     - a WSL home reached over \\wsl.localhost; the token file is read
#             via UNC and a refresh runs through wsl.exe
#   windows - the Windows user profile; a refresh runs the CLI directly
#   off     - the service is hidden and never fetched
# Resolution order: -WslDistro/-WslUser, then config.json, then detection. The
# outcome is written back to config.json, so a normal start scans nothing.
# Run with -Configure to detect again.
# ---------------------------------------------------------------------------
$script:TokenPaths = @{
    Claude = '.claude\.credentials.json'
    Codex  = '.codex\auth.json'
}
$script:Sources = @{
    Claude = @{ Kind = 'unset'; TokenFile = '' }
    Codex  = @{ Kind = 'unset'; TokenFile = '' }
}
$script:Wsl = @{ Distro = ''; User = '' }
$script:ActiveServices = @('Claude', 'Codex')

function Get-WslDistributionNames {
    # Installed distributions, the default one first. Read from the registry
    # because "wsl.exe -l" starts the WSL service merely to list them.
    $names = @()
    try {
        $root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
        if (-not (Test-Path $root)) { return $names }
        $defaultId = [string](Get-PropertyOrNull (Get-ItemProperty -Path $root -ErrorAction SilentlyContinue) 'DefaultDistribution')
        foreach ($key in @(Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            $name = [string](Get-PropertyOrNull (Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue) 'DistributionName')
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($key.PSChildName -eq $defaultId) { $names = @($name) + $names } else { $names += $name }
        }
    } catch { }
    return $names
}

function Get-WslHomePath {
    param([string]$Distro, [string]$User)
    if ($User -eq 'root') { return ('\\wsl.localhost\{0}\root' -f $Distro) }
    return ('\\wsl.localhost\{0}\home\{1}' -f $Distro, $User)
}

function Get-WslHomeUsers {
    # Every home in a distribution: each /home/<user>, plus /root.
    param([string]$Distro)
    $users = @()
    try {
        $homeRoot = '\\wsl.localhost\{0}\home' -f $Distro
        if (Test-PathSafe $homeRoot) {
            foreach ($dir in @(Get-ChildItem -LiteralPath $homeRoot -Directory -ErrorAction SilentlyContinue)) {
                $users += $dir.Name
            }
        }
    } catch { }
    try {
        if (Test-PathSafe ('\\wsl.localhost\{0}\root' -f $Distro)) { $users += 'root' }
    } catch { }
    return $users
}

function Find-TokenSource {
    # Searches the Windows profile and every WSL home for the service's token
    # file and returns the most recently written hit: the installation actually
    # in use is the one whose token keeps getting refreshed. $null if none.
    param([string]$Service)
    $rel = $script:TokenPaths[$Service]
    $hits = @()

    $winFile = Join-Path $env:USERPROFILE $rel
    $winAt = Get-FileWrittenAt $winFile
    if ($null -ne $winAt) {
        $hits += [pscustomobject]@{
            Kind = 'windows'; Distro = ''; User = ''; TokenFile = $winFile; WrittenAt = $winAt
        }
    }
    foreach ($distro in (Get-WslDistributionNames)) {
        foreach ($user in (Get-WslHomeUsers -Distro $distro)) {
            $file = Join-Path (Get-WslHomePath -Distro $distro -User $user) $rel
            # An unreadable file is skipped: a home this user cannot open is no
            # use as a token source even when the file exists.
            $writtenAt = Get-FileWrittenAt $file
            if ($null -eq $writtenAt) { continue }
            $hits += [pscustomobject]@{
                Kind = 'wsl'; Distro = $distro; User = $user; TokenFile = $file; WrittenAt = $writtenAt
            }
        }
    }
    if (@($hits).Count -eq 0) { return $null }
    return (@($hits) | Sort-Object WrittenAt -Descending | Select-Object -First 1)
}

function Save-TokenConfig {
    # Caches the resolved layout. Holds no credentials: a distribution name, a
    # linux user name, and one source kind per service.
    try {
        if (-not (Test-Path $script:Config.StateDir)) {
            New-Item -ItemType Directory -Path $script:Config.StateDir -Force | Out-Null
        }
        $data = [ordered]@{
            wsl      = [ordered]@{ distro = $script:Wsl.Distro; user = $script:Wsl.User }
            services = [ordered]@{
                claude = $script:Sources.Claude.Kind
                codex  = $script:Sources.Codex.Kind
            }
        }
        Set-Content -Path $script:Config.ConfigFile -Value ($data | ConvertTo-Json -Depth 4) -Encoding UTF8
    } catch {
        Write-Log ("save config failed: {0}" -f $_.Exception.Message)
    }
}

function Resolve-TokenSources {
    # Fills $script:Wsl and $script:Sources, then caches the outcome. Detection
    # runs only for a service that neither the command line nor config.json
    # settled, or for every service when -Redetect is given.
    param([switch]$Redetect)

    $cfg    = Read-JsonFile $script:Config.ConfigFile
    $cfgWsl = Get-PropertyOrNull $cfg 'wsl'
    $cfgSvc = Get-PropertyOrNull $cfg 'services'

    $script:Wsl.Distro = $WslDistro
    $script:Wsl.User   = $WslUser
    if ([string]::IsNullOrWhiteSpace($script:Wsl.Distro)) {
        $script:Wsl.Distro = [string](Get-PropertyOrNull $cfgWsl 'distro')
    }
    if ([string]::IsNullOrWhiteSpace($script:Wsl.User)) {
        $script:Wsl.User = [string](Get-PropertyOrNull $cfgWsl 'user')
    }

    foreach ($name in @('Claude', 'Codex')) {
        $src = $script:Sources[$name]
        $src.Kind = 'unset'
        $src.TokenFile = ''
        $stored = ''
        if (-not $Redetect) { $stored = [string](Get-PropertyOrNull $cfgSvc $name.ToLower()) }
        $haveWsl = -not ([string]::IsNullOrWhiteSpace($script:Wsl.Distro) -or
                         [string]::IsNullOrWhiteSpace($script:Wsl.User))

        if ($stored -eq 'off') {
            $src.Kind = 'off'
            continue
        }
        if ($stored -eq 'windows') {
            $src.Kind = 'windows'
            $src.TokenFile = Join-Path $env:USERPROFILE $script:TokenPaths[$name]
            continue
        }
        if ($stored -eq 'wsl' -and $haveWsl) {
            $src.Kind = 'wsl'
            $src.TokenFile = Join-Path (Get-WslHomePath -Distro $script:Wsl.Distro -User $script:Wsl.User) $script:TokenPaths[$name]
            continue
        }
        # Coordinates supplied but no stored decision: trust them when the file
        # is really there, so an explicit -WslUser is never overridden.
        if ($haveWsl) {
            $file = Join-Path (Get-WslHomePath -Distro $script:Wsl.Distro -User $script:Wsl.User) $script:TokenPaths[$name]
            if (Test-PathSafe $file) {
                $src.Kind = 'wsl'
                $src.TokenFile = $file
                continue
            }
        }
        $hit = Find-TokenSource -Service $name
        if ($null -eq $hit) { continue }
        $src.Kind = $hit.Kind
        $src.TokenFile = $hit.TokenFile
        if ($hit.Kind -eq 'wsl') {
            if ([string]::IsNullOrWhiteSpace($script:Wsl.Distro)) { $script:Wsl.Distro = $hit.Distro }
            if ([string]::IsNullOrWhiteSpace($script:Wsl.User))   { $script:Wsl.User   = $hit.User }
        }
    }
    Save-TokenConfig
}

function Test-SourceUnavailable {
    # Fills in the result and returns $true when a service has no usable token
    # location, so the caller returns without touching the network.
    param([string]$Service, $Result)
    $src = $script:Sources[$Service]
    if ($src.Kind -eq 'off') {
        $Result.Status = 'off'
        $Result.Message = 'disabled'
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($src.TokenFile)) {
        $Result.Status = 'unset'
        $Result.Message = 'token location not configured'
        return $true
    }
    return $false
}

function New-UsageResult {
    param([string]$Name)
    return [ordered]@{
        Name      = $Name
        Status    = 'error'     # ok | expired | error | unset | off | backoff
        Message   = ''
        HttpCode  = 0
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
    if ($span.TotalSeconds -le 0) { return '' }
    if ($span.TotalDays -ge 1) {
        return ('{0}일 {1}시간 후' -f [int][math]::Floor($span.TotalDays), $span.Hours)
    }
    if ($span.TotalHours -ge 1) {
        return ('{0}시간 {1}분 후' -f $span.Hours, $span.Minutes)
    }
    if ($span.TotalMinutes -ge 1) {
        return ('{0}분 후' -f $span.Minutes)
    }
    return '1분 이내'
}

# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------
function Test-ClaudeTokenValid {
    # Returns $true when the stored access token is not yet expired.
    $cred = Read-JsonFile $script:Sources.Claude.TokenFile
    $oauth = Get-PropertyOrNull $cred 'claudeAiOauth'
    if ($null -eq $oauth) { return $false }
    $expiresMs = Get-PropertyOrNull $oauth 'expiresAt'
    if ($null -eq $expiresMs) { return $false }
    $expiresAt = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$expiresMs)
    return ($expiresAt -gt [DateTimeOffset]::UtcNow.AddMinutes(1))
}

function Get-ClaudeUsage {
    $result = New-UsageResult -Name 'Claude'
    if (Test-SourceUnavailable -Service 'Claude' -Result $result) { return $result }
    try {
        $cred = Read-JsonFile $script:Sources.Claude.TokenFile
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
        $result.HttpCode = $code
        if ($code -eq 401) {
            $result.Status = 'expired'
            $result.Message = 'token rejected (401)'
        } else {
            $result.Message = if ($code -gt 0) { "http $code" } else { $_.Exception.Message }
        }
    }
    return $result
}

function Test-CodexTokenValid {
    # Returns $true when the stored access token (a JWT) is not yet expired.
    # A token whose expiry cannot be decoded is treated as valid so that the
    # API response (401) remains the final authority.
    $auth = Read-JsonFile $script:Sources.Codex.TokenFile
    $tokens = Get-PropertyOrNull $auth 'tokens'
    if ($null -eq $tokens) { return $false }
    $expiresAt = Get-JwtExpiry (Get-PropertyOrNull $tokens 'access_token')
    if ($null -eq $expiresAt) { return $true }
    return ($expiresAt -gt [DateTimeOffset]::UtcNow.AddMinutes(1))
}

function Get-CodexUsage {
    $result = New-UsageResult -Name 'Codex'
    if (Test-SourceUnavailable -Service 'Codex' -Result $result) { return $result }
    try {
        $auth = Read-JsonFile $script:Sources.Codex.TokenFile
        $tokens = Get-PropertyOrNull $auth 'tokens'
        if ($null -eq $tokens) {
            $result.Message = 'auth not found'
            return $result
        }
        if (-not (Test-CodexTokenValid)) {
            $result.Status = 'expired'
            $result.Message = 'token expired'
            return $result
        }
        $headers = @{
            'Authorization'      = 'Bearer ' + $tokens.access_token
            'ChatGPT-Account-ID' = [string]$tokens.account_id
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
        $result.HttpCode = $code
        if ($code -eq 401) {
            $result.Status = 'expired'
            $result.Message = 'token rejected (401)'
        } else {
            $result.Message = if ($code -gt 0) { "http $code" } else { $_.Exception.Message }
        }
    }
    return $result
}

# ---------------------------------------------------------------------------
# Token refresh: only when expired, at most once per cooldown window per
# service. Never touches the credential files directly; lets each CLI do it.
# ---------------------------------------------------------------------------
function Get-CapturedStderr {
    # Reads a captured stderr file, deletes it, and returns its last lines as a
    # single log-safe line (emails masked, length capped). Never throws.
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return '' }
        $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($text)) { return '' }
        $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
        $out = (($lines | Select-Object -Last 3) -join ' | ')
        $out = [regex]::Replace($out, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '<email>')
        if ($out.Length -gt 400) { $out = $out.Substring(0, 400) + '...' }
        return $out
    } catch {
        return ''
    }
}

function Invoke-CliCommand {
    # Runs a CLI command where that service keeps its tokens: inside WSL for a
    # wsl source, directly on Windows for a windows source. No visible window.
    # Returns the exit code (-1 on timeout, -2 when the service has no runnable
    # source) and logs the tail of stderr so failures can be diagnosed.
    param([string]$Service, [string]$Command, [int]$TimeoutSec = 120)

    $kind = $script:Sources[$Service].Kind
    if ($kind -eq 'wsl') {
        $exe = 'wsl.exe'
        $argList = '-d {0} -u {1} -- bash -lc "{2}"' -f $script:Wsl.Distro, $script:Wsl.User, $Command
        # wsl.exe writes UTF-16 to redirected handles unless told otherwise.
        $env:WSL_UTF8 = '1'
    } elseif ($kind -eq 'windows') {
        # cmd.exe resolves the CLI through PATH, which covers both an npm shim
        # (claude.cmd) and a native executable.
        $exe = 'cmd.exe'
        $argList = '/c {0}' -f $Command
    } else {
        return -2
    }

    if (-not (Test-Path $script:Config.StateDir)) {
        New-Item -ItemType Directory -Path $script:Config.StateDir -Force | Out-Null
    }
    # Unique per call: a file left locked by a killed process must not break
    # the next call. Stale files from earlier runs are swept opportunistically.
    try {
        Get-ChildItem -LiteralPath $script:Config.StateDir -Filter '*stderr-*.txt' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
    $errFile = Join-Path $script:Config.StateDir ('cli-stderr-{0}-{1}.txt' -f $PID, [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $proc = Start-Process -FilePath $exe -ArgumentList $argList -WindowStyle Hidden -PassThru `
        -RedirectStandardError $errFile
    # Touch Handle so that ExitCode is populated after exit (PowerShell 5.1 quirk).
    $null = $proc.Handle
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill(); $proc.WaitForExit(5000) | Out-Null } catch { }
        $code = -1
    } else {
        $code = $proc.ExitCode
    }
    $stderr = Get-CapturedStderr $errFile
    if ($stderr) { Write-Log ("{0} stderr [{1}]: {2}" -f $kind, $Command, $stderr) }
    return $code
}

function Test-RefreshAllowed {
    # Enforces the per-service cooldown and records the attempt when allowed.
    param([string]$Name)
    $now = [DateTimeOffset]::UtcNow
    if (($now - $script:LastRefreshAttempt[$Name]).TotalMinutes -lt $script:Config.RefreshCooldownMinutes) {
        return $false
    }
    $script:LastRefreshAttempt[$Name] = $now
    return $true
}

function Invoke-ClaudeTokenRefresh {
    # Claude Code refreshes an expired OAuth token right before it sends a
    # request, so one minimal headless message is the refresh mechanism.
    # ("claude auth status" only prints the stored credentials; it never
    # refreshed the token in 8 of 8 logged attempts.)
    if (-not (Test-RefreshAllowed -Name 'Claude')) { return $false }

    Write-Log 'claude token expired; sending one minimal headless message'
    $code = Invoke-CliCommand -Service 'Claude' -Command 'claude -p ok --model haiku' -TimeoutSec 180
    Write-Log ("claude -p exit={0}" -f $code)
    $ok = Test-ClaudeTokenValid
    Write-Log ("claude token valid after ping={0}" -f $ok)
    return $ok
}

function Invoke-CodexTokenRefresh {
    # "codex doctor" goes through AuthManager::auth(), which refreshes the
    # ChatGPT token with the stored refresh_token when the access token expires
    # within 5 minutes or last_refresh is older than 8 days. It sends no model
    # request, so it consumes no usage. The doctor also runs network reachability
    # checks, hence the longer timeout.
    if (-not (Test-RefreshAllowed -Name 'Codex')) { return $false }

    Write-Log 'codex token expired; trying "codex doctor --summary"'
    $code = Invoke-CliCommand -Service 'Codex' -Command 'codex doctor --summary' -TimeoutSec 120
    Write-Log ("codex doctor exit={0}" -f $code)
    $ok = Test-CodexTokenValid
    Write-Log ("codex token valid after doctor={0}" -f $ok)
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
    if ($Result.Status -eq 'backoff') {
        # No request was made: keep what the last one said.
        Update-LocalResets -State $State
        return
    }
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
    Left                = $null
    Top                 = $null
    IntervalMinutes     = $script:Config.DefaultIntervalMinutes
    TransparencyPercent = $script:Config.DefaultTransparency
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
            Left                = $script:Settings.Left
            Top                 = $script:Settings.Top
            IntervalMinutes     = $script:Settings.IntervalMinutes
            TransparencyPercent = $script:Settings.TransparencyPercent
            Services            = $services
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
        # Ignore intervals no longer offered (e.g. 1 minute) and keep the default.
        if ($null -ne $iv -and ($script:Config.IntervalChoices -contains [int]$iv)) {
            $script:Settings.IntervalMinutes = [int]$iv
        }
        $tp = Get-PropertyOrNull $state 'TransparencyPercent'
        # Same rule as the interval: drop values the menu no longer offers.
        if ($null -ne $tp -and ($script:Config.TransparencyChoices -contains [int]$tp)) {
            $script:Settings.TransparencyPercent = [int]$tp
        }

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
# Returns the process of a live widget instance, or $null. The pid file is the
# only reliable handle: WS_EX_TOOLWINDOW leaves MainWindowTitle empty, so the
# window title cannot identify a running widget.
function Get-RunningInstance {
    try {
        if (-not (Test-Path $script:Config.PidFile)) { return $null }
        $raw = (Get-Content $script:Config.PidFile -Raw).Trim()
        $oldPid = 0
        if (-not [int]::TryParse($raw, [ref]$oldPid)) { return $null }
        if ($oldPid -eq $PID) { return $null }
        $proc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
        if ($null -eq $proc) { return $null }
        if ($proc.ProcessName -notlike 'powershell*') { return $null }
        # Guard against pid reuse: the command line must mention this script.
        $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $oldPid" -ErrorAction SilentlyContinue
        if ($null -ne $cim -and $cim.CommandLine -notlike '*ai-usage-widget*') { return $null }
        return $proc
    } catch { return $null }
}

function Stop-ExistingInstance {
    $stopped = $false
    try {
        $running = Get-RunningInstance
        if ($null -ne $running) {
            Stop-Process -Id $running.Id -Force
            $stopped = $true
        }
        if (Test-Path $script:Config.PidFile) {
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
function Get-BackoffResult {
    # The result standing in for a fetch while a service waits out an HTTP 429
    # backoff, or $null when the service may be fetched.
    param([string]$Name)
    $until = $script:Backoff[$Name].Until
    if ([DateTimeOffset]::UtcNow.AddSeconds($script:Config.BackoffSlackSeconds) -ge $until) { return $null }
    $result = New-UsageResult -Name $Name
    $result.Status = 'backoff'
    $result.Message = 'waiting after http 429'
    return $result
}

function Update-Backoff {
    # Starts or doubles the backoff on HTTP 429 (capped); a success clears it.
    param([string]$Name, $Result)
    $wait = $script:Backoff[$Name]
    if ($Result.HttpCode -eq 429) {
        $wait.Minutes = [math]::Min([math]::Max($wait.Minutes * 2, $script:Config.BackoffMinMinutes),
                                    $script:Config.BackoffMaxMinutes)
        $wait.Until = [DateTimeOffset]::UtcNow.AddMinutes($wait.Minutes)
        Write-Log ("{0} http 429; next try in {1}m" -f $Name.ToLower(), $wait.Minutes)
    } elseif ($Result.Status -eq 'ok') {
        $wait.Minutes = 0
        $wait.Until = [DateTimeOffset]::MinValue
    }
}

function Update-AllServices {
    # -UseBackoff is for the widget only; one-shot modes always fetch.
    param([switch]$AllowRefresh, [switch]$UseBackoff)

    $claude = $null
    if ($UseBackoff) { $claude = Get-BackoffResult -Name 'Claude' }
    if ($null -eq $claude) {
        $claude = Get-ClaudeUsage
        if ($AllowRefresh -and $claude.Status -eq 'expired') {
            if (Invoke-ClaudeTokenRefresh) {
                $claude = Get-ClaudeUsage
            }
        }
        if ($UseBackoff) { Update-Backoff -Name 'Claude' -Result $claude }
    }
    Merge-UsageResult -State $script:Services.Claude -Result $claude

    $codex = $null
    if ($UseBackoff) { $codex = Get-BackoffResult -Name 'Codex' }
    if ($null -eq $codex) {
        $codex = Get-CodexUsage
        if ($AllowRefresh -and $codex.Status -eq 'expired') {
            if (Invoke-CodexTokenRefresh) {
                $codex = Get-CodexUsage
            }
        }
        if ($UseBackoff) { Update-Backoff -Name 'Codex' -Result $codex }
    }
    Merge-UsageResult -State $script:Services.Codex -Result $codex

    Write-Log ("fetch claude={0}{1} codex={2}{3}" -f $claude.Status,
        $(if ($claude.Message) { " ($($claude.Message))" } else { '' }),
        $codex.Status,
        $(if ($codex.Message) { " ($($codex.Message))" } else { '' }))

    return @{ Claude = $claude; Codex = $codex }
}

# ---------------------------------------------------------------------------
# Mode: -Stop (the only mode that needs no token configuration)
# ---------------------------------------------------------------------------
if ($Stop) {
    $stopped = Stop-ExistingInstance
    if ($stopped) { Write-Output 'stopped' } else { Write-Output 'not running' }
    exit 0
}

# Every mode below reads tokens, so the layout has to be settled first. A
# service turned off is dropped here and is neither fetched nor drawn.
Resolve-TokenSources -Redetect:$Configure
$script:ActiveServices = @(@('Claude', 'Codex') | Where-Object { $script:Sources[$_].Kind -ne 'off' })

# ---------------------------------------------------------------------------
# Mode: -Configure (reports paths and source kinds; never a token value)
# ---------------------------------------------------------------------------
if ($Configure) {
    [ordered]@{
        config_file = $script:Config.ConfigFile
        wsl         = [ordered]@{ distro = $script:Wsl.Distro; user = $script:Wsl.User }
        services    = [ordered]@{
            claude = [ordered]@{
                source     = $script:Sources.Claude.Kind
                token_file = $script:Sources.Claude.TokenFile
            }
            codex  = [ordered]@{
                source     = $script:Sources.Codex.Kind
                token_file = $script:Sources.Codex.TokenFile
            }
        }
    } | ConvertTo-Json -Depth 5
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

# The widget is Topmost, so an already-running instance is visible where the
# user left it; launching a second one would only restart the fetch cycle.
$script:Running = Get-RunningInstance
if ($null -ne $script:Running -and -not $Force) {
    Write-Log ("already running pid={0}; exiting" -f $script:Running.Id)
    exit 0
}

Stop-ExistingInstance | Out-Null
Write-PidFile
Load-State
if ($IntervalMinutes -gt 0) {
    if ($script:Config.IntervalChoices -contains $IntervalMinutes) {
        $script:Settings.IntervalMinutes = $IntervalMinutes
    } else {
        Write-Log ("ignoring unsupported interval {0}m; using {1}m" -f $IntervalMinutes, $script:Settings.IntervalMinutes)
    }
}
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
    Separator  = New-Brush '#28FFFFFF'
    ClaudeLogo = New-Brush '#D97757'
    CodexLogo  = New-Brush '#FFFFFF'
    Tag5h      = New-Brush '#3B82F6'
    Tag7d      = New-Brush '#8B5CF6'
}

function New-TextBlock {
    param([string]$Text = '', $Brush, [double]$Size = 12, [string]$Weight = 'Normal',
          [string]$HAlign = 'Left', [double]$Width = 0)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.Foreground = $Brush
    $tb.FontSize = $Size
    $tb.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe UI, Malgun Gothic'
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
    # Returns the track container, the fill element and the overlaid label.
    $h = $script:Config.BarHeight
    $track = New-Object System.Windows.Controls.Border
    $track.Width = $script:Config.BarWidth
    $track.Height = $h
    $track.CornerRadius = New-Object System.Windows.CornerRadius ($h / 2)
    $track.Background = $script:Colors.Track
    $track.VerticalAlignment = 'Center'
    $track.Margin = New-Object System.Windows.Thickness 0, 0, 10, 0

    $layer = New-Object System.Windows.Controls.Grid

    $fill = New-Object System.Windows.Controls.Border
    $fill.Height = $h
    $fill.Width = 0
    $fill.CornerRadius = New-Object System.Windows.CornerRadius ($h / 2)
    $fill.HorizontalAlignment = 'Left'
    $fill.Background = $script:Colors.Stale
    $layer.Children.Add($fill) | Out-Null

    $label = New-TextBlock -Text '--' -Brush $script:Colors.Text -Size 10 -Weight Bold
    $label.Margin = New-Object System.Windows.Thickness 0
    $label.HorizontalAlignment = 'Center'
    $label.VerticalAlignment = 'Center'
    $shadow = New-Object System.Windows.Media.Effects.DropShadowEffect
    $shadow.BlurRadius = 3
    $shadow.ShadowDepth = 0
    $shadow.Opacity = 0.9
    $shadow.Color = [System.Windows.Media.Colors]::Black
    $label.Effect = $shadow
    $layer.Children.Add($label) | Out-Null

    $track.Child = $layer
    return @{ Track = $track; Fill = $fill; Label = $label }
}

# Brand logos as vector path data (SVG path mini-language, parsed by WPF).
#   Claude: Simple Icons "claude" (CC0 1.0), viewBox 0 0 24 24, brand #D97757.
#   OpenAI: OpenAI symbol from Wikimedia Commons, viewBox 0 0 320 320, drawn white
#           on the dark widget background. Logos remain trademarks of their owners.
$script:LogoPaths = @{
    Claude = @'
m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z
'@
    Codex = @'
m297.06 130.97c7.26-21.79 4.76-45.66-6.85-65.48-17.46-30.4-52.56-46.04-86.84-38.68-15.25-17.18-37.16-26.95-60.13-26.81-35.04-.08-66.13 22.48-76.91 55.82-22.51 4.61-41.94 18.7-53.31 38.67-17.59 30.32-13.58 68.54 9.92 94.54-7.26 21.79-4.76 45.66 6.85 65.48 17.46 30.4 52.56 46.04 86.84 38.68 15.24 17.18 37.16 26.95 60.13 26.8 35.06.09 66.16-22.49 76.94-55.86 22.51-4.61 41.94-18.7 53.31-38.67 17.57-30.32 13.55-68.51-9.94-94.51zm-120.28 168.11c-14.03.02-27.62-4.89-38.39-13.88.49-.26 1.34-.73 1.89-1.07l63.72-36.8c3.26-1.85 5.26-5.32 5.24-9.07v-89.83l26.93 15.55c.29.14.48.42.52.74v74.39c-.04 33.08-26.83 59.9-59.91 59.97zm-128.84-55.03c-7.03-12.14-9.56-26.37-7.15-40.18.47.28 1.3.79 1.89 1.13l63.72 36.8c3.23 1.89 7.23 1.89 10.47 0l77.79-44.92v31.1c.02.32-.13.63-.38.83l-64.41 37.19c-28.69 16.52-65.33 6.7-81.92-21.95zm-16.77-139.09c7-12.16 18.05-21.46 31.21-26.29 0 .55-.03 1.52-.03 2.2v73.61c-.02 3.74 1.98 7.21 5.23 9.06l77.79 44.91-26.93 15.55c-.27.18-.61.21-.91.08l-64.42-37.22c-28.63-16.58-38.45-53.21-21.95-81.89zm221.26 51.49-77.79-44.92 26.93-15.54c.27-.18.61-.21.91-.08l64.42 37.19c28.68 16.57 38.51 53.26 21.94 81.94-7.01 12.14-18.05 21.44-31.2 26.28v-75.81c.03-3.74-1.96-7.2-5.2-9.06zm26.8-40.34c-.47-.29-1.3-.79-1.89-1.13l-63.72-36.8c-3.23-1.89-7.23-1.89-10.47 0l-77.79 44.92v-31.1c-.02-.32.13-.63.38-.83l64.41-37.16c28.69-16.55 65.37-6.7 81.91 22 6.99 12.12 9.52 26.31 7.15 40.1zm-168.51 55.43-26.94-15.55c-.29-.14-.48-.42-.52-.74v-74.39c.02-33.12 26.89-59.96 60.01-59.94 14.01 0 27.57 4.92 38.34 13.88-.49.26-1.33.73-1.89 1.07l-63.72 36.8c-3.26 1.85-5.26 5.31-5.24 9.06l-.04 89.79zm14.63-31.54 34.65-20.01 34.65 20v40.01l-34.65 20-34.65-20z
'@
}

function New-LogoIcon {
    # Renders a vector logo scaled uniformly into a Size x Size box.
    param([string]$PathData, $Brush, [double]$Size = 22)
    $shape = New-Object System.Windows.Shapes.Path
    $shape.Data = [System.Windows.Media.Geometry]::Parse($PathData.Trim())
    $shape.Fill = $Brush
    $shape.Stretch = 'Uniform'
    $box = New-Object System.Windows.Controls.Viewbox
    $box.Width = $Size
    $box.Height = $Size
    $box.Stretch = 'Uniform'
    $box.VerticalAlignment = 'Center'
    $box.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0
    $box.Child = $shape
    return $box
}

$script:WindowTags = @{
    '5h' = @{ Text = '5시간'; Brush = $null }
    '7d' = @{ Text = '7일';   Brush = $null }
}

function New-WindowTag {
    # Small rounded tag for the window label, coloured per window so the
    # 5-hour and 7-day rows are told apart at a glance.
    param([string]$Window)
    $spec = $script:WindowTags[$Window]
    $tag = New-Object System.Windows.Controls.Border
    $tag.CornerRadius = New-Object System.Windows.CornerRadius 4
    $tag.Background = $spec.Brush
    $tag.Padding = New-Object System.Windows.Thickness 0, 1, 0, 1
    $tag.Width = 44
    $tag.VerticalAlignment = 'Center'
    $tag.Margin = New-Object System.Windows.Thickness 0, 3, 8, 3
    $label = New-TextBlock -Text $spec.Text -Brush $script:Colors.Text -Size 11 -Weight Bold
    $label.Margin = New-Object System.Windows.Thickness 0
    $label.HorizontalAlignment = 'Center'
    $label.VerticalAlignment = 'Center'
    $tag.Child = $label
    return $tag
}

function New-Separator {
    $line = New-Object System.Windows.Controls.Border
    $line.Height = 1
    $line.Background = $script:Colors.Separator
    $line.Margin = New-Object System.Windows.Thickness 0, 7, 0, 5
    $line.HorizontalAlignment = 'Stretch'
    return $line
}

# Build the layout: one grid with columns [label | bar | reset]; per service a
# header row and two gauge rows, a separator between services, and a footer.
$grid = New-Object System.Windows.Controls.Grid
foreach ($w in @('Auto', 'Auto', 'Auto')) {
    $col = New-Object System.Windows.Controls.ColumnDefinition
    $col.Width = [System.Windows.GridLength]::Auto
    $grid.ColumnDefinitions.Add($col) | Out-Null
}
for ($i = 0; $i -lt 8; $i++) {
    $row = New-Object System.Windows.Controls.RowDefinition
    $row.Height = [System.Windows.GridLength]::Auto
    $grid.RowDefinitions.Add($row) | Out-Null
}

$script:LogoBrushes = @{ Claude = $script:Colors.ClaudeLogo; Codex = $script:Colors.CodexLogo }
$script:WindowTags['5h'].Brush = $script:Colors.Tag5h
$script:WindowTags['7d'].Brush = $script:Colors.Tag7d

$script:Views = @{}
$rowIndex = 0
foreach ($name in $script:ActiveServices) {
    if ($rowIndex -gt 0) {
        Add-ToGrid $grid (New-Separator) $rowIndex 0 3
        $rowIndex++
    }
    $view = @{}
    $header = New-Object System.Windows.Controls.StackPanel
    $header.Orientation = 'Horizontal'
    $header.Margin = New-Object System.Windows.Thickness 0, 0, 0, 4
    $header.Children.Add((New-LogoIcon -PathData $script:LogoPaths[$name] -Brush $script:LogoBrushes[$name] -Size 22)) | Out-Null
    $view.Name = New-TextBlock -Text $name -Brush $script:Colors.Text -Size 15 -Weight Bold
    $header.Children.Add($view.Name) | Out-Null
    $view.Status = New-TextBlock -Text '' -Brush $script:Colors.Dim -Size 10 -HAlign Right
    $view.Status.Margin = New-Object System.Windows.Thickness 0, 0, 0, 4
    Add-ToGrid $grid $header      $rowIndex 0 2
    Add-ToGrid $grid $view.Status $rowIndex 2
    $rowIndex++

    foreach ($win in @('5h', '7d')) {
        $label = New-WindowTag -Window $win
        $bar   = New-UsageBar
        $reset = New-TextBlock -Text '' -Brush $script:Colors.Text -Size 12 -HAlign Right -Width 104
        $reset.Margin = New-Object System.Windows.Thickness 0
        Add-ToGrid $grid $label     $rowIndex 0
        Add-ToGrid $grid $bar.Track $rowIndex 1
        Add-ToGrid $grid $reset     $rowIndex 2
        $view["Fill$win"]  = $bar.Fill
        $view["Label$win"] = $bar.Label
        $view["Reset$win"] = $reset
        $rowIndex++
    }
    $script:Views[$name] = $view
}
$script:Views.Footer = New-TextBlock -Text '시작 중...' -Brush $script:Colors.Dim -Size 9 -HAlign Right
$script:Views.Footer.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
Add-ToGrid $grid $script:Views.Footer $rowIndex 0 3

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
# The context menu lives in its own popup window, so it stays fully opaque.
$script:Window.Opacity = (100 - $script:Settings.TransparencyPercent) / 100

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
    if ($Remaining -ge $script:Config.LowRemaining) { return $script:Colors.Warn }
    return $script:Colors.Bad
}

function Get-ResetPresentation {
    # Decides text, colour and weight of the reset countdown. Judged purely on
    # time left; how much quota remains is already shown by the bar colour.
    # Thresholds come from ResetThresholds because the 5h and 7d windows run on
    # very different cycles:
    #   - within Soon -> red, bold, with a refresh arrow: the reset is close,
    #     so spend what is left before it is wiped
    #   - beyond Far  -> green (no reason to hurry; the window is far away)
    #   - in between  -> normal text (grey when stale)
    param($ResetsAt, [bool]$Fresh, [string]$Window)
    $text = Format-Countdown $ResetsAt
    if ([string]::IsNullOrEmpty($text)) {
        return @{ Text = ''; Brush = $script:Colors.Dim; Bold = $false }
    }
    if (-not $Fresh) {
        return @{ Text = $text; Brush = $script:Colors.Stale; Bold = $false }
    }
    $limits = $script:Config.ResetThresholds[$Window]
    $minutesLeft = ($ResetsAt - [DateTimeOffset]::UtcNow).TotalMinutes
    if ($minutesLeft -le $limits.Soon) {
        return @{ Text = ([string][char]0x21BB + ' ' + $text); Brush = $script:Colors.Bad; Bold = $true }
    }
    if ($minutesLeft -gt $limits.Far) {
        return @{ Text = $text; Brush = $script:Colors.Good; Bold = $false }
    }
    return @{ Text = $text; Brush = $script:Colors.Text; Bold = $false }
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
            $view["Label$win"].Text = '--'
        } else {
            $fill.Width = [math]::Max(0.0, $script:Config.BarWidth * ([double]$remaining / 100.0))
            $view["Label$win"].Text = ('{0}%' -f [int]$remaining)
        }
        $fill.Background = Get-BarBrush -Remaining $remaining -Fresh $fresh

        $reset = Get-ResetPresentation -ResetsAt $resetAt -Fresh $fresh -Window $win
        $rt = $view["Reset$win"]
        $rt.Text = $reset.Text
        $rt.Foreground = $reset.Brush
        $rt.FontWeight = [System.Windows.FontWeight]::FromOpenTypeWeight($(if ($reset.Bold) { 700 } else { 400 }))
    }

    switch ($s.Status) {
        'ok'      { $view.Status.Text = '' }
        'expired' { $view.Status.Text = '토큰 만료' }
        'stale'   { $view.Status.Text = '캐시된 값' }
        'init'    { $view.Status.Text = '' }
        'unset'   { $view.Status.Text = '설정 필요' }
        default   { $view.Status.Text = '오류: ' + $s.Message }
    }
    $view.Status.Foreground = $(if ($s.Status -eq 'ok' -or $s.Status -eq 'init') { $script:Colors.Dim } else { $script:Colors.Warn })
}

function Update-View {
    foreach ($name in $script:ActiveServices) { Update-ServiceView $name }
    $times = @()
    foreach ($name in $script:ActiveServices) {
        $u = $script:Services[$name].UpdatedAt
        if ($null -ne $u) { $times += $u }
    }
    if ($times.Count -gt 0) {
        $latest = ($times | Sort-Object)[-1]
        $script:Views.Footer.Text = ('{0} 갱신  ·  {1}분마다' -f $latest.ToLocalTime().ToString('HH:mm'), $script:Settings.IntervalMinutes)
    } else {
        $script:Views.Footer.Text = ('데이터 없음  ·  {0}분마다' -f $script:Settings.IntervalMinutes)
    }
}

function Invoke-FetchAndRender {
    $script:Views.Footer.Text = '갱신 중...'
    # Flush the render queue so the "updating..." text is visible during the fetch.
    $script:Window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    try {
        Update-AllServices -AllowRefresh -UseBackoff | Out-Null
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

function Set-WindowTransparency {
    param([int]$Percent)
    $script:Settings.TransparencyPercent = $Percent
    $script:Window.Opacity = (100 - $Percent) / 100
    foreach ($item in $script:TransparencyItems) { $item.IsChecked = ([int]$item.Tag -eq $Percent) }
    Save-State
    Write-Log ("transparency set to {0}%" -f $Percent)
}

# ---------------------------------------------------------------------------
# Context menu
# ---------------------------------------------------------------------------
$menu = New-Object System.Windows.Controls.ContextMenu

$miRefresh = New-Object System.Windows.Controls.MenuItem
$miRefresh.Header = '지금 갱신'
$miRefresh.Add_Click({
    try { Invoke-FetchAndRender } catch { Write-Log ("manual refresh failed: {0}" -f $_.Exception.Message) }
})
$menu.Items.Add($miRefresh) | Out-Null

$miInterval = New-Object System.Windows.Controls.MenuItem
$miInterval.Header = '갱신 주기'
$script:IntervalItems = @()
foreach ($m in $script:Config.IntervalChoices) {
    $item = New-Object System.Windows.Controls.MenuItem
    $item.Header = ('{0}분' -f $m)
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

$miTransparency = New-Object System.Windows.Controls.MenuItem
$miTransparency.Header = '투명도'
$script:TransparencyItems = @()
foreach ($t in $script:Config.TransparencyChoices) {
    $item = New-Object System.Windows.Controls.MenuItem
    if ($t -eq 0) { $item.Header = '없음' } else { $item.Header = ('{0}%' -f $t) }
    $item.Tag = $t
    $item.IsCheckable = $true
    $item.IsChecked = ($t -eq $script:Settings.TransparencyPercent)
    $item.Add_Click({
        param($sender, $e)
        try { Set-WindowTransparency -Percent ([int]$sender.Tag) } catch { Write-Log ("set transparency failed: {0}" -f $_.Exception.Message) }
    })
    $miTransparency.Items.Add($item) | Out-Null
    $script:TransparencyItems += $item
}
$menu.Items.Add($miTransparency) | Out-Null

$menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null

$miExit = New-Object System.Windows.Controls.MenuItem
$miExit.Header = '종료'
$miExit.Add_Click({ $script:Window.Close() })
$menu.Items.Add($miExit) | Out-Null

$root.ContextMenu = $menu

# ---------------------------------------------------------------------------
# Window events
# ---------------------------------------------------------------------------
$root.Add_MouseLeftButtonDown({
    # DragMove blocks until the button is released and swallows the
    # MouseLeftButtonUp event, so persist the position right after it returns.
    try { $script:Window.DragMove() } catch { }
    try {
        $script:Settings.Left = $script:Window.Left
        $script:Settings.Top  = $script:Window.Top
        Save-State
    } catch {
        Write-Log ("save position failed: {0}" -f $_.Exception.Message)
    }
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
