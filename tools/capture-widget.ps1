# Dev tool: capture the running widget window (found by widget.pid) via PrintWindow.
# Works even when a fullscreen app covers the screen or the widget is on another monitor.
# Output: %LOCALAPPDATA%\Temp\widget-window.png
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace Cap -Name Native -MemberDefinition @'
public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
'@
$targetPid = [uint32](Get-Content "$env:LOCALAPPDATA\ai-usage-widget\widget.pid").Trim()
$found = [IntPtr]::Zero
$cb = [Cap.Native+EnumWindowsProc]{ param($h, $l)
    $wp = 0; [Cap.Native]::GetWindowThreadProcessId($h, [ref]$wp) | Out-Null
    if ($wp -eq $targetPid -and [Cap.Native]::IsWindowVisible($h)) { $script:found = $h; return $false }
    return $true }
[Cap.Native]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
if ($found -eq [IntPtr]::Zero) { Write-Output 'window not found'; exit 1 }
$r = New-Object Cap.Native+RECT
[Cap.Native]::GetWindowRect($found, [ref]$r) | Out-Null
$w = $r.R - $r.L; $h = $r.B - $r.T
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::FromArgb(255, 40, 60, 90))
$hdc = $g.GetHdc()
$ok = [Cap.Native]::PrintWindow($found, $hdc, 2)
$g.ReleaseHdc($hdc)
$bmp.Save("$env:LOCALAPPDATA\Temp\widget-window.png")
Write-Output ("captured {0}x{1} at {2},{3} ok={4}" -f $w, $h, $r.L, $r.T, $ok)
