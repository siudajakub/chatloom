#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Personal Matrix event_id_only -> FCM HTTP v1 gateway. No chat content."""

from __future__ import annotations

import argparse
from collections import Counter
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import logging
import os
from pathlib import Path
import re
import signal
import socket
import sqlite3
import stat
import threading
import time
from typing import Callable
import urllib.error
import urllib.request
import urllib.parse

APP_ID = "pl.personal.chat"
ENDPOINT = "/_matrix/push/v1/notify"
REMINDER_ENDPOINT = "/internal/reminder"
REGISTER_ENDPOINT = "/_personal/push/v1/register"
MAX_FCM_DATA_BYTES = 3500
# Counters of requests that publish nothing are kept in memory and written at
# most this often (or by the next publish transaction, or at shutdown).
STATS_FLUSH_SECONDS = 60
# Dynamic registrations kept per OpenID-verified account; the least recently
# registered one is evicted (a phone re-enrolls after logout/login with a new
# Matrix device id, so older rows of the same account become stale).
MAX_DEVICES_PER_ACCOUNT = 8
LOG = logging.getLogger("personal-push")
PATH_NAMES = {ENDPOINT: "notify", REMINDER_ENDPOINT: "reminder", REGISTER_ENDPOINT: "register", "/healthz": "healthz"}
# Only fixed enum/count names ever reach logs or the stats table.
_STAT_NAME = re.compile(r"[a-z0-9_.]{1,80}")
_ENUM_VALUE = re.compile(r"[A-Za-z0-9_+./-]{1,64}")
_UA_PRODUCT = re.compile(r"([A-Za-z0-9._-]{1,32})(?:/([A-Za-z0-9._-]{1,16}))?")


class GatewayError(Exception):
    def __init__(self, status: int, code: str, retry_after: int | None = None, *, reason: str | None = None):
        self.status, self.code, self.retry_after = status, code, retry_after
        self.reason = reason
        super().__init__(code)


def ua_product(value) -> str:
    """First User-Agent product token only (e.g. Synapse/1.2); never free text."""
    if not isinstance(value, str):
        return "-"
    match = _UA_PRODUCT.match(value.strip())
    if not match:
        return "-"
    return match.group(1) + (f"/{match.group(2)}" if match.group(2) else "")


class RequestTrace:
    """Content-free per-request accounting.

    Holds only enums and counts: never tokens, nonces, Matrix IDs, IP addresses,
    bodies or header values other than the sanitized User-Agent product token.
    """

    def __init__(self, path: str, ua: str = "-"):
        self.path = path if path in PATH_NAMES.values() else "other"
        self.ua = ua if _ENUM_VALUE.fullmatch(ua or "") else "-"
        self.started = time.monotonic()
        self.status: int | None = None
        self.reason = "-"
        self.fields: dict[str, object] = {}
        self.tallies: dict[str, Counter] = {}
        self.counts: Counter = Counter()
        self._flushed: Counter = Counter()
        self.logged = False

    def field(self, name: str, value):
        if isinstance(value, bool):
            value = int(value)
        if isinstance(value, int) or (isinstance(value, str) and _ENUM_VALUE.fullmatch(value)):
            self.fields[name] = value

    def tally(self, category: str, value: str, n: int = 1):
        """Count a per-device/per-send enum, both for the log line and stats."""
        self.tallies.setdefault(category, Counter())[value] += n
        self.count(f"{category}.{value}", n)

    def count(self, name: str, n: int = 1):
        stat = f"{self.path}.{name}"
        if _STAT_NAME.fullmatch(stat):
            self.counts[stat] += n

    def finish(self, status: int, reason: str | None = None):
        # The first outcome wins; a failed reply after a processed request does
        # not rewrite what the gateway actually did.
        if self.status is not None:
            return
        self.status = status
        self.count("requests")
        self.count(f"status.{status}")
        if reason and _ENUM_VALUE.fullmatch(reason):
            self.reason = reason
            self.count(f"reason.{reason}")

    def take_pending(self) -> Counter:
        pending = self.counts - self._flushed
        self._flushed = Counter(self.counts)
        return pending

    def line(self) -> str:
        parts = [f"path={self.path}", f"status={self.status if self.status is not None else '-'}",
                 f"reason={self.reason}"]
        for name, value in self.fields.items():
            parts.append(f"{name}={value}")
        for category, values in self.tallies.items():
            present = sorted(key for key, n in values.items() if n)
            parts.append(f"{category}={'+'.join(present) if present else '-'}")
        parts.append(f"ua={self.ua}")
        parts.append(f"ms={int((time.monotonic() - self.started) * 1000)}")
        return "req " + " ".join(parts)


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
    # Explicit operator pins: never discover or fetch a host supplied by a phone.
    registration_openid_server: str = "matrix.beeper.com"
    registration_openid_origin: str = "https://matrix.beeper.com"
    registration_allowed_users_sha256: tuple[str, ...] = ()

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
        origin = urllib.parse.urlsplit(self.registration_openid_origin)
        if (origin.scheme != "https" or not origin.hostname or origin.username or origin.password
                or origin.path or origin.query or origin.fragment
                or not re.fullmatch(r"[a-zA-Z0-9.-]+", self.registration_openid_server)
                or len(self.registration_allowed_users_sha256) > 16
                or any(not isinstance(item, str) or not re.fullmatch(r"[a-f0-9]{64}", item)
                       for item in self.registration_allowed_users_sha256)):
            raise ConfigError()
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
        raise GatewayError(400, "M_BAD_JSON", reason="counts")
    output = {}
    for key in ("unread", "missed_calls"):
        if key not in value:
            continue
        val = value[key]
        if type(val) is not int or not 0 <= val <= 2147483647:
            raise GatewayError(400, "M_BAD_JSON", reason="counts")
        output[key] = val
    return output


