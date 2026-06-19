"""Read-only local HTTP API for LLM Usage Monitor snapshots."""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from ipaddress import ip_address
from urllib.parse import urlsplit


API_VERSION = "1"
MAX_DATA_BYTES = 1024 * 1024


def load_snapshot(path: str) -> dict:
    with open(path, "rb") as stream:
        raw = stream.read(MAX_DATA_BYTES + 1)
    if len(raw) > MAX_DATA_BYTES:
        raise ValueError("snapshot is too large")
    value = json.loads(raw.decode("utf-8-sig"))
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        raise ValueError("unsupported snapshot schema")
    return value


def snapshot_age_seconds(snapshot: dict) -> float | None:
    try:
        observed = datetime.fromisoformat(str(snapshot["observed_at"]).replace("Z", "+00:00"))
        if observed.tzinfo is None:
            observed = observed.replace(tzinfo=timezone.utc)
        return max(0.0, (datetime.now(timezone.utc) - observed.astimezone(timezone.utc)).total_seconds())
    except (KeyError, TypeError, ValueError):
        return None


def make_handler(data_path: str):
    class UsageApiHandler(BaseHTTPRequestHandler):
        server_version = "LLMUsageMonitorAPI/1"

        def send_json(self, status: HTTPStatus, value: dict) -> None:
            body = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            self.send_response(status.value)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(body)

        def read_snapshot(self) -> dict | None:
            try:
                return load_snapshot(data_path)
            except (OSError, ValueError, json.JSONDecodeError):
                return None

        def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
            path = urlsplit(self.path).path.rstrip("/") or "/"
            if path == "/":
                self.send_json(
                    HTTPStatus.OK,
                    {
                        "name": "LLM Usage Monitor API",
                        "version": API_VERSION,
                        "endpoints": ["/health", "/api/v1/usage"],
                    },
                )
                return
            if path == "/health":
                snapshot = self.read_snapshot()
                age = snapshot_age_seconds(snapshot) if snapshot else None
                self.send_json(
                    HTTPStatus.OK,
                    {
                        "status": "ok" if snapshot is not None else "waiting",
                        "data_available": snapshot is not None,
                        "data_age_seconds": round(age, 3) if age is not None else None,
                    },
                )
                return
            if path == "/api/v1/usage":
                snapshot = self.read_snapshot()
                if snapshot is None:
                    self.send_json(HTTPStatus.SERVICE_UNAVAILABLE, {"error": "usage data is not available"})
                else:
                    self.send_json(HTTPStatus.OK, snapshot)
                return
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})

        def do_HEAD(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
            self.send_response(HTTPStatus.NO_CONTENT.value)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()

        def log_message(self, _format: str, *args) -> None:
            return

    return UsageApiHandler


def main() -> int:
    parser = argparse.ArgumentParser(description="Local API for LLM Usage Monitor")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=47831)
    parser.add_argument("--data", default=os.path.join(os.path.expanduser("~"), ".ai-usage", "usage.json"))
    parser.add_argument("--allow-remote", action="store_true")
    args = parser.parse_args()

    try:
        is_loopback = ip_address(args.host).is_loopback
    except ValueError:
        is_loopback = args.host.lower() == "localhost"
    if not is_loopback and not args.allow_remote:
        print("Refusing a non-loopback bind without --allow-remote", file=sys.stderr)
        return 2
    if not 0 <= args.port <= 65535:
        print("Port must be between 0 and 65535", file=sys.stderr)
        return 2

    server = ThreadingHTTPServer((args.host, args.port), make_handler(os.path.abspath(args.data)))
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
