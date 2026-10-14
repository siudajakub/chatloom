#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Personal Matrix event_id_only -> FCM HTTP v1 gateway. No chat content."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import logging
import os
from pathlib import Path
import re
import socket
import sqlite3
import stat
import threading
import time
from typing import Callable
import urllib.error
import urllib.request

APP_ID = "pl.personal.chat"
ENDPOINT = "/_matrix/push/v1/notify"
REMINDER_ENDPOINT = "/internal/reminder"
MAX_FCM_DATA_BYTES = 3500
LOG = logging.getLogger("personal-push")


class GatewayError(Exception):
    def __init__(self, status: int, code: str, retry_after: int | None = None):
        self.status, self.code, self.retry_after = status, code, retry_after
        super().__init__(code)


class ConfigError(Exception):
    def __str__(self):
        return "Invalid private push configuration"


def private_json(path: str | Path, maximum: int = 65536) -> dict:
    """Read only an explicitly selected regular owner-only file, no symlinks."""
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077:
            raise ConfigError()
        if info.st_uid not in (os.geteuid(), 0):
            raise ConfigError()
        with os.fdopen(fd, "rb", closefd=False) as file:
            raw = file.read(maximum + 1)
        if len(raw) > maximum:
            raise ConfigError()
        value = json.loads(raw)
        if not isinstance(value, dict):
            raise ConfigError()
        return value
    finally:
        os.close(fd)


@dataclass(frozen=True, repr=False)
class Registration:
    pushkey: str
    app_id: str
    nonce: str


@dataclass(frozen=True, repr=False)
class Config:
    project_id: str
    service_account_file: str
    registrations: tuple[Registration, ...]
    state_directory: str = "/var/lib/personal-push-gateway"
    bind: str = "127.0.0.1"
    port: int = 8088
    max_body_bytes: int = 16384
    max_devices: int = 8
    rate_per_minute: int = 120
    max_concurrency: int = 8
    request_timeout_seconds: int = 8
    provider_timeout_seconds: int = 8
    dedup_seconds: int = 86400
    max_dedup_entries: int = 20000
    reminder_credential_file: str | None = None

    @classmethod
    def load(cls, path: str | Path) -> Config:
        try:
            value = private_json(path)
            registrations = tuple(Registration(**item) for item in value.pop("registrations"))
            config = cls(registrations=registrations, **value)
            config.validate()
            return config
        except Exception:
            raise ConfigError() from None

    def validate(self):
        if self.bind not in ("127.0.0.1", "::1"):
            raise ConfigError()
        if not re.fullmatch(r"[a-z][a-z0-9-]{4,28}[a-z0-9]", self.project_id):
            raise ConfigError()
        if not Path(self.service_account_file).is_absolute() or not Path(self.state_directory).is_absolute():
            raise ConfigError()
        if self.reminder_credential_file is not None and not Path(self.reminder_credential_file).is_absolute():
            raise ConfigError()
        for name, low, high in (
            ("port", 1, 65535), ("max_body_bytes", 1024, 65536),
            ("max_devices", 1, 8), ("rate_per_minute", 1, 600),
            ("max_concurrency", 1, 16), ("request_timeout_seconds", 1, 15),
            ("provider_timeout_seconds", 1, 15), ("dedup_seconds", 60, 604800),
            ("max_dedup_entries", 100, 100000),
        ):
            val = getattr(self, name)
            if type(val) is not int or not low <= val <= high:
                raise ConfigError()
        if len(self.registrations) > 16:
            raise ConfigError()
        unique = set()
        for reg in self.registrations:
            if not isinstance(reg.pushkey, str) or not 16 <= len(reg.pushkey) <= 2048:
                raise ConfigError()
            if reg.pushkey in unique or not valid_app_id(reg.app_id):
                raise ConfigError()
            unique.add(reg.pushkey)
            if not isinstance(reg.nonce, str) or not re.fullmatch(r"[A-Za-z0-9_-]{43,128}", reg.nonce):
                raise ConfigError()


def valid_app_id(value):
    return isinstance(value, str) and len(value) <= 64 and bool(
        re.fullmatch(r"pl\.personal\.chat(?:\.[A-Za-z0-9_-]+)?", value)
    )


def count_data(value):
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise GatewayError(400, "M_BAD_JSON")
    output = {}
    for key in ("unread", "missed_calls"):
        if key not in value:
            continue
        val = value[key]
        if type(val) is not int or not 0 <= val <= 2147483647:
            raise GatewayError(400, "M_BAD_JSON")
        output[key] = val
    return output