def routing_data(notification):
    """FCM v1 data values are strings; SDK accepts counts/devices JSON strings."""
    counts = count_data(notification.get("counts"))
    output = {"counts": json.dumps(counts, separators=(",", ":")), "devices": "[]"}
    event, room = notification.get("event_id"), notification.get("room_id")
    if event is not None:
        if not isinstance(event, str) or not event.startswith("$") or not 2 <= len(event.encode()) <= 512:
            raise GatewayError(400, "M_BAD_JSON", reason="event")
        if not isinstance(room, str) or not room.startswith("!") or not 2 <= len(room.encode()) <= 512:
            raise GatewayError(400, "M_BAD_JSON", reason="event")
        output.update(event_id=event, room_id=room)
    elif room is not None:
        raise GatewayError(400, "M_BAD_JSON", reason="event")
    if len(json.dumps(output, separators=(",", ":")).encode()) > MAX_FCM_DATA_BYTES:
        raise GatewayError(413, "M_TOO_LARGE", reason="too_large")
    # content, sender, sender_display_name, room_name, tweaks and pusher data are
    # never copied. No default_payload extension can bypass this allowlist.
    return output


@dataclass(frozen=True)
class PublishResult:
    status: str  # accepted | rejected | transient
    retry_after: int = 60


@dataclass(frozen=True, repr=False)
class NotifyRequest:
    """A validated notify request: content-free routing data and the devices
    whose registration and nonce matched. Never logged."""
    data: dict
    event: str | None
    priority: str
    authorized: dict
    rejected: list


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
        self.lock = threading.RLock()
        self.registration_attempts = []
        self.rate = {}  # only SHA-256 digests of registered tokens, bounded by config
        # Counters not yet written to the stats table (refused, unauthorized or
        # malformed requests). Never holds anything but fixed enum names.
        self.pending_lock = threading.Lock()
        self.pending: Counter = Counter()
        self.last_flush = clock()
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
            db.execute("CREATE TABLE IF NOT EXISTS registrations (owner TEXT NOT NULL, app_id TEXT NOT NULL, "
                       "pushkey TEXT NOT NULL UNIQUE, nonce TEXT NOT NULL, PRIMARY KEY (owner, app_id))")
            # Content-free counters: fixed enum names, counts and last-update time.
            db.execute("CREATE TABLE IF NOT EXISTS stats (name TEXT PRIMARY KEY, n INTEGER NOT NULL, last REAL NOT NULL)")
            self.invalid_tokens = {r[0] for r in db.execute("SELECT digest FROM invalid")}
            # Only register() writes registrations; the snapshot is replaced (never
            # mutated) after each committed change, so classification needs no lock.
            self.active = self.active_registrations(db)
        self.db_path.chmod(0o600)

    # -- content-free accounting -------------------------------------------------

    def note_busy(self):
        with self.pending_lock:
            self.pending["server.busy"] += 1

    def write_stats(self, db, trace: RequestTrace | None):
        """Add the trace's and all deferred counters inside the caller's transaction."""
        pending = trace.take_pending() if trace is not None else Counter()
        with self.pending_lock:
            pending.update(self.pending)
            self.pending = Counter()
            self.last_flush = self.clock()
        now = self.clock()
        for name, n in sorted(pending.items()):
            if n > 0 and _STAT_NAME.fullmatch(name):
                db.execute("INSERT INTO stats (name, n, last) VALUES (?, ?, ?) ON CONFLICT(name) "
                           "DO UPDATE SET n = n + excluded.n, last = excluded.last", (name, n, now))

    def flush(self, trace: RequestTrace | None):
        """Write counters now; only for requests that already passed authentication."""
        if trace is not None and not (trace.counts - trace._flushed):
            return
        try:
            with self.lock, self.database() as db:
                self.write_stats(db, trace)
        except Exception:
            LOG.error("stats_write_failed")

    def defer(self, trace: RequestTrace | None):
        """Keep counters of a request that wrote nothing in memory.

        Refused, unauthorized and malformed requests never take the global lock
        or open the database themselves: their counters join the next publish
        transaction or a flush at most every STATS_FLUSH_SECONDS.
        """
        if trace is not None:
            pending = trace.take_pending()
            if pending:
                with self.pending_lock:
                    self.pending.update(pending)
        self.maybe_flush()

    def maybe_flush(self):
        """Periodic best-effort flush; never waits for the global lock."""
        with self.pending_lock:
            if not self.pending or self.clock() - self.last_flush < STATS_FLUSH_SECONDS:
                return
        if not self.lock.acquire(blocking=False):
            return  # an in-flight publish writes them in its transaction
        try:
            self._write_pending()
        finally:
            self.lock.release()

    def flush_pending(self, timeout: float = 5):
        """Best effort at shutdown (and in tests): write deferred counters now."""
        if not self.lock.acquire(timeout=timeout):
            LOG.error("stats_write_failed")
            return
        try:
            self._write_pending()
        finally:
            self.lock.release()

    def _write_pending(self):
        with self.pending_lock:
            if not self.pending:
                return
        try:
            with self.database() as db:
                self.write_stats(db, None)
        except Exception:
            LOG.error("stats_write_failed")

    @staticmethod
    def _failed(trace: RequestTrace, error: GatewayError):
        trace.finish(error.status, error.reason or error.code.lower())

    # -- registration -----------------------------------------------------------

    def register(self, packet, trace: RequestTrace | None = None):
        trace = trace if trace is not None else RequestTrace("register")
        try:
            result = self._register(packet, trace)
        except GatewayError as error:
            self._failed(trace, error)
            self.defer(trace)
            raise
        trace.finish(200, "registered")
        self.flush(trace)
        return result

    def _register(self, packet, trace):
        if not self.config.registration_allowed_users_sha256:
            raise GatewayError(503, "M_REGISTRATION_DISABLED", 300, reason="disabled")
        if (not isinstance(packet, dict) or set(packet) != {
                "app_id", "pushkey", "nonce", "account_sha256", "openid"}):
            raise GatewayError(400, "M_BAD_JSON", reason="envelope")
        reg = Registration(packet["pushkey"], packet["app_id"], packet["nonce"])
        if (not valid_app_id(reg.app_id) or not reg.app_id.startswith(APP_ID + ".")
                or not isinstance(reg.pushkey, str) or not 16 <= len(reg.pushkey) <= 2048
                or not isinstance(reg.nonce, str) or not re.fullmatch(r"[A-Za-z0-9_-]{43,128}", reg.nonce)):
            raise GatewayError(400, "M_BAD_JSON", reason="registration")
        owner = packet["account_sha256"]
        if not isinstance(owner, str) or owner not in self.config.registration_allowed_users_sha256:
            raise GatewayError(403, "M_FORBIDDEN", reason="account")
        proof = packet["openid"]
        if (not isinstance(proof, dict) or set(proof) != {"access_token", "matrix_server_name", "token_type", "expires_in"}
                or proof.get("matrix_server_name") != self.config.registration_openid_server
                or proof.get("token_type") != "Bearer"
                or type(proof.get("expires_in")) is not int or not 1 <= proof["expires_in"] <= 3600
                or not isinstance(proof.get("access_token"), str)
                or not 1 <= len(proof["access_token"]) <= 4096):
            raise GatewayError(403, "M_FORBIDDEN", reason="proof")
        # Bounded global budget even when a caller forges proxy/client headers.
        with self.lock:
            now = self.clock()
            self.registration_attempts = [at for at in self.registration_attempts if now - at < 60]
            if len(self.registration_attempts) >= 20:
                raise GatewayError(429, "M_LIMIT_EXCEEDED", 60, reason="rate_limited")
            self.registration_attempts.append(now)
        try:
            status, _, raw = http_request(self.config.registration_openid_origin
                + "/_matrix/federation/v1/openid/userinfo?"
                + urllib.parse.urlencode({"access_token": proof["access_token"]}),
                timeout=self.config.provider_timeout_seconds)
            if status in (401, 403):
                raise GatewayError(403, "M_FORBIDDEN", reason="openid_rejected")
            if status != 200:
                raise GatewayError(503, "M_UNAVAILABLE", 60, reason="openid_unavailable")
            identity = json.loads(raw)
            subject = identity.get("sub") if isinstance(identity, dict) else None
            if (not isinstance(subject, str) or not subject.startswith("@")
                    or hashlib.sha256(subject.encode()).hexdigest() != owner):
                raise GatewayError(403, "M_FORBIDDEN", reason="openid_subject")
        except GatewayError:
            raise
        except Exception:
            raise GatewayError(503, "M_UNAVAILABLE", 60, reason="openid_unavailable") from None
        with self.lock:
            with self.database() as db:
                active = self._store_registration(db, owner, reg, trace)
            # Published only after the commit succeeded.
            self.active = active
        return {"registered": True}

    def _store_registration(self, db, owner, reg, trace):
        previous = db.execute("SELECT owner, app_id FROM registrations WHERE pushkey = ?", (reg.pushkey,)).fetchone()
        if previous is not None and previous[0] != owner:
            # Another account can never claim a registered token.
            raise GatewayError(409, "M_CONFLICT", reason="conflict")
        if reg.pushkey in self.registrations:
            static = self.registrations[reg.pushkey]
            if static.app_id != reg.app_id:
                raise GatewayError(409, "M_CONFLICT", reason="conflict")
        if previous is not None and previous[1] != reg.app_id:
            # Same verified account, new Matrix device id (logout/login): move
            # the token to the new app id in this transaction.
            db.execute("DELETE FROM registrations WHERE pushkey = ?", (reg.pushkey,))
            trace.count("moved")
        existing = db.execute("SELECT 1 FROM registrations WHERE owner = ? AND app_id = ?", (owner, reg.app_id)).fetchone()
        if not existing:
            count = db.execute("SELECT COUNT(*) FROM registrations WHERE owner = ?", (owner,)).fetchone()[0]
            excess = count - MAX_DEVICES_PER_ACCOUNT + 1
            if excess > 0:
                db.execute("DELETE FROM registrations WHERE rowid IN (SELECT rowid FROM registrations "
                           "WHERE owner = ? ORDER BY rowid ASC LIMIT ?)", (owner, excess))
                trace.count("evicted", excess)
        # One transaction replaces a rotated token; retries are idempotent.
        # Delete + insert gives the row a new (highest) rowid, so rowid order is
        # "least recently registered first" without a schema change (an older
        # gateway version still works with this database after a rollback).
        db.execute("DELETE FROM registrations WHERE owner = ? AND app_id = ?", (owner, reg.app_id))
        db.execute("INSERT INTO registrations VALUES (?, ?, ?, ?)", (owner, reg.app_id, reg.pushkey, reg.nonce))
        trace.count("replaced" if existing else "added")
        return self.active_registrations(db)

    def active_registrations(self, db):
        rows = db.execute("SELECT owner, app_id, pushkey, nonce FROM registrations").fetchall()
        # An enrolled app supersedes its legacy static registration, including
        # after account revocation. Never resurrect an old token on restart.
        enrolled_apps = {row[1] for row in rows}
        registrations = {key: reg for key, reg in self.registrations.items() if reg.app_id not in enrolled_apps}
        for owner, app_id, pushkey, nonce in rows:
            if owner in self.config.registration_allowed_users_sha256:
                registrations[pushkey] = Registration(pushkey, app_id, nonce)
        return registrations

    @contextmanager
    def database(self):
        db = sqlite3.connect(self.db_path, timeout=2)
        try:
            with db:
                yield db
        finally:
            db.close()

    # -- Matrix push gateway ----------------------------------------------------

    def notify(self, packet, trace: RequestTrace | None = None):
        trace = trace if trace is not None else RequestTrace("notify")
        try:
            # Validation and device classification touch neither the global lock
            # nor the database: an unauthenticated caller cannot serialize or
            # write anything.
            request = self._classify(packet, self.active, trace)
        except GatewayError as error:
            self._failed(trace, error)
            self.defer(trace)
            raise
        if not request.authorized:
            result = {"rejected": list(dict.fromkeys(request.rejected))}
            trace.finish(200, "ok" if not result["rejected"] else "rejected_devices")
            self.defer(trace)
            return result
        with self.lock, self.database() as db:
            try:
                result = self._publish(request, db, trace)
            except GatewayError as error:
                self._failed(trace, error)
                # Keep FCM-accepted dedup rows and counters before the homeserver
                # is asked to retry; invalid tokens stay rejected on that retry.
                self.write_stats(db, trace)
                db.commit()
                raise
            trace.finish(200, "ok" if not result["rejected"] else "rejected_devices")
            self.write_stats(db, trace)
            return result

    def _classify(self, packet, registrations, trace) -> "NotifyRequest":
        if not isinstance(packet, dict) or not isinstance(packet.get("notification"), dict):
            raise GatewayError(400, "M_BAD_JSON", reason="envelope")
        notification = packet["notification"]
        data = routing_data(notification)
        devices = notification.get("devices")
        if not isinstance(devices, list) or len(devices) > self.config.max_devices:
            raise GatewayError(400, "M_BAD_JSON", reason="devices")
        event = data.get("event_id")
        priority_hint = notification.get("prio", "high")
        trace.field("devices", len(devices))
        trace.field("event", bool(event))
        trace.count("kind.event" if event else "kind.counts")
        authorized: dict[str, Registration] = {}
        rejected = []
        skipped = 0
        unknown = mismatch = 0
        for device in devices:
            if not isinstance(device, dict) or not isinstance(device.get("pushkey"), str):
                raise GatewayError(400, "M_BAD_JSON", reason="devices")
            key = device["pushkey"]
            if not 1 <= len(key) <= 2048:
                raise GatewayError(400, "M_BAD_JSON", reason="devices")
        for device in devices:
            key = device["pushkey"]
            reg = registrations.get(key)
            if reg is None:
                unknown += 1
                rejected.append(key)
                continue
            if device.get("app_id") != reg.app_id:
                mismatch += 1
                rejected.append(key)
                continue
            extra = device.get("data")
            extra = extra if isinstance(extra, dict) else {}
            requested = extra.get("format")
            trace.tally("format", "ok" if requested == "event_id_only" else "missing" if requested is None else "other")
            nonce = extra.get("gateway_nonce")
            if not isinstance(nonce, str) or not nonce:
                nonce_state = "missing"
            elif hmac.compare_digest(nonce.encode(), reg.nonce.encode()):
                nonce_state = "ok"
            else:
                nonce_state = "mismatch"
            trace.tally("nonce", nonce_state)
            if nonce_state != "ok":
                # A per-device problem must never stall the homeserver's queue:
                # no error status (which causes back-off) and no rejection (which
                # deletes the pusher). Nothing is published for this device.
                skipped += 1
                continue
            # A format mismatch with a valid nonce still publishes: routing_data
            # never copies content, so the FCM payload is identical either way.
            authorized.setdefault(key, reg)
        trace.field("authorized", len(authorized))
        trace.field("skipped", skipped)
        trace.field("unknown", unknown)
        trace.field("appid_mismatch", mismatch)
        if unknown:
            trace.count("device.unknown", unknown)
        if mismatch:
            trace.count("device.appid_mismatch", mismatch)
        if skipped:
            trace.count("device.skipped", skipped)
        priority = "high" if event and priority_hint == "high" else "normal"
        if authorized:
            trace.field("prio", priority)
        return NotifyRequest(data, event, priority, authorized, rejected)

    def _publish(self, request: "NotifyRequest", db, trace):
        data, event, priority = request.data, request.event, request.priority
        rejected = list(request.rejected)
        transient = None
        # Serialize dedup/rate bookkeeping and publish so concurrent repeats
        # never generate another confirmed FCM send for the same device/event.
        now = self.clock()
        db.execute("DELETE FROM accepted WHERE expires <= ?", (now,))
        current = self.active
        for key, reg in request.authorized.items():
            if current.get(key) != reg:
                # Rotated or replaced while this request waited for the lock.
                trace.count("device.changed")
                continue
            token_digest = hashlib.sha256(key.encode()).hexdigest()
            if token_digest in self.invalid_tokens:
                trace.tally("fcm", "invalid_token")
                rejected.append(key)
                continue
            digest = hashlib.sha256(json.dumps([key, data.get("room_id"), event],
                separators=(",", ":")).encode()).hexdigest() if event else None
            if digest and db.execute("SELECT 1 FROM accepted WHERE digest = ?", (digest,)).fetchone():
                trace.tally("fcm", "dedup")
                continue
            minute = int(now // 60)
            old_minute, old_count = self.rate.get(token_digest, (minute, 0))
            count = old_count if old_minute == minute else 0
            if count >= self.config.rate_per_minute:
                trace.tally("fcm", "ratelimited")
                transient = max(transient or 0, 60)
                continue
            self.rate[token_digest] = (minute, count + 1)
            try:
                outcome = self.publisher.publish(key, dict(data), priority)
            except Exception:
                outcome = PublishResult("transient")
            trace.tally("fcm", outcome.status if outcome.status in ("accepted", "rejected") else "transient")
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
            raise GatewayError(503, "M_UNAVAILABLE", transient, reason="fcm_retry")
        return {"rejected": list(dict.fromkeys(rejected))}

    # -- worker reminder relay ------------------------------------------------------

    def reminder(self, packet, authorization, peer, trace: RequestTrace | None = None):
        trace = trace if trace is not None else RequestTrace("reminder")
        try:
            hint = self._reminder_hint(packet, authorization, peer)
        except GatewayError as error:
            self._failed(trace, error)
            self.defer(trace)
            raise
        with self.lock, self.database() as db:
            try:
                result = self._reminder(hint, db, trace)
            except GatewayError as error:
                self._failed(trace, error)
                self.write_stats(db, trace)
                db.commit()
                raise
            trace.finish(200, "ok")
            self.write_stats(db, trace)
            return result

    def _reminder_hint(self, packet, authorization, peer):
        if self.reminder_token is None:
            raise GatewayError(404, "M_UNRECOGNIZED", reason="disabled")
        if peer not in ("127.0.0.1", "::1"):
            raise GatewayError(403, "M_FORBIDDEN", reason="peer")
        expected = f"Bearer {self.reminder_token}"
        if not isinstance(authorization, str) or not hmac.compare_digest(authorization.encode(), expected.encode()):
            raise GatewayError(403, "M_FORBIDDEN", reason="auth")
        if not isinstance(packet, dict) or set(packet) != {"hintId", "emittedAt"}:
            raise GatewayError(400, "M_BAD_JSON", reason="envelope")
        hint = packet["hintId"]
        if not isinstance(hint, str) or not re.fullmatch(r"[a-f0-9]{64}", hint):
            raise GatewayError(400, "M_BAD_JSON", reason="hint")
        try:
            stamp = packet["emittedAt"]
            if not isinstance(stamp, str) or len(stamp) > 40:
                raise ValueError()
            parsed = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
            if parsed.tzinfo is None or parsed.utcoffset() != timedelta(0):
                raise ValueError()
        except (TypeError, ValueError):
            raise GatewayError(400, "M_BAD_JSON", reason="emitted_at") from None
        # No permanent age expiry: a worker may retain a due hint while devices
        # are being configured. emittedAt is validated but never logged/stored.
        return hint

    def _reminder(self, hint, db, trace):
        now = self.clock()
        db.execute("DELETE FROM accepted WHERE expires <= ?", (now,))
        # Every active device of every allowed account: the relay credential is
        # not bound to one account (see README). The wake is content-free.
        tokens = [key for key in self.active if hashlib.sha256(key.encode()).hexdigest() not in self.invalid_tokens]
        trace.field("devices", len(tokens))
        if not tokens:
            raise GatewayError(503, "M_NO_DEVICES", 300, reason="no_devices")
        transient = None
        accepted = 0
        for key in tokens:
            token_digest = hashlib.sha256(key.encode()).hexdigest()
            digest = hashlib.sha256(json.dumps(["reminder", key, hint], separators=(",", ":")).encode()).hexdigest()
            if db.execute("SELECT 1 FROM accepted WHERE digest = ?", (digest,)).fetchone():
                trace.tally("fcm", "dedup")
                accepted += 1
                continue
            minute = int(now // 60)
            old_minute, old_count = self.rate.get(token_digest, (minute, 0))
            count = old_count if old_minute == minute else 0
            if count >= self.config.rate_per_minute:
                trace.tally("fcm", "ratelimited")
                transient = max(transient or 0, 60)
                continue
            self.rate[token_digest] = (minute, count + 1)
            try:
                outcome = self.publisher.publish(key, {"personal_wake": "reminder"}, "high")
            except Exception:
                outcome = PublishResult("transient")
            trace.tally("fcm", outcome.status if outcome.status in ("accepted", "rejected") else "transient")
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
        if transient:
            raise GatewayError(503, "M_UNAVAILABLE", transient, reason="fcm_retry")
        if not accepted:
            raise GatewayError(503, "M_NO_DEVICES", 300, reason="no_valid_devices")
        return {"accepted": True, "state": "fcm_accepted"}


def read_stats(state_directory: str | Path) -> dict:
    """Read-only operator view: counters and table sizes, never secrets or IDs."""
    path = Path(state_directory) / "push_state.sqlite"
    report = {"stats": {}, "tables": {}, "hints": []}
    if not path.is_file():
        report["hints"].append("no_state_database")
        return report
    # mode=ro never creates, migrates or locks the live database for writing.
    db = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=2)
    try:
        tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        for table in ("registrations", "invalid", "accepted"):
            if table in tables:
                report["tables"][table] = db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        if "stats" in tables:
            for name, n, last in db.execute("SELECT name, n, last FROM stats ORDER BY name"):
                report["stats"][name] = {
                    "n": n, "last": datetime.fromtimestamp(last, timezone.utc).isoformat(timespec="seconds")}
    finally:
        db.close()
    stats = {name: value["n"] for name, value in report["stats"].items()}
    def total(prefix):
        return sum(n for name, n in stats.items() if name.startswith(prefix))
    if not stats:
        report["hints"].append("no_counters_yet")
    if not total("notify.requests"):
        report["hints"].append("no_notify_requests_since_stats_enabled")
    if total("notify.status.4"):
        report["hints"].append("notify_requests_refused_check_reasons")
    if total("notify.nonce.missing") or total("notify.nonce.mismatch"):
        report["hints"].append("pusher_nonce_problem_reregister_phone")
    if total("notify.format.other") or total("notify.format.missing"):
        # The homeserver sends full notifications (content) to the gateway; the
        # gateway still forwards only ids, but the pusher should be re-set up.
        report["hints"].append("pusher_format_not_event_id_only")
    if total("notify.device.unknown") or total("notify.device.appid_mismatch"):
        report["hints"].append("unregistered_pusher_reregister_phone")
    if total("notify.fcm.transient") or total("notify.fcm.ratelimited"):
        report["hints"].append("fcm_retries_seen")
    if total("notify.fcm.accepted"):
        report["hints"].append("fcm_accepted_check_phone_diagnostics")
    return report


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

    def trace(self):
        path = getattr(self, "path", "")
        headers = getattr(self, "headers", None)
        return RequestTrace(PATH_NAMES.get(path, "other"),
                            ua_product(headers.get("User-Agent") if headers is not None else None))

    def respond(self, trace, status, value, retry_after=None, reason=None):
        # Exactly one content-free line per request (enums, counts, UA product,
        # ms), written before the reply so it is never lost to a disconnect.
        trace.finish(status, reason)
        if not trace.logged:
            trace.logged = True
            LOG.info(trace.line())
        self.reply(status, value, retry_after)

    def finish_trace(self, trace):
        if not trace.logged:
            trace.logged = True
            LOG.info(trace.line())
        # Whatever the request did not write itself stays in memory; the reply
        # is already sent and this never waits for the global lock.
        self.server.gateway.defer(trace)

    def do_GET(self):
        trace = self.trace()
        try:
            if self.path == "/healthz":
                self.respond(trace, 200, {"ready": True}, reason="ok")
            else:
                status = 405 if self.path == ENDPOINT else 404
                self.respond(trace, status, {"errcode": "M_UNRECOGNIZED"},
                             reason="method" if status == 405 else "unknown_path")
        finally:
            self.finish_trace(trace)

    def do_POST(self):
        trace = self.trace()
        try:
            if self.path not in (ENDPOINT, REMINDER_ENDPOINT, REGISTER_ENDPOINT):
                raise GatewayError(404, "M_UNRECOGNIZED", reason="unknown_path")
            if self.headers.get("Transfer-Encoding") is not None:
                raise GatewayError(400, "M_BAD_JSON", reason="te")
            length = self.headers.get("Content-Length")
            if length is None or not length.isdigit():
                raise GatewayError(411, "M_BAD_JSON", reason="no_length")
            if not 1 <= int(length) <= self.server.gateway.config.max_body_bytes:
                raise GatewayError(413, "M_TOO_LARGE", reason="too_large")
            if self.headers.get("Content-Type", "").split(";")[0].lower() != "application/json":
                raise GatewayError(415, "M_BAD_JSON", reason="content_type")
            body = self.rfile.read(int(length))
            if len(body) != int(length):
                raise GatewayError(400, "M_BAD_JSON", reason="short_body")
            try:
                packet = json.loads(body)
            except (ValueError, UnicodeError):
                raise GatewayError(400, "M_BAD_JSON", reason="bad_json") from None
            if self.path == REGISTER_ENDPOINT:
                result = self.server.gateway.register(packet, trace)
            elif self.path == REMINDER_ENDPOINT:
                result = self.server.gateway.reminder(packet, self.headers.get("Authorization"),
                                                      self.client_address[0], trace)
            else:
                result = self.server.gateway.notify(packet, trace)
            self.respond(trace, 200, result)
        except GatewayError as error:
            self.respond(trace, error.status, {"errcode": error.code}, error.retry_after,
                         reason=error.reason or error.code.lower())
        except (OSError, ValueError):
            self.respond(trace, 503, {"errcode": "M_UNAVAILABLE"}, 60, reason="io")
        except Exception:
            LOG.error("request_failed")
            self.respond(trace, 503, {"errcode": "M_UNAVAILABLE"}, 60, reason="internal")
        finally:
            self.finish_trace(trace)

    def do_PUT(self):
        trace = self.trace()
        status = 405 if self.path == ENDPOINT else 404
        try:
            self.respond(trace, status, {"errcode": "M_UNRECOGNIZED"},
                         reason="method" if status == 405 else "unknown_path")
        finally:
            self.finish_trace(trace)

    do_DELETE = do_PUT
    do_OPTIONS = do_PUT
    do_PATCH = do_PUT
    do_HEAD = do_PUT
    do_TRACE = do_PUT

    def send_error(self, code, message=None, explain=None):
        # BaseHTTPRequestHandler otherwise emits HTML containing request data.
        path = getattr(self, "path", "")
        status = (405 if path == ENDPOINT else 404) if code == 501 else code
        trace = RequestTrace(PATH_NAMES.get(path, "other"))
        try:
            self.respond(trace, status, {"errcode": "M_UNRECOGNIZED" if code == 501 else "M_BAD_JSON"},
                         reason="method" if code == 501 else "malformed")
        finally:
            self.finish_trace(trace)


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
            LOG.info("req path=- status=503 reason=busy")
            self.gateway.note_busy()
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

    def service_actions(self):
        # Runs between polls of serve_forever: periodic flush of deferred
        # counters even when no further request arrives.
        super().service_actions()
        self.gateway.maybe_flush()

    def handle_error(self, request, address):
        LOG.error("connection_failed")


def _interrupt(*_):
    raise KeyboardInterrupt()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, help="Owner-only private configuration file")
    parser.add_argument("--check", action="store_true", help="Validate local files without provider calls")
    parser.add_argument("--stats", action="store_true",
                        help="Print content-free counters as JSON (read-only; no provider or network request)")
    args = parser.parse_args()
    os.umask(0o077)
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    for name in ("google", "urllib3", "requests"):
        logging.getLogger(name).setLevel(logging.CRITICAL)
    try:
        config = Config.load(args.config)
        if args.stats:
            print(json.dumps(read_stats(config.state_directory), indent=2, sort_keys=True))
            return
        publisher = FcmPublisher(config)
        if args.check:
            print("Private configuration validated; no provider request made")
            return
        gateway = Gateway(config, publisher)
        # systemd stops with SIGTERM: leave serve_forever and write deferred
        # counters (best effort) before exiting.
        signal.signal(signal.SIGTERM, _interrupt)
        try:
            with Server(gateway) as server:
                LOG.info("gateway_ready_loopback")
                server.serve_forever()
        finally:
            gateway.flush_pending()
    except KeyboardInterrupt:
        pass
    except Exception:
        LOG.error("gateway_setup_failed")
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
