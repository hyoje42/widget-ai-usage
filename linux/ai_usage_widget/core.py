"""Data layer of the Linux widget: config, state, fetch, token refresh, instance.

Nothing here imports GTK, so the headless modes (--fetch-only, --configure,
--stop) work without a display. The behaviour follows the shared contract in
the root AGENTS.md; windows/ai-usage-widget.ps1 is the reference implementation.
"""

import base64
import datetime as dt
import fcntl
import glob
import json
import os
import re
import shutil
import signal
import subprocess
import time
import urllib.error
import urllib.request

APP = "ai-usage-widget"
WINDOW_TITLE = "AI Usage Widget"
HOME = os.path.expanduser("~")
STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local", "state"), APP)
CONFIG_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config"), APP)
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")
STATE_FILE = os.path.join(STATE_DIR, "state.json")
PID_FILE = os.path.join(STATE_DIR, "widget.pid")
LOCK_FILE = os.path.join(STATE_DIR, "widget.lock")
LOG_FILE = os.path.join(STATE_DIR, "widget.log")
# Throwaway top bar images; the runtime dir is a tmpfs cleared at logout.
RUNTIME_DIR = os.path.join(os.environ["XDG_RUNTIME_DIR"], APP) if os.environ.get("XDG_RUNTIME_DIR") else STATE_DIR

DEFAULT_INTERVAL = 5
INTERVAL_CHOICES = (2, 5, 10)
DEFAULT_TRANSPARENCY = 0
TRANSPARENCY_CHOICES = (0, 15, 30, 45)
HTTP_TIMEOUT = 15
REFRESH_COOLDOWN_SEC = 15 * 60
# After an HTTP 429 a service is skipped for this long, doubling per repeat.
BACKOFF_MIN_SEC, BACKOFF_MAX_SEC = 10 * 60, 30 * 60
# Timers fire a little early; a fetch due within this slack is not skipped.
BACKOFF_SLACK_SEC = 30
LOW_REMAINING = 20
# Reset countdown colour thresholds in minutes, per window: (soon, far).
RESET_THRESHOLDS = {"5h": (30, 120), "7d": (720, 4320)}

CLAUDE_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
USER_AGENT = APP

SERVICES = ("Claude", "Codex")
SPEC = {
    "Claude": {"key": "claude", "home_env": "CLAUDE_CONFIG_DIR", "home_dir": ".claude",
               "token": ".credentials.json", "refresh": ["-p", "ok", "--model", "haiku"], "timeout": 180},
    "Codex": {"key": "codex", "home_env": "CODEX_HOME", "home_dir": ".codex",
              "token": "auth.json", "refresh": ["doctor", "--summary"], "timeout": 120},
}

UTC = dt.timezone.utc
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")


def now_utc():
    return dt.datetime.now(UTC)


# ---------------------------------------------------------------------------
# Files and logging (never log tokens, emails or account ids)
# ---------------------------------------------------------------------------
def log(message):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > 200_000:
            os.remove(LOG_FILE)
        with open(LOG_FILE, "a", encoding="utf-8") as fh:
            fh.write("%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), message))
    except OSError:
        pass  # Logging must never break the widget.


def read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
    os.replace(tmp, path)


def iso_or_none(value):
    return value.isoformat() if value is not None else None


def parse_iso(value):
    if not value:
        return None
    parsed = dt.datetime.fromisoformat(value)
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)


# ---------------------------------------------------------------------------
# Config: token file and CLI path per service, cached in config.json
# ---------------------------------------------------------------------------
def default_token_file(service):
    spec = SPEC[service]
    base = os.environ.get(spec["home_env"]) or os.path.join(HOME, spec["home_dir"])
    return os.path.join(base, spec["token"])


