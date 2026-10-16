#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Copy systemd's read-only credentials into a service-owned 0700 runtime.

Standalone deployment helper: no application dependencies and no secret output.
"""
import json
import os
from pathlib import Path
import secrets
import stat

MAXIMUM = 65536
SERVICE = 'gateway'


class CredentialError(Exception):
    """A deliberately non-sensitive startup failure."""


def source_bytes(directory_fd, name):
    # O_NONBLOCK also prevents a malicious FIFO from hanging service startup.
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                 dir_fd=directory_fd)
    try:
        info = os.fstat(fd)
        groups = {*os.getgroups(), os.getegid()}
        if (not stat.S_ISREG(info.st_mode)
                or stat.S_IMODE(info.st_mode) not in (0o400, 0o440, 0o600)
                or info.st_uid not in (0, os.geteuid())
                or (info.st_mode & 0o040 and info.st_gid not in groups)
                or info.st_size > MAXIMUM or info.st_nlink != 1):
            raise CredentialError()
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            data = stream.read(MAXIMUM + 1)
        if len(data) > MAXIMUM:
            raise CredentialError()
        return data
    finally:
        os.close(fd)


def prepare(source, runtime):
    source = Path(source)
    runtime = Path(runtime)
    if not source.is_absolute() or not runtime.is_absolute():
        raise CredentialError()
    source_fd = os.open(source, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        source_info = os.fstat(source_fd)
        if source_info.st_uid not in (0, os.geteuid()) or source_info.st_mode & 0o022:
            raise CredentialError()
        runtime_fd = os.open(runtime, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            info = os.fstat(runtime_fd)
            if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
                raise CredentialError()
            names = ['credentials.json'] if SERVICE == 'worker' else [
                'gateway-config.json', 'fcm-service-account.json']
            data = {name: source_bytes(source_fd, name) for name in names}
            if SERVICE == 'gateway':
                config = json.loads(data['gateway-config.json'])
                if (not isinstance(config, dict)
                        or config.get('service_account_file') != str(runtime / 'fcm-service-account.json')):
                    raise CredentialError()
                reminder = config.get('reminder_credential_file')
                if reminder is not None:
                    if reminder != str(runtime / 'reminder-relay.json'):
                        raise CredentialError()
                    data['reminder-relay.json'] = source_bytes(source_fd, 'reminder-relay.json')
            # Validate every input and existing destination before any output.
            for name in data:
                try:
                    info = os.stat(name, dir_fd=runtime_fd, follow_symlinks=False)
                except FileNotFoundError:
                    continue
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                        or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
                    raise CredentialError()
            for name, content in data.items():
                temporary = '.credential-' + secrets.token_hex(16)
                fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=runtime_fd)
                try:
                    with os.fdopen(fd, 'wb') as stream:
                        os.fchmod(stream.fileno(), 0o600)
                        stream.write(content)
                        stream.flush()
                        os.fsync(stream.fileno())
                    # Atomic replacement never follows a destination symlink.
                    os.replace(temporary, name, src_dir_fd=runtime_fd, dst_dir_fd=runtime_fd)
                finally:
                    try:
                        os.unlink(temporary, dir_fd=runtime_fd)
                    except FileNotFoundError:
                        pass
        finally:
            os.close(runtime_fd)
    finally:
        os.close(source_fd)


def main():
    try:
        runtime = Path('/run/personal-worker' if SERVICE == 'worker' else '/run/personal-push-gateway')
        prepare(os.environ['CREDENTIALS_DIRECTORY'], runtime)
    except Exception:
        raise SystemExit('Credential preparation refused') from None


if __name__ == '__main__':
    main()
