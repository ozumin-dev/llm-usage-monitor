"""Fetch Antigravity (agy) subscription usage via `agy -p /usage`.

agy exposes no structured usage API; its /usage slash command prints a small
table with two quota families (Gemini; Claude and GPT), each with a weekly and
a five-hour window, reported as REMAINING percent plus an ISO reset time.

We run agy in headless JSON mode, take the report text from the "response"
field, and parse it into the same window shape the rest of the monitor uses
(used_percent = 100 - remaining). The Gemini family is surfaced as the primary
five_hour/weekly (the bridge drives agy with Gemini models); the Claude+GPT
family is included as an extra block.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone


def _agy_command() -> str:
    if os.name == "nt":
        local = os.environ.get("LOCALAPPDATA")
        if local:
            candidate = os.path.join(local, "agy", "bin", "agy.exe")
            if os.path.exists(candidate):
                return candidate
    return "agy"


# Under pythonw.exe (no console) a console child gets a NEW console, which Windows
# Terminal shows as a pop-up tab on every poll. CREATE_NO_WINDOW prevents it.
NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0) if os.name == "nt" else 0


def _agy_env() -> dict:
    # agy periodically forks "agy.exe --bg-updater", which opens a NEW console that
    # CREATE_NO_WINDOW on the parent cannot hide (seen as a Windows Terminal flash on
    # every update check). Disable the auto-updater for this non-interactive call only;
    # the user's interactive agy keeps updating itself.
    env = dict(os.environ)
    env["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
    return env


class AgyError(RuntimeError):
    pass


LINE_RE = re.compile(
    r"^(?P<family>.+?)\s+(?P<window>Weekly|Five Hour)\s+Limit\s+Remaining\s+(?P<remaining>\d+(?:\.\d+)?)%\s+(?P<reset>\S+)\s*$",
    re.IGNORECASE,
)


def _iso_to_epoch(value: str):
    try:
        return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return None


def _window_from_remaining(remaining: float, reset_iso: str, window_minutes: int) -> dict:
    remaining = max(0.0, min(100.0, remaining))
    return {
        "used_percent": round(100.0 - remaining, 2),
        "left_percent": round(remaining, 2),
        "resets_at_epoch": _iso_to_epoch(reset_iso),
        "window_minutes": window_minutes,
    }


def run_usage_report(command: str, timeout: float) -> str:
    # Prompt must be argv; /usage needs slash-command expansion (do not disable it).
    proc = subprocess.run(
        [command, "-p", "/usage", "--output-format", "json"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=timeout,
        creationflags=NO_WINDOW,
        env=_agy_env(),
    )
    if proc.returncode != 0:
        raise AgyError(f"agy exited {proc.returncode}: {(proc.stderr or '').strip()[:300]}")
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise AgyError(f"agy did not return JSON: {exc}") from None
    if payload.get("status") != "SUCCESS":
        raise AgyError(f"agy /usage status {payload.get('status')}: {payload.get('error')}")
    report = payload.get("response")
    if not isinstance(report, str) or not report.strip():
        raise AgyError("agy /usage returned an empty report")
    return report


def parse_report(report: str) -> dict:
    families: dict[str, dict] = {}
    for raw_line in report.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        match = LINE_RE.match(line)
        if not match:
            continue
        family_label = match.group("family").strip()
        key = "gemini" if "gemini" in family_label.lower() else "claude_gpt" if (
            "claude" in family_label.lower() or "gpt" in family_label.lower()
        ) else family_label.lower().replace(" ", "_")
        remaining = float(match.group("remaining"))
        is_weekly = match.group("window").lower().startswith("week")
        window = _window_from_remaining(remaining, match.group("reset"), 10080 if is_weekly else 300)
        bucket = families.setdefault(key, {"label": family_label, "five_hour": None, "weekly": None})
        bucket["weekly" if is_weekly else "five_hour"] = window
    if not families:
        raise AgyError("agy /usage report had no recognizable limit lines")
    return families


def normalize(families: dict) -> dict:
    primary = families.get("gemini") or next(iter(families.values()))
    return {
        "provider": "antigravity",
        "model": primary.get("label"),
        "plan": None,
        "five_hour": primary.get("five_hour"),
        "weekly": primary.get("weekly"),
        "context_window": None,
        "families": families,
        "source": "agy_usage_report",
        "captured_at": datetime.now(timezone.utc).astimezone().isoformat(),
    }


def atomic_json_write(path: str, value: dict) -> None:
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".agy-usage-", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, separators=(",", ":"))
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def error_path_for(output_path: str) -> str:
    return os.path.splitext(output_path)[0] + ".error.json"


def record_fetch_error(output_path: str, message: str, hint: str | None = None) -> None:
    """Leave <output>.error.json for the monitor so a failing fetch is shown
    instead of silently keeping the last good data. `since` and `count` span
    the current run of consecutive failures."""
    path = error_path_for(output_path)
    now = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
    since, count = now, 0
    try:
        with open(path, encoding="utf-8") as stream:
            previous = json.load(stream)
        since = previous.get("since") or now
        count = int(previous.get("count") or 0)
    except (OSError, ValueError, AttributeError):
        pass
    value = {"message": message, "since": since, "last_at": now, "count": count + 1}
    if hint:
        value["hint"] = hint
    try:
        atomic_json_write(path, value)
    except OSError:
        pass


def clear_fetch_error(output_path: str) -> None:
    try:
        os.unlink(error_path_for(output_path))
    except OSError:
        pass


def main() -> int:
    default_output = os.path.join(os.path.expanduser("~"), ".ai-usage", "agy-usage.json")
    parser = argparse.ArgumentParser(description="Fetch Antigravity usage via agy /usage")
    parser.add_argument("--output", default=default_output)
    parser.add_argument("--command", default=_agy_command())
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("--print", action="store_true", dest="print_only")
    args = parser.parse_args()

    try:
        normalized = normalize(parse_report(run_usage_report(args.command, args.timeout)))
    except Exception as exc:  # noqa: BLE001 - every failure must reach the monitor
        detail = str(exc) if isinstance(exc, (AgyError, subprocess.TimeoutExpired)) else f"{type(exc).__name__}: {exc}"
        print(f"Antigravity usage update failed: {detail}", file=sys.stderr)
        if not args.print_only:
            record_fetch_error(os.path.abspath(args.output), detail)
        return 1

    if args.print_only:
        print(json.dumps(normalized, ensure_ascii=False, indent=1))
        return 0

    atomic_json_write(os.path.abspath(args.output), normalized)
    clear_fetch_error(os.path.abspath(args.output))
    gem = normalized["five_hour"]
    gw = normalized["weekly"]
    print(
        "Antigravity usage updated: gemini 5h_left={0}% weekly_left={1}%".format(
            gem["left_percent"] if gem else "?",
            gw["left_percent"] if gw else "?",
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