def find_cli(name):
    """Absolute path of a CLI, or "" when it cannot be found.

    An autostarted widget does not inherit the PATH an interactive shell builds
    (nvm, for one, loads from ~/.bashrc), so ask that shell before guessing.
    """
    found = shutil.which(name)
    if found:
        return found
    shell = os.environ.get("SHELL") or "/bin/bash"
    try:
        out = subprocess.run([shell, "-lic", "command -v " + name], stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=15, text=True).stdout
        for line in reversed(out.splitlines()):
            line = line.strip()
            if line.startswith("/") and os.access(line, os.X_OK):
                return line
    except (OSError, subprocess.SubprocessError):
        pass
    candidates = [os.path.join(HOME, ".local", "bin", name)]
    candidates += sorted(glob.glob(os.path.join(HOME, ".nvm", "versions", "node", "*", "bin", name)),
                         key=os.path.getmtime, reverse=True)
    candidates += [os.path.join(HOME, ".npm-global", "bin", name), os.path.join(HOME, ".bun", "bin", name),
                   "/usr/local/bin/" + name, "/usr/bin/" + name]
    for path in candidates:
        if os.access(path, os.X_OK):
            return path
    return ""


def resolve_sources(redetect=False):
    """Returns {service: {enabled, token_file, cli}} and caches it.

    A stored "enabled": false survives re-detection; paths are detected again
    when missing, stale, or when redetect is set.
    """
    stored = read_json(CONFIG_FILE)
    stored = stored if isinstance(stored, dict) else {}
    sources, changed = {}, False
    for service in SERVICES:
        key = SPEC[service]["key"]
        entry = stored.get(key) if isinstance(stored.get(key), dict) else {}
        token_file = entry.get("token_file") or ""
        cli = entry.get("cli") or ""
        if redetect or not token_file or not os.path.exists(token_file):
            token_file = default_token_file(service)
        if redetect or not cli or not os.access(cli, os.X_OK):
            cli = find_cli(key)
        source = {"enabled": entry.get("enabled", True) is not False, "token_file": token_file, "cli": cli}
        changed = changed or source != entry
        sources[service] = source
    if changed:
        try:
            write_json(CONFIG_FILE, {SPEC[s]["key"]: sources[s] for s in SERVICES})
        except OSError as exc:
            log("save config failed: %s" % exc)
    return sources


# ---------------------------------------------------------------------------
# Fetch
# ---------------------------------------------------------------------------
def new_result(service):
    return {"name": service, "status": "error", "message": "",  # ok | expired | error | unset | off | backoff
            "http_code": None,
            "five_hour": {"remaining": None, "resets_at": None},
            "seven_day": {"remaining": None, "resets_at": None},
            "fetched_at": None}


def to_remaining(used):
    try:
        remaining = round(100.0 - float(used))
    except (TypeError, ValueError):
        return None
    return max(0, min(100, int(remaining)))


def format_countdown(resets_at, now=None, short=False):
    """Time until a reset: "2일 3시간 후" style, or one unit ("2d", "3h", "25m")
    when short, for the top bar."""
    if resets_at is None:
        return ""
    total = int((resets_at - (now or now_utc())).total_seconds())
    if total <= 0:
        return ""
    days, hours, minutes = total // 86400, (total % 86400) // 3600, (total % 3600) // 60
    if short:
        return "%dd" % days if days else "%dh" % hours if hours else "%dm" % minutes if minutes else "<1m"
    if days >= 1:
        return "%d일 %d시간 후" % (days, hours)
    if total >= 3600:
        return "%d시간 %d분 후" % (hours, minutes)
    if total >= 60:
        return "%d분 후" % minutes
    return "1분 이내"


def http_get_json(url, headers):
    request = urllib.request.Request(url, headers=dict(headers, **{"User-Agent": USER_AGENT}))
    with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
        return json.loads(response.read().decode("utf-8"))


def _unavailable(source, result):
    if not source["enabled"]:
        result.update(status="off", message="disabled")
        return True
    if not os.path.isfile(source["token_file"]):
        result.update(status="unset", message="token file not found")
        return True
    return False


def _fail(result, exc):
    if isinstance(exc, urllib.error.HTTPError):
        result["http_code"] = exc.code
        if exc.code == 401:
            result.update(status="expired", message="token rejected (401)")
        else:
            result["message"] = "http %d" % exc.code
    else:
        result["message"] = str(getattr(exc, "reason", exc))


