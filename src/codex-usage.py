"""Fetch Codex rate limits from the official `codex app-server` JSON-RPC API.

Replaces scraping ~/.codex/sessions/*.jsonl for rate_limits: the app-server
`account/rateLimits/read` method returns live, authoritative windows plus the
account's rate-limit reset credits.

Handshake: initialize -> initialized notification -> account/rateLimits/read.
Output mirrors the shape UsageData.ps1 expects, with an added reset_credits list.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import threading
from datetime import datetime, timezone


def _codex_command() -> str:
    return "codex.cmd" if os.name == "nt" else "codex"


# The monitor runs this under pythonw.exe (no console). A console child spawned
# from a console-less parent gets a NEW console, which Windows Terminal (default
# terminal app) shows as a pop-up tab on every poll. CREATE_NO_WINDOW prevents it.
NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0) if os.name == "nt" else 0


class RpcError(RuntimeError):
    pass


def _send(proc: subprocess.Popen, value: dict) -> None:
    try:
        proc.stdin.write(json.dumps(value) + "\n")  # type: ignore[union-attr]
        proc.stdin.flush()  # type: ignore[union-attr]
    except (OSError, ValueError):
        pass


def read_rate_limits(command: str, timeout: float) -> dict:
    """Drive codex app-server over stdio and return the raw rateLimits result."""
    proc = subprocess.Popen(
        [command, "app-server"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        shell=os.name == "nt",  # codex.cmd is an npm shim
        text=True,
        encoding="utf-8",
        bufsize=1,
        creationflags=NO_WINDOW,
    )
    result: dict = {}
    error: dict = {}
    done = threading.Event()

    def pump() -> None:
        try:
            for line in proc.stdout:  # type: ignore[union-attr]
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(msg, dict):
                    continue
                if msg.get("id") == 1:
                    if isinstance(msg.get("error"), dict):
                        error.update(msg["error"])
                        done.set()
                        return
                    _send(proc, {"jsonrpc": "2.0", "method": "initialized"})
                    _send(proc, {"jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read", "params": {}})
                elif msg.get("id") == 2:
                    if isinstance(msg.get("error"), dict):
                        error.update(msg["error"])
                    elif isinstance(msg.get("result"), dict):
                        result.update(msg["result"])
                    done.set()
                    return
        finally:
            done.set()

    reader = threading.Thread(target=pump, daemon=True)
    reader.start()
    _send(proc, {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {"clientInfo": {"name": "LLMUsageMonitor", "title": "LLMUsageMonitor", "version": "1.0"}},
    })

    finished = done.wait(timeout=timeout)
    try:
        proc.kill()
    except OSError:
        pass
    if not finished:
        raise RpcError(f"codex app-server timed out after {timeout}s")
    if error:
        raise RpcError(f"codex app-server error: {error.get('message', json.dumps(error))}")
    if not result:
        stderr = (proc.stderr.read() if proc.stderr else "") or ""
        raise RpcError(f"codex app-server returned no rate limits{': ' + stderr.strip()[:300] if stderr.strip() else ''}")
    return result


def _window(source) -> dict:
    if not isinstance(source, dict):
        return {"used_percent": None, "left_percent": None, "resets_at_epoch": None, "window_minutes": None}
    used = source.get("usedPercent")
    used_f = float(used) if isinstance(used, (int, float)) else None
    resets = source.get("resetsAt")
    window = source.get("windowDurationMins")
    return {
        "used_percent": used_f,
        "left_percent": (100.0 - used_f) if used_f is not None else None,
        "resets_at_epoch": int(resets) if isinstance(resets, (int, float)) else None,
        "window_minutes": int(window) if isinstance(window, (int, float)) else None,
    }


def _reset_credits(raw: dict) -> list:
    container = raw.get("rateLimitResetCredits")
    credits = container.get("credits") if isinstance(container, dict) else None
    if not isinstance(credits, list):
        return []
    out = []
    for credit in credits:
        if not isinstance(credit, dict):
            continue
        out.append({
            "id": credit.get("id"),
            "reset_type": credit.get("resetType"),
            "status": credit.get("status"),
            "title": credit.get("title"),
            "granted_at_epoch": credit.get("grantedAt"),
            "expires_at_epoch": credit.get("expiresAt"),
        })
    return out


def normalize(raw: dict) -> dict:
    limits = raw.get("rateLimits") if isinstance(raw.get("rateLimits"), dict) else raw
    credits = _reset_credits(raw)
    available = [c for c in credits if c.get("status") == "available"]
    return {
        "provider": "codex",
        "model": None,
        "plan": limits.get("planType") if isinstance(limits, dict) else None,
        "five_hour": _window(limits.get("primary") if isinstance(limits, dict) else None),
        "weekly": _window(limits.get("secondary") if isinstance(limits, dict) else None),
        "context_window": None,
        "reset_credits": {"available_count": len(available), "credits": credits},
        "source": "codex_app_server_ratelimits",
        "captured_at": datetime.now(timezone.utc).astimezone().isoformat(),
    }


def atomic_json_write(path: str, value: dict) -> None:
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".codex-usage-", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, separators=(",", ":"))
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main() -> int:
    default_output = os.path.join(os.path.expanduser("~"), ".ai-usage", "codex-usage.json")
    parser = argparse.ArgumentParser(description="Fetch Codex rate limits via app-server")
    parser.add_argument("--output", default=default_output)
    parser.add_argument("--command", default=_codex_command())
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--print", action="store_true", dest="print_only")
    args = parser.parse_args()

    try:
        normalized = normalize(read_rate_limits(args.command, args.timeout))
    except RpcError as exc:
        print(f"Codex usage update failed: {exc}", file=sys.stderr)
        return 1

    if args.print_only:
        print(json.dumps(normalized, ensure_ascii=False, indent=1))
        return 0

    atomic_json_write(os.path.abspath(args.output), normalized)
    five = normalized["five_hour"]["used_percent"]
    week = normalized["weekly"]["used_percent"]
    credits = normalized["reset_credits"]["available_count"]
    print(f"Codex usage updated: 5h={five}% 7d={week}% reset_credits={credits}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
