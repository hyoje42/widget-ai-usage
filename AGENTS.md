# AGENTS.md

Shared instructions for all agents (Claude Code, Codex, ...). Records decisions and facts
not derivable from code or git history. Platform rules live in each platform folder's AGENTS.md.

## 1. Purpose

A small desktop widget showing the **remaining percent** of Claude Code and Codex subscription
usage (5-hour and 7-day windows) and the time until each resets. Each platform has its own implementation.

Anyone who clones the repo must be able to use it unmodified: never hardcode machine-specific
values (paths, distro names, usernames). User docs are in each platform's README.md.

## 2. Layout and scope

```
AGENTS.md / CLAUDE.md   # shared rules (this file)
README.md               # repo intro, links to platform docs
windows/                # PowerShell 5.1 + WPF. Rules: windows/AGENTS.md
linux/                  # Python 3 + GTK 3. Rules: linux/AGENTS.md
```

- Platforms share no code; sections 3-5 are the shared **contract**. Windows is pinned to
  PowerShell 5.1, so there is no common language, and the shareable logic (fetch, parse) is small (decided 2026-09-11).
- When you change the contract, update both implementations in the same task. If you can run
  only one platform, record what is left undone in the other platform's AGENTS.md.
- For platform work, **start the session in that platform folder**: Codex reads AGENTS.md only
  from the git root down to the cwd. If you started at the root, read the platform AGENTS.md first.
- Do not turn platform folders into git submodules: Codex treats a submodule as the git root and
  skips this file (codex-cli 0.154.0, checked with `codex debug prompt-input`, 2026-09-11).
- Write instructions only in AGENTS.md; each CLAUDE.md is the single line `@AGENTS.md`.

## 3. Behavior rules (do not revert)

- Token files are **read-only**. Resolve their location at runtime; never hardcode it.
  The widget calls the APIs directly, not through the CLIs.
- **Never refresh with the refresh_token directly.** Racing Claude Code's own refresh can invalidate each other's tokens.
- **No periodic headless messages.** They consume usage and pile up session history.
  - Reconsidered as a usage source and rejected (2026-09-11): one `claude -p "ok" --model haiku` used ~25k tokens
    (cache write 11k + read 14k) of the very quota being shown, and its stream-json `rate_limit_event` carries
    utilization only after a bucket crosses a warning threshold (anthropics/claude-code#50518, closed not planned).
- Refresh **once, only on detected expiry**, by invoking the service CLI. How to launch the CLI is platform-specific.
  - Claude: `claude -p "ok" --model haiku`. Claude Code refreshes an expired token right before
    a request, so one minimal message is the refresh. `claude auth status` only prints stored
    credentials (0 refreshes in 8 attempts in the widget log, 2026-09-07); it was once tried first and removed for wasting 30 s.
  - Codex: `codex doctor --summary`. `doctor` calls `AuthManager::auth()`, which refreshes when the
    access token is within 5 min of expiry or `last_refresh` is older than 8 days (codex-rs
    `login/src/auth/manager.rs`). It sends no model request, so it uses no quota. `codex login status` only reads the file.
    Not yet verified in a real environment (as of 2026-09-07); update this line once confirmed.
  - Log the last 3 stderr lines of the refresh command, emails masked, to diagnose failures.
  - The 15-minute refresh cooldown is per service; a Claude attempt does not block Codex.
- While the API is unreachable, keep the last values; once a reset time passes, reset that window to 0% used locally.
- **Fetch every 5 minutes by default** (menu choices 2/5/10). **On HTTP 429 from a usage API, skip that service** for
  10 minutes, doubling per consecutive 429 up to 30; a success clears it, and a fetch due within 30 s is not skipped.
  A skipped fetch leaves that service's state untouched and logs `backoff`. One-shot fetch modes never back off.
  `/api/oauth/usage` rate-limits hard with no usable `Retry-After` (anthropics/claude-code#30930, #31637); this widget
  hit a 6-minute 429 burst at a 2-minute interval (2026-09-11).
- **Single instance.** A second launch logs and exits immediately. Each start calls the API at once,
  so rapid restarts cause HTTP 429.
- For shared UI elements (bar color thresholds, countdown format and colors, status text, refresh
  interval and opacity choices), `windows/ai-usage-widget.ps1` is the reference. See `$script:Config`,
  `Get-BarBrush`, `Get-ResetPresentation`, `Format-Countdown`, `Update-ServiceView`.

## 4. Data sources (unofficial APIs)

Both endpoints are internal to the CLIs and may change without notice. If a field is missing or
malformed, **show an error state** instead of throwing.

`~` below is the home where that CLI stores credentials; finding it is platform-specific.

### Claude Code
- Token: `~/.claude/.credentials.json` → `claudeAiOauth.accessToken`, `claudeAiOauth.expiresAt` (epoch ms).
  Lifetime ~8 h; Claude Code refreshes and rewrites the file when near expiry.
- Request: `GET https://api.anthropic.com/api/oauth/usage`
  - Headers: `Authorization: Bearer <accessToken>`, `anthropic-beta: oauth-2025-04-20`, `Content-Type: application/json`
- Fields: `five_hour.utilization` (used %, 0-100), `five_hour.resets_at` (ISO 8601); same under `seven_day`.

### Codex
- Token: `~/.codex/auth.json` → `tokens.access_token`, `tokens.account_id`. The access token is a JWT;
  use its `exp` claim (lifetime ~10 days; ignore `id_token`, 1 h). `last_refresh` is the CLI's last refresh time.
- Request: `GET https://chatgpt.com/backend-api/wham/usage`
  - Headers: `Authorization: Bearer <access_token>`, `ChatGPT-Account-ID: <account_id>`
- Fields: `rate_limit.primary_window.used_percent`, `rate_limit.primary_window.reset_at` (epoch s) for
  the 5-hour window; same under `rate_limit.secondary_window` for the 7-day window.
- The response includes `email`, `user_id`, `account_id`. **Never display or store them.**

Displayed value: remaining percent = `100 - used%`.

### Logos
- Claude: Simple Icons `claude` (CC0 1.0), viewBox 0 0 24 24, brand color `#D97757`.
- Codex: OpenAI symbol (Wikimedia Commons `ChatGPT-Logo.svg`, single path, viewBox 0 0 320 320), white on dark.
- Path data: `$script:LogoPaths` in `windows/ai-usage-widget.ps1`.
- Both are trademarks, used only in a personal widget. Do not alter their color or shape.

## 5. Security and privacy (mandatory)

- Never write, move, or delete token files.
- Never put token values, refresh tokens, account ids, or emails in logs, UI, files, chat output, or commits.
  For debugging, print key names only or mask values.
- Never save raw API responses. State files hold only percentages, reset times, last update time, and window position.
- Keep `.credentials.json`, `auth.json`, state files, and scratch output out of the repo (maintain `.gitignore`).
- Config files with personal environment info (distro, username, paths) stay out of the repo even
  though they are not credentials. Commands that print config show paths only, never token values.

## 6. Conventions

- Reply to the user in **Korean**.
- Code comments and commit messages in English; imperative subject, 72 chars max.
- Commit only after explicit user approval.
- Write AGENTS.md files in English and keep them concise: rules and pointers, not copies of READMEs or code.
- After verifying an open item (e.g., whether `codex doctor` refreshes an expired token), update the doc that records it.