def claude_token_valid(source):
    cred = read_json(source["token_file"])
    oauth = cred.get("claudeAiOauth") if isinstance(cred, dict) else None
    try:
        expires = dt.datetime.fromtimestamp(int(oauth["expiresAt"]) / 1000, tz=UTC)
    except (TypeError, KeyError, ValueError):
        return False
    return expires > now_utc() + dt.timedelta(minutes=1)


def get_claude_usage(source):
    result = new_result("Claude")
    if _unavailable(source, result):
        return result
    cred = read_json(source["token_file"])
    oauth = cred.get("claudeAiOauth") if isinstance(cred, dict) else None
    if not isinstance(oauth, dict) or not oauth.get("accessToken"):
        result["message"] = "credentials not found"
        return result
    if not claude_token_valid(source):
        result.update(status="expired", message="token expired")
        return result
    try:
        resp = http_get_json(CLAUDE_USAGE_URL, {"Authorization": "Bearer " + oauth["accessToken"],
                                                "anthropic-beta": "oauth-2025-04-20",
                                                "Content-Type": "application/json"})
        five = resp.get("five_hour") if isinstance(resp, dict) else None
        seven = resp.get("seven_day") if isinstance(resp, dict) else None
        if not isinstance(five, dict) or not isinstance(seven, dict):
            result["message"] = "unexpected response shape"
            return result
        for window, data in (("five_hour", five), ("seven_day", seven)):
            result[window]["remaining"] = to_remaining(data.get("utilization"))
            result[window]["resets_at"] = parse_iso(data.get("resets_at"))
        result.update(status="ok", fetched_at=now_utc())
    except (urllib.error.URLError, OSError, ValueError) as exc:
        _fail(result, exc)
    return result


def jwt_expiry(token):
    """The exp claim of a JWT (signature not validated), or None."""
    try:
        payload = token.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        return dt.datetime.fromtimestamp(int(claims["exp"]), tz=UTC)
    except (AttributeError, IndexError, KeyError, TypeError, ValueError):
        return None


def codex_token_valid(source):
    # An undecodable expiry counts as valid so the API (401) stays the authority.
    auth = read_json(source["token_file"])
    tokens = auth.get("tokens") if isinstance(auth, dict) else None
    if not isinstance(tokens, dict):
        return False
    expires = jwt_expiry(tokens.get("access_token"))
    return expires is None or expires > now_utc() + dt.timedelta(minutes=1)


def get_codex_usage(source):
    result = new_result("Codex")
    if _unavailable(source, result):
        return result
    auth = read_json(source["token_file"])
    tokens = auth.get("tokens") if isinstance(auth, dict) else None
    if not isinstance(tokens, dict) or not tokens.get("access_token"):
        result["message"] = "auth not found"
        return result
    if not codex_token_valid(source):
        result.update(status="expired", message="token expired")
        return result
    try:
        resp = http_get_json(CODEX_USAGE_URL, {"Authorization": "Bearer " + tokens["access_token"],
                                               "ChatGPT-Account-ID": str(tokens.get("account_id") or "")})
        limits = resp.get("rate_limit") if isinstance(resp, dict) else None
        primary = limits.get("primary_window") if isinstance(limits, dict) else None
        secondary = limits.get("secondary_window") if isinstance(limits, dict) else None
        if not isinstance(primary, dict) or not isinstance(secondary, dict):
            result["message"] = "unexpected response shape"
            return result
        for window, data in (("five_hour", primary), ("seven_day", secondary)):
            result[window]["remaining"] = to_remaining(data.get("used_percent"))
            reset = data.get("reset_at")
            result[window]["resets_at"] = dt.datetime.fromtimestamp(int(reset), tz=UTC) if reset else None
        result.update(status="ok", fetched_at=now_utc())
    except (urllib.error.URLError, OSError, ValueError, TypeError) as exc:
        _fail(result, exc)
    return result


FETCHERS = {"Claude": get_claude_usage, "Codex": get_codex_usage}
TOKEN_VALID = {"Claude": claude_token_valid, "Codex": codex_token_valid}


# ---------------------------------------------------------------------------
# Token refresh: only on expiry, once per cooldown per service, via the CLI
# ---------------------------------------------------------------------------
_last_refresh = {}