def routing_data(notification):
    """FCM v1 data values are strings; SDK accepts counts/devices JSON strings."""
    counts = count_data(notification.get("counts"))
    output = {"counts": json.dumps(counts, separators=(",", ":")), "devices": "[]"}
    event, room = notification.get("event_id"), notification.get("room_id")
    if event is not None:
        if not isinstance(event, str) or not event.startswith("$") or not 2 <= len(event.encode()) <= 512:
            raise GatewayError(400, "M_BAD_JSON")
        if not isinstance(room, str) or not room.startswith("!") or not 2 <= len(room.encode()) <= 512:
            raise GatewayError(400, "M_BAD_JSON")
        output.update(event_id=event, room_id=room)
    elif room is not None:
        raise GatewayError(400, "M_BAD_JSON")
    if len(json.dumps(output, separators=(",", ":")).encode()) > MAX_FCM_DATA_BYTES:
        raise GatewayError(413, "M_TOO_LARGE")
    # content, sender, sender_display_name, room_name, tweaks and pusher data are
    # never copied. No default_payload extension can bypass this allowlist.
    return output


@dataclass(frozen=True)
class PublishResult:
    status: str  # accepted | rejected | transient
    retry_after: int = 60


def provider_result(status: int, body: bytes, retry_after: str | None = None):
    if 200 <= status < 300:
        return PublishResult("accepted")
    delay = 60
    if retry_after is not None and retry_after.isdigit():
        delay = max(60, min(int(retry_after), 3600))
    try:
        payload = json.loads(body)
        details = payload.get("error", {}).get("details", [])
        fcm_codes = {entry.get("errorCode") for entry in details if isinstance(entry, dict)
                     and entry.get("@type") == "type.googleapis.com/google.firebase.fcm.v1.FcmError"}
    except (ValueError, AttributeError, TypeError):
        fcm_codes = set()
    # Generic 400/403/404 may be payload/project/IAM errors. Do not revoke valid
    # pushers merely because gateway configuration/provider authentication failed.
    if "UNREGISTERED" in fcm_codes or "SENDER_ID_MISMATCH" in fcm_codes:
        return PublishResult("rejected")
    return PublishResult("transient", delay)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, url):
        return None


def http_request(url, *, method="GET", body=None, headers=None, timeout=8):
    request = urllib.request.Request(url, data=body, headers=headers or {}, method=method)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with opener.open(request, timeout=timeout) as response:
            data = response.read(65537)
            if len(data) > 65536:
                raise GatewayError(503, "M_UNAVAILABLE", 60)
            return response.status, dict(response.headers), data
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers), error.read(65536)


class OAuthRequest:
    """google-auth transport.Request adapter; auth never leaves Google OAuth."""
    def __init__(self, timeout):
        self.timeout = timeout

    def __call__(self, url, method="GET", body=None, headers=None, timeout=None, **kwargs):
        from google.auth.exceptions import TransportError
        if url != "https://oauth2.googleapis.com/token":
            raise TransportError("OAuth endpoint blocked")
        try:
            status, response_headers, data = http_request(url, method=method, body=body,
                headers=headers, timeout=min(timeout or self.timeout, self.timeout))
            return type("OAuthResponse", (), {"status": status, "headers": response_headers, "data": data})()
        except Exception:
            raise TransportError("OAuth transport failed") from None


class FcmPublisher:
    def __init__(self, config: Config):
        from google.oauth2 import service_account
        info = private_json(config.service_account_file)
        if (info.get("type") != "service_account" or info.get("project_id") != config.project_id
                or info.get("token_uri") != "https://oauth2.googleapis.com/token"
                or not isinstance(info.get("client_email"), str)
                or not info["client_email"].endswith(f"@{config.project_id}.iam.gserviceaccount.com")
                or info.get("universe_domain", "googleapis.com") != "googleapis.com"):
            raise ConfigError()
        self.credentials = service_account.Credentials.from_service_account_info(
            info, scopes=["https://www.googleapis.com/auth/firebase.messaging"])
        self.project_id = config.project_id
        self.timeout = config.provider_timeout_seconds
        self.auth_request = OAuthRequest(self.timeout)
        self.auth_lock = threading.Lock()

    def publish(self, token: str, data: dict[str, str], priority: str):
        url = f"https://fcm.googleapis.com/v1/projects/{self.project_id}/messages:send"
        try:
            headers = {"Content-Type": "application/json"}
            with self.auth_lock:
                self.credentials.before_request(self.auth_request, "POST", url, headers)
            body = {"message": {"token": token, "data": data,
                "android": {"priority": priority, "ttl": "3600s", "restricted_package_name": APP_ID}}}
            status, response_headers, response_body = http_request(url, method="POST",
                body=json.dumps(body, separators=(",", ":")).encode(), headers=headers, timeout=self.timeout)
            return provider_result(status, response_body, response_headers.get("Retry-After"))
        except Exception:
            return PublishResult("transient")


