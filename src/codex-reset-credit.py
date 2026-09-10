"""List and (optionally) consume Codex rate-limit reset credits.

There is no `codex` CLI subcommand for reset credits; the app-server JSON-RPC
API is the only interface. This tool exposes it:

  * default / --list : read account/rateLimits/read and print the available
    reset credits (no side effects).
  * --consume <creditId> : call account/rateLimitResetCredit/consume with
    {creditId, resetType} and print the fresh rate limits it returns.

CONSUMING SPENDS A CREDIT AND IS IRREVERSIBLE. It only happens with an explicit
--consume <id> and --yes. This is the mechanism an automation layer would call
when a window is exhausted and a credit is available; the policy (when to spend)
is deliberately left to the caller.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import threading
from datetime import datetime, timezone


def _codex_command() -> str:
    return "codex.cmd" if os.name == "nt" else "codex"


# Same as codex-usage.py: avoid a pop-up console when run from a console-less parent.
NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0) if os.name == "nt" else 0


class RpcError(RuntimeError):
    pass


def _send(proc: subprocess.Popen, value: dict) -> None:
    try:
        proc.stdin.write(json.dumps(value) + "\n")  # type: ignore[union-attr]
        proc.stdin.flush()  # type: ignore[union-attr]
    except (OSError, ValueError):
        pass


def rpc_call(command: str, method: str, params: dict, timeout: float) -> dict:
    """initialize -> initialized -> <method>, returning the method's result."""
    proc = subprocess.Popen(
        [command, "app-server"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        shell=os.name == "nt", text=True, encoding="utf-8", bufsize=1,
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
                        error.update(msg["error"]); done.set(); return
                    _send(proc, {"jsonrpc": "2.0", "method": "initialized"})
                    _send(proc, {"jsonrpc": "2.0", "id": 2, "method": method, "params": params})
                elif msg.get("id") == 2:
                    if isinstance(msg.get("error"), dict):
                        error.update(msg["error"])
                    elif isinstance(msg.get("result"), dict):
                        result.update(msg["result"])
                    done.set(); return
        finally:
            done.set()

    threading.Thread(target=pump, daemon=True).start()
    _send(proc, {
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
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
        raise RpcError(f"{method} error: {error.get('message', json.dumps(error))}")
    return result


def list_credits(command: str, timeout: float) -> list:
    raw = rpc_call(command, "account/rateLimits/read", {}, timeout)
    container = raw.get("rateLimitResetCredits")
    credits = container.get("credits") if isinstance(container, dict) else None
    return credits if isinstance(credits, list) else []


def _fmt_epoch(value) -> str:
    if not isinstance(value, (int, float)):
        return "?"
    return datetime.fromtimestamp(value, timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M")


def main() -> int:
    parser = argparse.ArgumentParser(description="List or consume Codex rate-limit reset credits")
    parser.add_argument("--command", default=_codex_command())
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--list", action="store_true", help="list available reset credits (default)")
    parser.add_argument("--consume", metavar="CREDIT_ID", help="consume a specific credit id (spends it; irreversible)")
    parser.add_argument("--reset-type", default="codexRateLimits")
    parser.add_argument("--yes", action="store_true", help="required confirmation for --consume")
    parser.add_argument("--json", action="store_true", help="emit JSON instead of text")
    args = parser.parse_args()

    try:
        if args.consume:
            if not args.yes:
                print("Refusing to consume without --yes (this spends a credit and is irreversible).", file=sys.stderr)
                return 2
            result = rpc_call(
                args.command,
                "account/rateLimitResetCredit/consume",
                {"creditId": args.consume, "resetType": args.reset_type},
                args.timeout,
            )
            if args.json:
                print(json.dumps(result, ensure_ascii=False, indent=1))
            else:
                limits = result.get("rateLimits", {}) if isinstance(result.get("rateLimits"), dict) else {}
                primary = limits.get("primary", {}) if isinstance(limits.get("primary"), dict) else {}
                secondary = limits.get("secondary", {}) if isinstance(limits.get("secondary"), dict) else {}
                print("Consumed credit. Fresh limits:")
                print(f"  5h used {primary.get('usedPercent')}%  weekly used {secondary.get('usedPercent')}%")
            return 0

        credits = list_credits(args.command, args.timeout)
        available = [c for c in credits if isinstance(c, dict) and c.get("status") == "available"]
        if args.json:
            print(json.dumps(credits, ensure_ascii=False, indent=1))
        else:
            print(f"{len(available)} available reset credit(s) of {len(credits)} total:")
            for c in credits:
                if not isinstance(c, dict):
                    continue
                print(f"  [{c.get('status')}] {c.get('id')}  {c.get('title')}  expires {_fmt_epoch(c.get('expiresAt'))}")
        return 0
    except RpcError as exc:
        print(f"reset-credit call failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