def run_cli(service, source, timeout):
    """Runs the service's refresh command. Returns the exit code, -1 on
    timeout, -2 when the CLI cannot be run. Logs the stderr tail, emails masked."""
    key, args = SPEC[service]["key"], SPEC[service]["refresh"]
    cli = source.get("cli") or ""
    if not os.access(cli, os.X_OK):
        log("%s cli not found; run --configure" % key)
        return -2
    env = dict(os.environ)
    # An npm-installed CLI is a node script: keep its bin dir (holding node) on PATH.
    env["PATH"] = os.path.dirname(cli) + os.pathsep + env.get("PATH", "")
    os.makedirs(STATE_DIR, exist_ok=True)
    try:
        proc = subprocess.run([cli] + args, cwd=STATE_DIR, env=env, stdin=subprocess.DEVNULL,
                              stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=timeout)
        code, err = proc.returncode, proc.stderr
    except subprocess.TimeoutExpired as exc:
        code, err = -1, exc.stderr or b""
    except OSError as exc:
        log("%s cli failed to start: %s" % (key, exc))
        return -2
    lines = [line for line in err.decode("utf-8", "replace").splitlines() if line.strip()]
    tail = EMAIL_RE.sub("<email>", " | ".join(lines[-3:]))
    if tail:
        log("%s stderr [%s]: %s" % (key, " ".join([key] + args), tail[:400]))
    return code


def refresh_token(service, source):
    last = _last_refresh.get(service)
    if last is not None and time.monotonic() - last < REFRESH_COOLDOWN_SEC:
        return False
    _last_refresh[service] = time.monotonic()
    key = SPEC[service]["key"]
    log("%s token expired; running %s %s" % (key, key, " ".join(SPEC[service]["refresh"])))
    code = run_cli(service, source, SPEC[service]["timeout"])
    valid = TOKEN_VALID[service](source)
    log("%s refresh exit=%s token valid=%s" % (key, code, valid))
    return valid


# ---------------------------------------------------------------------------
# HTTP 429 backoff: the usage APIs rate-limit hard and send no usable Retry-After
# ---------------------------------------------------------------------------
_backoff = {}  # service -> (monotonic time of the next allowed fetch, last delay in seconds)


def in_backoff(service):
    until = _backoff.get(service, (0.0, 0))[0]
    return time.monotonic() + BACKOFF_SLACK_SEC < until


