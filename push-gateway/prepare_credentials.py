"""Copy systemd credentials into the service-owned private runtime directory.

Some systemd versions expose credentials as root:service-group mode 0440.
Keep the gateway's stricter owner-only file validation unchanged.
"""
import os
from pathlib import Path

runtime = Path('/run/personal-push-gateway')
source = Path(os.environ['CREDENTIALS_DIRECTORY'])
if runtime.stat().st_uid != os.geteuid() or runtime.stat().st_mode & 0o077:
    raise SystemExit('Invalid private runtime directory')
for name in ('gateway-config.json', 'fcm-service-account.json'):
    data = (source / name).read_bytes()
    if len(data) > 65536:
        raise SystemExit('Credential exceeds limit')
    fd = os.open(runtime / name, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as out:
        os.fchmod(out.fileno(), 0o600)
        out.write(data)
