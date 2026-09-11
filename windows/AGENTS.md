# AGENTS.md (windows)

Rules for the Windows implementation. Follow them together with the root [AGENTS.md](../AGENTS.md)
(shared rules and contract). Relative paths are from `windows/`. User docs: [README.md](./README.md).

## 1. Overview

An always-on-top widget on the Windows desktop. Developed in WSL (Ubuntu), run on the Windows host.

## 2. Architecture decisions (do not revert)

- **Single PowerShell script + WPF.** Install nothing on Windows. Call APIs with `Invoke-RestMethod`.
- **Token source is resolved per service**: `wsl`, `windows`, or `off`. Claude may live in WSL while Codex lives on Windows.
  - The root AGENTS.md `~` is the WSL home via UNC for `wsl`, and `%USERPROFILE%` for `windows`.
  - Resolution order: `-WslDistro`/`-WslUser` parameters → `config.json` → auto-detect.
    The result is cached in `config.json`; `-Configure` re-detects.
  - Auto-detect reads distros from the registry `HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss`
    (`wsl.exe -l` wakes the WSL service; the registry does not). It then picks the **most recently written**
    token file across the Windows profile and all WSL homes, since the install in use is the one refreshing its token.
  - `Test-Path` on an inaccessible home (another user's or root's) throws `UnauthorizedAccessException`,
    which aborts the script under `$ErrorActionPreference = 'Stop'`. For paths we don't own, always use
    `Test-PathSafe`, and `Get-FileWrittenAt` for file times.
  - Both the `wsl` and the `windows` source work in real environments (confirmed by the user, 2026-09-11).
- The refresh CLI (root AGENTS.md §3) runs where the service's source is, for both services:
  `wsl.exe -d <distro> -u <user> -- bash -lc "<cmd>"` for `wsl`, `cmd.exe /c <cmd>` for `windows`.
  `cmd.exe` resolves both npm's `claude.cmd` and native executables on PATH.
- The widget is always `Topmost`, so a second launch does not bring the existing window forward.
  Use `-Force` only when an install must replace the running instance.
- `config.json` holds the WSL distro and Linux username. It is personal info, so it stays out of the repo (root AGENTS.md §5).

## 3. Environment facts

Machine-specific values (usernames, distro names, absolute paths) come from auto-detect and `config.json`.
**Write them in neither code nor this file.** Check the current values with `-Configure`.

- Host: Windows 11 Pro with **only Windows PowerShell 5.1**. No pwsh 7, Node, real Python (Store stub only), .NET SDK, or Rainmeter.
- Windows home: `%USERPROFILE%`, or `/mnt/c/Users/<user>` from WSL. WSL home from Windows: `\\wsl.localhost\<distro>\home\<user>`.
  On this dev machine, auto-detect finds the WSL home for both services (2026-09-09).
- Calling `powershell.exe` from WSL: `cd /mnt/c` first to avoid the UNC working-directory warning, always
  pass `-NoProfile`, and pipe through `tr -d '\r'`. Korean error messages may look garbled due to the code page.
- A Windows → WSL call (`wsl.exe -d <distro> -u <user> -- <cmd>`) takes ~0.2 s.
- Startup folder: `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup`. The installer creates the same
  `AI Usage Widget.lnk` there and in the Start menu (`...\Programs`).

## 4. PowerShell 5.1 rules

- No PowerShell 7-only syntax: ternary `? :`, null-coalescing `??`, `ForEach-Object -Parallel`, `Get-Error`, `-SkipHttpErrorCheck`, etc.
- `.ps1` files containing Korean **must be UTF-8 with BOM**; 5.1 reads BOM-less UTF-8 as ANSI.
  `ai-usage-widget.ps1` has Korean UI text. In Python use `encoding='utf-8-sig'`; after editing with
  sed or similar, check that `head -c3 | xxd` shows `ef bb bf`.
- WPF needs an **STA thread**: launch with `-STA`.
- Always pass `-TimeoutSec` to `Invoke-RestMethod`, and add TLS 1.2 to `[Net.ServicePointManager]::SecurityProtocol` before calling.
- Use `System.Windows.Threading.DispatcherTimer` for timers (UI-thread safe).
- **Variable names are case-insensitive**: at script top level, `$ui` and `$script:Ui` are the same variable.
  Give script-scope and loop-local variables clearly different names (e.g., `$script:Views` vs `$view`).
- Never write a literal starting with `--%`; even quoted, `'--%'` can be parsed as the stop-parsing token.
- Under `$ErrorActionPreference = 'Stop'`, an exception in a timer tick or event handler silently kills
  the process. Wrap every handler in try/catch with `Write-Log`, and keep a `Dispatcher.UnhandledException` handler as the last safety net.
