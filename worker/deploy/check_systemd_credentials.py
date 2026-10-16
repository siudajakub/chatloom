#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Synthetic transient units; run as root ONLY in a disposable Linux/systemd VM."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--isolated-fixture', action='store_true', required=True)
    parser.parse_args()
    if os.geteuid() != 0 or not Path('/run/systemd/system').is_dir():
        raise SystemExit('Requires root in an isolated Linux/systemd fixture')
    root = Path(__file__).resolve().parents[2]
    for name in ('personal-worker', 'personal-push-gateway'):
        if Path('/run', name).exists():
            raise SystemExit('Fixture runtime path already exists; refusing')
    with tempfile.TemporaryDirectory(prefix='personal-credential-fixture-') as directory:
        fixture = Path(directory)
        fixture.chmod(0o755)
        shutil.copyfile(root / 'push-gateway/gateway.py', fixture / 'gateway.py')
        (fixture / 'gateway.py').chmod(0o444)
        for service, relay in (('worker', False), ('gateway', False), ('gateway', True)):
            runtime = Path('/run/personal-worker' if service == 'worker' else '/run/personal-push-gateway')
            preparer = (root / 'worker/deploy/prepare_credentials.py' if service == 'worker'
                        else root / 'push-gateway/prepare_credentials.py')
            shutil.copyfile(preparer, fixture / 'prepare.py')
            (fixture / 'prepare.py').chmod(0o444)
            content = {'credentials.json': {'databaseCipher': 'a' * 64}}
            if service == 'gateway':
                config = dict(project_id='fixture-project', registrations=[],
                              service_account_file=str(runtime / 'fcm-service-account.json'),
                              state_directory=str(runtime / 'state'))
                content = {'gateway-config.json': config, 'fcm-service-account.json': {'fixture': True}}
                if relay:
                    config['reminder_credential_file'] = str(runtime / 'reminder-relay.json')
                    content['reminder-relay.json'] = {'token': 'r' * 43}
            command = ['systemd-run', '--wait', '--pipe', '--collect',
                       '--unit=personal-credential-' + service + '-fixture',
                       '-p', 'DynamicUser=yes', '-p', 'UMask=0077',
                       '-p', 'RuntimeDirectory=' + runtime.name,
                       '-p', 'RuntimeDirectoryMode=0700',
                       '-p', 'ExecStartPre=/usr/bin/python3 ' + str(fixture / 'prepare.py')]
            for name, value in content.items():
                source = fixture / name
                source.write_text(json.dumps(value))
                source.chmod(0o600)
                command += ['-p', 'LoadCredential=' + name + ':' + str(source)]
            probe = """import json, os, pathlib, stat, sys
assert os.geteuid() != 0
runtime = pathlib.Path(sys.argv[1])
for name in json.loads(sys.argv[2]):
    path = runtime / name
    info = path.lstat()
    assert stat.S_ISREG(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o600
    assert info.st_uid == os.geteuid()
    json.loads(path.read_bytes())
if (runtime / 'gateway-config.json').exists():
    sys.path.insert(0, sys.argv[3])
    import gateway
    instance = gateway.Gateway(gateway.Config.load(runtime / 'gateway-config.json'), object())
    assert bool(instance.reminder_token) == (sys.argv[4] == 'True')
print('Synthetic service credentials PASS')
"""
            command += ['/usr/bin/python3', '-c', probe, str(runtime),
                        json.dumps(list(content)), str(fixture), str(relay)]
            subprocess.run(command, check=True)


if __name__ == '__main__':
    main()