class Gateway:
    def __init__(self, config: Config, publisher, *, clock: Callable = time.time):
        config.validate()
        self.config, self.publisher, self.clock = config, publisher, clock
        self.registrations = {reg.pushkey: reg for reg in config.registrations}
        self.invalid_tokens = set()
        self.lock = threading.Lock()
        self.rate = {}  # only SHA-256 digests of registered tokens, bounded by config
        self.reminder_token = None
        if config.reminder_credential_file is not None:
            token = private_json(config.reminder_credential_file).get("token")
            if not isinstance(token, str) or not re.fullmatch(r"[A-Za-z0-9_-]{43,128}", token):
                raise ConfigError()
            self.reminder_token = token
        state = Path(config.state_directory)
        state.mkdir(mode=0o700, parents=True, exist_ok=True)
        if state.stat().st_mode & 0o077:
            raise ConfigError()
        self.db_path = state / "push_state.sqlite"
        with self.database() as db:
            db.execute("CREATE TABLE IF NOT EXISTS accepted (digest TEXT PRIMARY KEY, expires REAL NOT NULL)")
            db.execute("CREATE TABLE IF NOT EXISTS invalid (digest TEXT PRIMARY KEY)")
            self.invalid_tokens = {r[0] for r in db.execute("SELECT digest FROM invalid")}

    @contextmanager
    def database(self):
        db = sqlite3.connect(self.db_path, timeout=2)
        try:
            with db:
                yield db
        finally:
            db.close()

    def notify(self, packet):
        if not isinstance(packet, dict) or not isinstance(packet.get("notification"), dict):
            raise GatewayError(400, "M_BAD_JSON")
        notification = packet["notification"]
        data = routing_data(notification)
        devices = notification.get("devices")
        if not isinstance(devices, list) or len(devices) > self.config.max_devices:
            raise GatewayError(400, "M_BAD_JSON")
        authorized, rejected = [], []
        for device in devices:
            if not isinstance(device, dict) or not isinstance(device.get("pushkey"), str):
                raise GatewayError(400, "M_BAD_JSON")
            key = device["pushkey"]
            if not 1 <= len(key) <= 2048:
                raise GatewayError(400, "M_BAD_JSON")
            reg = self.registrations.get(key)
            if reg is None or device.get("app_id") != reg.app_id:
                rejected.append(key)
                continue
            extra = device.get("data")
            if not isinstance(extra, dict) or extra.get("format") != "event_id_only":
                raise GatewayError(400, "M_BAD_JSON")
            nonce = extra.get("gateway_nonce")
            if not isinstance(nonce, str) or not hmac.compare_digest(nonce.encode(), reg.nonce.encode()):
                raise GatewayError(403, "M_FORBIDDEN")
            if key not in authorized:
                authorized.append(key)
        transient = None
        # Serialize dedup/rate bookkeeping and publish so concurrent repeats
        # never generate another confirmed FCM send for the same device/event.
        with self.lock, self.database() as db:
            now = self.clock()
            db.execute("DELETE FROM accepted WHERE expires <= ?", (now,))
            for key in authorized:
                token_digest = hashlib.sha256(key.encode()).hexdigest()
                if token_digest in self.invalid_tokens:
                    rejected.append(key)
                    continue
                event = data.get("event_id")
                digest = hashlib.sha256(json.dumps([key, data.get("room_id"), event],
                    separators=(",", ":")).encode()).hexdigest() if event else None
                if digest and db.execute("SELECT 1 FROM accepted WHERE digest = ?", (digest,)).fetchone():
                    continue
                minute = int(now // 60)
                old_minute, old_count = self.rate.get(token_digest, (minute, 0))
                count = old_count if old_minute == minute else 0
                if count >= self.config.rate_per_minute:
                    transient = max(transient or 0, 60)
                    continue
                self.rate[token_digest] = (minute, count + 1)
                priority = "high" if event and notification.get("prio", "high") == "high" else "normal"
                try:
                    outcome = self.publisher.publish(key, dict(data), priority)
                except Exception:
                    outcome = PublishResult("transient")
                if outcome.status == "rejected":
                    rejected.append(key)
                    self.invalid_tokens.add(token_digest)
                    db.execute("INSERT OR IGNORE INTO invalid VALUES (?)", (token_digest,))
                elif outcome.status == "accepted" and digest:
                    db.execute("INSERT OR REPLACE INTO accepted VALUES (?, ?)",
                        (digest, now + self.config.dedup_seconds))
                    db.execute("DELETE FROM accepted WHERE digest IN ("
                        "SELECT digest FROM accepted ORDER BY expires DESC, digest DESC LIMIT -1 OFFSET ?)",
                        (self.config.max_dedup_entries,))
                elif outcome.status != "accepted":
                    transient = max(transient or 0, outcome.retry_after)
            if transient:
                # Commit accepted other devices before asking the homeserver to
                # retry. Invalid tokens remain rejected on that subsequent retry.
                db.commit()
                raise GatewayError(503, "M_UNAVAILABLE", transient)
        return {"rejected": list(dict.fromkeys(rejected))}

    def reminder(self, packet, authorization, peer):
        if self.reminder_token is None:
            raise GatewayError(404, "M_UNRECOGNIZED")
        if peer not in ("127.0.0.1", "::1"):
            raise GatewayError(403, "M_FORBIDDEN")
        expected = f"Bearer {self.reminder_token}"
        if not isinstance(authorization, str) or not hmac.compare_digest(authorization.encode(), expected.encode()):
            raise GatewayError(403, "M_FORBIDDEN")
        if not isinstance(packet, dict) or set(packet) != {"hintId", "emittedAt"}:
            raise GatewayError(400, "M_BAD_JSON")
        hint = packet["hintId"]
        if not isinstance(hint, str) or not re.fullmatch(r"[a-f0-9]{64}", hint):
            raise GatewayError(400, "M_BAD_JSON")
        try:
            stamp = packet["emittedAt"]
            if not isinstance(stamp, str) or len(stamp) > 40:
                raise ValueError()
            parsed = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
            if parsed.tzinfo is None or parsed.utcoffset() != timedelta(0):
                raise ValueError()
        except (TypeError, ValueError):
            raise GatewayError(400, "M_BAD_JSON") from None
        # No permanent age expiry: a worker may retain a due hint while devices
        # are being configured. emittedAt is validated but never logged/stored.
        with self.lock, self.database() as db:
            now = self.clock()
            db.execute("DELETE FROM accepted WHERE expires <= ?", (now,))
            tokens = [key for key in self.registrations if hashlib.sha256(key.encode()).hexdigest() not in self.invalid_tokens]
            if not tokens:
                raise GatewayError(503, "M_NO_DEVICES", 300)
            transient = None
            accepted = 0
            for key in tokens:
                token_digest = hashlib.sha256(key.encode()).hexdigest()
                digest = hashlib.sha256(json.dumps(["reminder", key, hint], separators=(",", ":")).encode()).hexdigest()
                if db.execute("SELECT 1 FROM accepted WHERE digest = ?", (digest,)).fetchone():
                    accepted += 1
                    continue
                minute = int(now // 60)
                old_minute, old_count = self.rate.get(token_digest, (minute, 0))
                count = old_count if old_minute == minute else 0
                if count >= self.config.rate_per_minute:
                    transient = max(transient or 0, 60)
                    continue
                self.rate[token_digest] = (minute, count + 1)
                try:
                    outcome = self.publisher.publish(key, {"personal_wake": "reminder"}, "high")
                except Exception:
                    outcome = PublishResult("transient")
                if outcome.status == "rejected":
                    self.invalid_tokens.add(token_digest)
                    db.execute("INSERT OR IGNORE INTO invalid VALUES (?)", (token_digest,))
                elif outcome.status == "accepted":
                    accepted += 1
                    db.execute("INSERT OR REPLACE INTO accepted VALUES (?, ?)", (digest, now + self.config.dedup_seconds))
                    db.execute("DELETE FROM accepted WHERE digest IN ("
                        "SELECT digest FROM accepted ORDER BY expires DESC, digest DESC LIMIT -1 OFFSET ?)",
                        (self.config.max_dedup_entries,))
                else:
                    transient = max(transient or 0, outcome.retry_after)
            db.commit()
            if transient:
                raise GatewayError(503, "M_UNAVAILABLE", transient)
            if not accepted:
                raise GatewayError(503, "M_NO_DEVICES", 300)
        return {"accepted": True, "state": "fcm_accepted"}


class Handler(BaseHTTPRequestHandler):
    server_version = "PersonalPush"
    sys_version = ""

    def log_message(self, *_):
        pass

    def reply(self, status, value, retry_after=None):
        encoded = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(encoded)))
        if retry_after is not None:
            self.send_header("Retry-After", str(retry_after))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        if self.path == "/healthz":
            self.reply(200, {"ready": True})
        else:
            self.reply(405 if self.path == ENDPOINT else 404, {"errcode": "M_UNRECOGNIZED"})

    def do_POST(self):
        try:
            if self.path not in (ENDPOINT, REMINDER_ENDPOINT):
                raise GatewayError(404, "M_UNRECOGNIZED")
            if self.headers.get("Transfer-Encoding") is not None:
                raise GatewayError(400, "M_BAD_JSON")
            length = self.headers.get("Content-Length")
            if length is None or not length.isdigit():
                raise GatewayError(411, "M_BAD_JSON")
            if not 1 <= int(length) <= self.server.gateway.config.max_body_bytes:
                raise GatewayError(413, "M_TOO_LARGE")
            if self.headers.get("Content-Type", "").split(";")[0].lower() != "application/json":
                raise GatewayError(415, "M_BAD_JSON")
            body = self.rfile.read(int(length))
            if len(body) != int(length):
                raise GatewayError(400, "M_BAD_JSON")
            try:
                packet = json.loads(body)
            except (ValueError, UnicodeError):
                raise GatewayError(400, "M_BAD_JSON") from None
            result = self.server.gateway.reminder(packet, self.headers.get("Authorization"),
                self.client_address[0]) if self.path == REMINDER_ENDPOINT else self.server.gateway.notify(packet)
            self.reply(200, result)
        except GatewayError as error:
            self.reply(error.status, {"errcode": error.code}, error.retry_after)
        except (OSError, ValueError):
            self.reply(503, {"errcode": "M_UNAVAILABLE"}, 60)
        except Exception:
            LOG.error("request_failed")
            self.reply(503, {"errcode": "M_UNAVAILABLE"}, 60)

    def do_PUT(self):
        self.reply(405 if self.path == ENDPOINT else 404, {"errcode": "M_UNRECOGNIZED"})

    do_DELETE = do_PUT
    do_OPTIONS = do_PUT
    do_PATCH = do_PUT
    do_HEAD = do_PUT
    do_TRACE = do_PUT

    def send_error(self, code, message=None, explain=None):
        # BaseHTTPRequestHandler otherwise emits HTML containing request data.
        status = (405 if self.path == ENDPOINT else 404) if code == 501 else code
        self.reply(status, {"errcode": "M_UNRECOGNIZED" if code == 501 else "M_BAD_JSON"})


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 16

    def __init__(self, gateway, address=None):
        self.gateway = gateway
        self.slots = threading.BoundedSemaphore(gateway.config.max_concurrency)
        if gateway.config.bind == "::1":
            self.address_family = socket.AF_INET6
        if address is not None and address[0] not in ("127.0.0.1", "::1"):
            raise ConfigError()
        super().__init__(address or (gateway.config.bind, gateway.config.port), Handler)

    def get_request(self):
        socket_, address = super().get_request()
        socket_.settimeout(self.gateway.config.request_timeout_seconds)
        return socket_, address

    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            try:
                request.sendall(b"HTTP/1.0 503 Service Unavailable\r\nContent-Length: 0\r\nRetry-After: 60\r\n\r\n")
            finally:
                self.shutdown_request(request)
            return
        try:
            super().process_request(request, address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.slots.release()

    def handle_error(self, request, address):
        LOG.error("connection_failed")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, help="Owner-only private configuration file")
    parser.add_argument("--check", action="store_true", help="Validate local files without provider calls")
    args = parser.parse_args()
    os.umask(0o077)
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    for name in ("google", "urllib3", "requests"):
        logging.getLogger(name).setLevel(logging.CRITICAL)
    try:
        config = Config.load(args.config)
        publisher = FcmPublisher(config)
        if args.check:
            print("Private configuration validated; no provider request made")
            return
        gateway = Gateway(config, publisher)
        with Server(gateway) as server:
            LOG.info("gateway_ready_loopback")
            server.serve_forever()
    except KeyboardInterrupt:
        pass
    except Exception:
        LOG.error("gateway_setup_failed")
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