- A window with `WS_EX_TOOLWINDOW` has an empty `Process.MainWindowTitle`; detect the running instance via `widget.pid`.
- `Window.DragMove()` blocks until the drag ends and swallows `MouseLeftButtonUp`; save the position right after it returns.
- Don't use automatic variables (`$host`, `$input`, `$args`, ...) as local variable names.
- Use FontFamily `'Segoe UI, Malgun Gothic'` for Hangul fallback.
- Header logos (root AGENTS.md §4) are embedded SVG path data drawn with WPF `Path`; no image files.

## 5. Files and deployment

```
README.md                 # user install and config guide
ai-usage-widget.ps1       # widget (UI + fetch + refresh)
ai-usage-widget.ico       # shortcut icon (generated, but committed)
install.ps1               # copy to install dir, register startup shortcut, restart widget
uninstall.ps1             # remove shortcuts, stop widget
tools/capture-widget.ps1  # dev only: capture the widget window to PNG (not installed)
tools/make-icon.py        # dev only: render the icon in code (not installed)
```

- Develop in this folder of the repo cloned inside WSL. Install dir: `%LOCALAPPDATA%\ai-usage-widget\`, holding
  `state.json` (window position, last values), `widget.pid`, `config.json` (token sources), and `widget.log`.
  The installer creates `config.json` by calling `-Configure`.
- Shortcuts must not include `-Force`, or every Start-menu click restarts the widget. Only the installer's own launch uses `-Force`.
- The window title is fixed to `AI Usage Widget`. Stopping uses `widget.pid` first, then the window title.
- The installer must be idempotent.
- The icon is rendered in WSL with the Python stdlib only (`python3 tools/make-icon.py`), since Windows has no
  image tools. Signed distance functions give anti-aliasing without libraries. 16-48 px use a single ring and
  64 px+ a double ring, because two rings blur at small sizes. The Windows icon cache may delay showing a regenerated icon.

## 6. Run and verify (from WSL)

```bash
# Windows path of this folder (run once, anywhere in the repo)
WIN_DIR="$(wslpath -w "$(git rev-parse --show-toplevel)/windows")"

# Install: copy + detect token sources + register shortcuts + restart
cd /mnt/c && powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WIN_DIR\install.ps1" | tr -d '\r'

# Capture the widget window to PNG
cd /mnt/c && powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WIN_DIR\tools\capture-widget.ps1" | tr -d '\r'
```

For the installed widget, use `-Command` with **bash single quotes**; inside double quotes bash expands
`$env` and breaks the path into `:LOCALAPPDATA\...`.

```bash
# Swap the switch: -FetchOnly (fetch result as JSON), -Configure (token sources, paths only), -Stop (stop widget)
cd /mnt/c && powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '& "$env:LOCALAPPDATA\ai-usage-widget\ai-usage-widget.ps1" -FetchOnly' | tr -d '\r'
```

- The widget script must support `-FetchOnly`, `-Stop`, `-Force`, and `-Configure`.
- Launching the UI directly **does not return while the process lives**. To restart, run `install.ps1`
  (it uses `Start-Process` and returns). If you must launch directly, append `&`.
- For screen checks, prefer `tools/capture-widget.ps1`: it captures the widget window itself with PrintWindow,
  even under a fullscreen app or on another monitor. It saves `%LOCALAPPDATA%\Temp\widget-window.png` and prints the window's real coordinates.
- Only when you need surrounding screen context, crop the primary monitor's bottom-right corner:

```bash
cd /mnt/c && powershell.exe -NoProfile -Command 'Add-Type -AssemblyName System.Drawing,System.Windows.Forms; $b=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds; $r=New-Object System.Drawing.Rectangle ($b.Width-480),($b.Height-300),480,300; $bmp=New-Object System.Drawing.Bitmap $r.Width,$r.Height; $g=[System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($r.Location,[System.Drawing.Point]::Empty,$r.Size); $bmp.Save("$env:TEMP\widget-crop.png")'
```

- To see startup errors, run `-Command 'try { & "<path>" } catch { $_.ScriptStackTrace; $_.Exception.Message }'`; `-File` loses line numbers.
- Log: `widget.log` in the install dir. When healthy, it gets one `fetch claude=ok codex=ok` line per refresh interval.
- After any change, at minimum confirm that `-FetchOnly` returns `ok` for both services.

## 7. Open items

- The 5-minute default and the HTTP 429 backoff (root AGENTS.md §3: `$script:Backoff`, `Get-BackoffResult`,
  `Update-Backoff`) were written on a native Ubuntu machine without PowerShell (2026-09-11), so the script has not been
  parsed or run since. Next Windows session: check the BOM, run `install.ps1` and `-FetchOnly`, and watch `widget.log`
  for `fetch` lines. A saved `IntervalMinutes` of 2 stays 2; switch it from the menu. Remove this item once verified.