def update_backoff(service, result):
    delay = _backoff.get(service, (0.0, 0))[1]
    if result["http_code"] == 429:
        delay = min(max(delay * 2, BACKOFF_MIN_SEC), BACKOFF_MAX_SEC)
        _backoff[service] = (time.monotonic() + delay, delay)
        log("%s http 429; next try in %dm" % (SPEC[service]["key"], delay // 60))
    elif result["status"] == "ok":
        _backoff.pop(service, None)


def fetch_all(sources, allow_refresh=False, backoff=False):
    results = {}
    for service in SERVICES:
        if backoff and in_backoff(service):
            result = new_result(service)
            result.update(status="backoff", message="waiting after http 429")
        else:
            result = FETCHERS[service](sources[service])
            if allow_refresh and result["status"] == "expired" and refresh_token(service, sources[service]):
                result = FETCHERS[service](sources[service])
            if backoff:
                update_backoff(service, result)
        results[service] = result
    log("fetch " + " ".join("%s=%s%s" % (SPEC[s]["key"], results[s]["status"],
                                         " (%s)" % results[s]["message"] if results[s]["message"] else "")
                            for s in SERVICES))
    return results


# ---------------------------------------------------------------------------
# Service state (survives failed fetches) and persistence
# ---------------------------------------------------------------------------
def new_service_state():
    return {"remaining5": None, "reset5": None, "remaining7": None, "reset7": None,
            "updated_at": None, "status": "init", "message": ""}


def apply_local_resets(state, now=None):
    # Stale data only: once a window has reset, assume it is fully available.
    if state["status"] == "ok":
        return
    now = now or now_utc()
    for window in ("5", "7"):
        reset = state["reset" + window]
        if reset is not None and reset <= now:
            state["remaining" + window] = 100


def merge_result(state, result):
    if result["status"] == "backoff":  # No request was made: keep what the last one said.
        apply_local_resets(state)
        return
    state["status"], state["message"] = result["status"], result["message"]
    if result["status"] == "ok":
        state.update(remaining5=result["five_hour"]["remaining"], reset5=result["five_hour"]["resets_at"],
                     remaining7=result["seven_day"]["remaining"], reset7=result["seven_day"]["resets_at"],
                     updated_at=result["fetched_at"])
    else:
        apply_local_resets(state)


def load_state():
    settings = {"left": None, "top": None, "interval": DEFAULT_INTERVAL, "transparency": DEFAULT_TRANSPARENCY,
                "hidden": False}
    states = {service: new_service_state() for service in SERVICES}
    data = read_json(STATE_FILE)
    if not isinstance(data, dict):
        return settings, states
    try:
        if isinstance(data.get("Left"), (int, float)) and isinstance(data.get("Top"), (int, float)):
            settings["left"], settings["top"] = int(data["Left"]), int(data["Top"])
        # Drop values the menu no longer offers.
        if data.get("IntervalMinutes") in INTERVAL_CHOICES:
            settings["interval"] = data["IntervalMinutes"]
        if data.get("TransparencyPercent") in TRANSPARENCY_CHOICES:
            settings["transparency"] = data["TransparencyPercent"]
        settings["hidden"] = data.get("HiddenToPanel") is True
        saved_services = data.get("Services") if isinstance(data.get("Services"), dict) else {}
        for service in SERVICES:
            saved = saved_services.get(service)
            if not isinstance(saved, dict):
                continue
            states[service].update(remaining5=saved.get("Remaining5"), remaining7=saved.get("Remaining7"),
                                   reset5=parse_iso(saved.get("Reset5")), reset7=parse_iso(saved.get("Reset7")),
                                   updated_at=parse_iso(saved.get("UpdatedAt")),
                                   status="stale", message="from cache")
    except (TypeError, ValueError) as exc:
        log("load state failed: %s" % exc)
    return settings, states


def save_state(settings, states):
    data = {"Left": settings["left"], "Top": settings["top"], "IntervalMinutes": settings["interval"],
            "TransparencyPercent": settings["transparency"], "HiddenToPanel": settings["hidden"],
            "Services": {service: {"Remaining5": s["remaining5"], "Reset5": iso_or_none(s["reset5"]),
                                   "Remaining7": s["remaining7"], "Reset7": iso_or_none(s["reset7"]),
                                   "UpdatedAt": iso_or_none(s["updated_at"])}
                         for service, s in states.items()}}
    try:
        write_json(STATE_FILE, data)
    except OSError as exc:
        log("save state failed: %s" % exc)


# ---------------------------------------------------------------------------
# Single instance: an flock guards the UI, the pid file lets --stop find it
# ---------------------------------------------------------------------------
def running_pid():
    try:
        with open(PID_FILE, encoding="ascii") as fh:
            pid = int(fh.read().strip())
        with open("/proc/%d/cmdline" % pid, "rb") as fh:
            cmdline = fh.read().decode("utf-8", "replace")
    except (OSError, ValueError):
        return None
    # Guard against pid reuse: the process must be running this widget.
    return pid if pid != os.getpid() and APP in cmdline else None


def stop_running(wait_sec=5.0):
    pid = running_pid()
    if pid is None:
        return False
    try:
        os.kill(pid, signal.SIGTERM)
        deadline = time.monotonic() + wait_sec
        while os.path.exists("/proc/%d" % pid) and time.monotonic() < deadline:
            time.sleep(0.1)
        if os.path.exists("/proc/%d" % pid):
            os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    return True


class InstanceLock:
    def __init__(self):
        self._fh = None

    def acquire(self):
        os.makedirs(STATE_DIR, exist_ok=True)
        fh = open(LOCK_FILE, "a")
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            fh.close()
            return False
        self._fh = fh
        with open(PID_FILE, "w", encoding="ascii") as pid_fh:
            pid_fh.write(str(os.getpid()))
        return True

    def release(self):
        if self._fh is None:
            return
        try:
            os.remove(PID_FILE)
        except OSError:
            pass
        self._fh.close()
        self._fh = None
