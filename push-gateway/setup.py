#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Offline setup helpers. Never echoes credentials, pushkeys or nonces."""

import argparse
import getpass
import json
import os
from pathlib import Path
import secrets
import sys
import tempfile

from gateway import APP_ID, Config, ConfigError, Registration, private_json, valid_app_id


def outside_repository(path):
    path = Path(path).expanduser()
    if path.is_symlink():
        raise ConfigError()
    path = path.resolve()
    if any((parent / ".git").exists() for parent in (path.parent, *path.parents)):
        raise ConfigError()
    return path


def atomic_private_json(path, value):
    path = outside_repository(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.is_symlink():
        raise ConfigError()
    fd, temporary = tempfile.mkstemp(prefix=".push-config-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as file:
            json.dump(value, file, indent=2)
            file.write("\n")
            file.flush()
            os.fsync(file.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def check_android_config(path, expected_project):
    value = private_json(path)
    if value.get("project_info", {}).get("project_id") != expected_project:
        raise ConfigError()
    matches = [client for client in value.get("client", []) if
        client.get("client_info", {}).get("android_client_info", {}).get("package_name") == APP_ID]
    if len(matches) != 1:
        raise ConfigError()
    return True


def register(config_path, app_id, nonce_file, pushkey, nonce):
    config_path = outside_repository(config_path)
    nonce_file = outside_repository(nonce_file)
    Config.load(config_path)
    if not valid_app_id(app_id) or not 16 <= len(pushkey) <= 2048:
        raise ConfigError()
    value = private_json(config_path)
    entries = [reg for reg in value["registrations"] if reg["pushkey"] != pushkey]
    entries.append({"app_id": app_id, "pushkey": pushkey, "nonce": nonce})
    value["registrations"] = entries
    # Validate before either file is changed. No service restart or network call.
    Config(**{**value, "registrations": tuple(Registration(**e) for e in entries)}).validate()
    if nonce_file.exists():
        raise ConfigError()
    atomic_private_json(nonce_file, {"format": "event_id_only", "gateway_nonce": nonce})
    atomic_private_json(config_path, value)


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    android = commands.add_parser("check-android")
    android.add_argument("--file", required=True)
    android.add_argument("--project-id", required=True)
    add = commands.add_parser("register")
    add.add_argument("--config", required=True)
    add.add_argument("--app-id", required=True)
    add.add_argument("--nonce-file", required=True)
    reminder = commands.add_parser("reminder-key")
    reminder.add_argument("--file", required=True)
    args = parser.parse_args()
    try:
        if args.command == "check-android":
            check_android_config(args.file, args.project_id)
            print("Own Android package/project configuration validated")
        elif args.command == "reminder-key":
            if outside_repository(args.file).exists():
                raise ConfigError()
            atomic_private_json(args.file, {"token": secrets.token_urlsafe(32)})
            print("Private reminder credential created; no service or API changed")
        else:
            pushkey = getpass.getpass("FCM registration token (hidden): ")
            nonce = getpass.getpass("Gateway nonce (hidden; empty generates one): ") or secrets.token_urlsafe(32)
            register(args.config, args.app_id, args.nonce_file, pushkey, nonce)
            print("Private registration saved; configure app nonce and explicitly reload gateway")
    except Exception:
        print("Setup failed; check private paths, permissions and own project/package", file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
