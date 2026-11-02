#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import hmac
import json
import os
import subprocess
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


HOST = os.environ.get("PORTFOLIO_WEBHOOK_HOST", "127.0.0.1")
PORT = int(os.environ.get("PORTFOLIO_WEBHOOK_PORT", "9010"))
SECRET = os.environ["PORTFOLIO_WEBHOOK_SECRET"]
MAX_BODY_BYTES = 5 * 1024 * 1024
EXPECTED_EVENT = os.environ.get("PORTFOLIO_WEBHOOK_EVENT", "push")
EXPECTED_REF = os.environ.get("PORTFOLIO_WEBHOOK_REF", "refs/heads/main")
REPO_DIR = Path(os.environ.get("PORTFOLIO_WEBHOOK_REPO_DIR", "/opt/portfolio-deploy"))
DEPLOY_SCRIPT = os.environ.get(
    "PORTFOLIO_WEBHOOK_DEPLOY_SCRIPT",
    str(REPO_DIR / "scripts" / "github-webhook-deploy.sh"),
)
STATE_DIR = Path(
    os.environ.get("PORTFOLIO_WEBHOOK_STATE_DIR", "/var/lib/portfolio-webhook")
)
DELIVERY_DIR = STATE_DIR / "deliveries"
LOG_FILE = Path(
    os.environ.get(
        "PORTFOLIO_WEBHOOK_LOG_FILE", "/var/log/portfolio-webhook/deploy.log"
    )
)


def json_response(
    handler: BaseHTTPRequestHandler, status: HTTPStatus, payload: dict[str, object]
) -> None:
    body = json.dumps(payload).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def verify_signature(body: bytes, signature: str | None) -> bool:
    if not signature or not signature.startswith("sha256="):
        return False
    expected = (
        "sha256=" + hmac.new(SECRET.encode("utf-8"), body, hashlib.sha256).hexdigest()
    )
    return hmac.compare_digest(expected, signature)


def mark_delivery(delivery_id: str) -> bool:
    DELIVERY_DIR.mkdir(parents=True, exist_ok=True)
    marker = DELIVERY_DIR / hashlib.sha256(delivery_id.encode("utf-8")).hexdigest()
    try:
        marker.touch(exist_ok=False)
    except FileExistsError:
        return False
    return True


def spawn_deploy(delivery_id: str) -> None:
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with LOG_FILE.open("ab") as log_handle:
        subprocess.Popen(
            [DEPLOY_SCRIPT, delivery_id],
            cwd=str(REPO_DIR),
            stdout=log_handle,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            env={
                **os.environ,
                "PORTFOLIO_WEBHOOK_REPO_DIR": str(REPO_DIR),
                "PORTFOLIO_WEBHOOK_LOG_FILE": str(LOG_FILE),
            },
        )


class Handler(BaseHTTPRequestHandler):
    server_version = "PortfolioWebhook/1.0"

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            json_response(self, HTTPStatus.OK, {"ok": True, "ref": EXPECTED_REF})
            return
        json_response(self, HTTPStatus.NOT_FOUND, {"ok": False, "error": "not_found"})

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/":
            json_response(
                self, HTTPStatus.NOT_FOUND, {"ok": False, "error": "not_found"}
            )
            return

        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            json_response(
                self, HTTPStatus.BAD_REQUEST, {"ok": False, "error": "invalid_length"}
            )
            return

        if content_length <= 0 or content_length > MAX_BODY_BYTES:
            json_response(
                self,
                HTTPStatus.REQUEST_ENTITY_TOO_LARGE,
                {"ok": False, "error": "invalid_length"},
            )
            return

        body = self.rfile.read(content_length)

        if not verify_signature(body, self.headers.get("X-Hub-Signature-256")):
            json_response(
                self,
                HTTPStatus.UNAUTHORIZED,
                {"ok": False, "error": "invalid_signature"},
            )
            return

        event = self.headers.get("X-GitHub-Event")
        if event != EXPECTED_EVENT:
            json_response(
                self,
                HTTPStatus.ACCEPTED,
                {"ok": True, "ignored": True, "reason": "event"},
            )
            return

        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            json_response(
                self, HTTPStatus.BAD_REQUEST, {"ok": False, "error": "invalid_json"}
            )
            return

        if payload.get("ref") != EXPECTED_REF:
            json_response(
                self,
                HTTPStatus.ACCEPTED,
                {"ok": True, "ignored": True, "reason": "ref"},
            )
            return

        delivery_id = self.headers.get("X-GitHub-Delivery") or "unknown"
        if not mark_delivery(delivery_id):
            json_response(
                self,
                HTTPStatus.OK,
                {"ok": True, "duplicate": True, "delivery": delivery_id},
            )
            return

        spawn_deploy(delivery_id)
        json_response(
            self,
            HTTPStatus.ACCEPTED,
            {"ok": True, "queued": True, "delivery": delivery_id},
        )

    def log_message(self, format: str, *args: object) -> None:
        return


if __name__ == "__main__":
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    server.serve_forever()
