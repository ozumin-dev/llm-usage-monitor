"""Fetch Claude subscription usage without starting an inference session.

OAuth tokens are read from Claude Code's own credential file, kept in memory,
and sent only to Anthropic's official OAuth and usage endpoints.  The output
file contains usage percentages and reset times only.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone


CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
TOKEN_URL = "https://platform.claude.com/v1/oauth/token"
USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
USER_AGENT = "LLMUsageMonitor/1.0"


class UsageError(RuntimeError):
    pass


def request_json(url: str, *, headers: dict[str, str], body: dict | None = None) -> dict:
    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(url, data=data, headers=headers, method="POST" if data else "GET")
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        raise UsageError(f"HTTP {exc.code} from Anthropic") from None
    except urllib.error.URLError as exc:
        raise UsageError(f"Could not reach Anthropic: {exc.reason}") from None


def atomic_json_write(path: str, value: dict) -> None:
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".llm-usage-", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, separators=(",", ":"))
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def refresh_access_token(root: dict, credential_path: str) -> str:
    oauth = root.get("claudeAiOauth")
    if not isinstance(oauth, dict) or not oauth.get("refreshToken"):
        raise UsageError("Claude Code OAuth credentials are unavailable")

    token = request_json(
        TOKEN_URL,
        headers={"Content-Type": "application/json", "Accept": "application/json", "User-Agent": USER_AGENT},
        body={"grant_type": "refresh_token", "refresh_token": oauth["refreshToken"], "client_id": CLIENT_ID},
    )
    access_token = token.get("access_token")
    if not access_token:
        raise UsageError("Anthropic did not return an access token")

    # Do not overwrite credentials rotated by Claude while this request was in
    # flight. Prefer the newer on-disk token when another process refreshed it.
    try:
        with open(credential_path, encoding="utf-8") as stream:
            current_root = json.load(stream)
        current_oauth = current_root.get("claudeAiOauth", {})
        if current_oauth.get("refreshToken") != oauth.get("refreshToken") and int(
            current_oauth.get("expiresAt", 0)
        ) > int(time.time() * 1000) + 120_000:
            return current_oauth["accessToken"]
        root = current_root
        oauth = root.setdefault("claudeAiOauth", {})
    except (OSError, json.JSONDecodeError):
        pass

    oauth["accessToken"] = access_token
    if token.get("refresh_token"):
        oauth["refreshToken"] = token["refresh_token"]
    oauth["expiresAt"] = int(time.time() * 1000) + int(token.get("expires_in", 3600)) * 1000
    if token.get("scope"):
        oauth["scopes"] = token["scope"]
    atomic_json_write(credential_path, root)
    return access_token


def epoch_seconds(value) -> int | None:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return int(value)
    try:
        return int(datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp())
    except ValueError:
        return None


def normalize_window(window) -> dict:
    if not isinstance(window, dict) or window.get("utilization") is None:
        return {"used_percent": None, "left_percent": None, "resets_at_epoch": None}
    used = max(0.0, min(100.0, float(window["utilization"])))
    return {
        "used_percent": used,
        "left_percent": 100.0 - used,
        "resets_at_epoch": epoch_seconds(window.get("resets_at")),
    }


def fetch_usage(credential_path: str) -> dict:
    try:
        with open(credential_path, encoding="utf-8") as stream:
            root = json.load(stream)
    except (OSError, json.JSONDecodeError) as exc:
        raise UsageError(f"Could not read Claude credentials: {type(exc).__name__}") from None

    oauth = root.get("claudeAiOauth")
    if not isinstance(oauth, dict) or not oauth.get("accessToken"):
        raise UsageError("Claude Code is not signed in")

    access_token = oauth["accessToken"]
    if int(oauth.get("expiresAt", 0)) <= int(time.time() * 1000) + 120_000:
        access_token = refresh_access_token(root, credential_path)

    headers = {
        "Authorization": "Bearer " + access_token,
        "Accept": "application/json",
        "Content-Type": "application/json",
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": USER_AGENT,
    }
    try:
        return request_json(USAGE_URL, headers=headers)
    except UsageError as exc:
        if "HTTP 401" not in str(exc):
            raise
        # Claude may have rotated the token in another process. Reload once,
        # then perform the same official refresh flow.
        with open(credential_path, encoding="utf-8") as stream:
            root = json.load(stream)
        access_token = refresh_access_token(root, credential_path)
        headers["Authorization"] = "Bearer " + access_token
        return request_json(USAGE_URL, headers=headers)


def main() -> int:
    default_credentials = os.path.join(os.path.expanduser("~"), ".claude", ".credentials.json")
    default_output = os.path.join(os.path.expanduser("~"), ".ai-usage", "claude-desktop-usage.json")
    parser = argparse.ArgumentParser()
    parser.add_argument("--credentials", default=default_credentials)
    parser.add_argument("--output", default=default_output)
    args = parser.parse_args()

    try:
        usage = fetch_usage(os.path.abspath(args.credentials))
        result = {
            "provider": "claude_desktop_code",
            "model": "Claude Desktop Code",
            "five_hour": normalize_window(usage.get("five_hour")),
            "weekly": normalize_window(usage.get("seven_day")),
            "context_window": None,
            "source": "claude_oauth_usage_api",
            "captured_at": datetime.now(timezone.utc).astimezone().isoformat(),
        }
        atomic_json_write(os.path.abspath(args.output), result)
        five = result["five_hour"]["used_percent"]
        week = result["weekly"]["used_percent"]
        print(f"Claude usage updated: 5h={five}% 7d={week}%")
        return 0
    except UsageError as exc:
        print(f"Claude usage update failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
