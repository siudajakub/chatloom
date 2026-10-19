# SPDX-License-Identifier: AGPL-3.0-or-later
"""Only synthetic files: exercise both independently deployed preparers."""
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


worker = load('worker_credential_preparer', ROOT / 'worker/deploy/prepare_credentials.py')
gateway = load('gateway_credential_preparer', ROOT / 'push-gateway/prepare_credentials.py')
app = load('gateway_credential_app', ROOT / 'push-gateway/gateway.py')


class WorkerCredentialsTests(unittest.TestCase):
    preparer = worker

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'
        self.runtime = self.root / 'runtime'
        self.source.mkdir(mode=0o700)
        self.runtime.mkdir(mode=0o700)
        self.primary = self.source / 'credentials.json'
        self.write(self.primary, b'{"databaseCipher":"synthetic"}')

    def write(self, path, data):
        if path.exists():
            path.chmod(0o600)
        path.write_bytes(data)
        path.chmod(0o440)

    def prepare(self):
        self.preparer.prepare(self.source, self.runtime)

    def assert_refused(self):
        with self.assertRaises((self.preparer.CredentialError, OSError, ValueError)):
            self.prepare()
        self.assertEqual(list(self.runtime.iterdir()), [])

    def test_read_only_systemd_copy_is_private_and_repeatable(self):
        self.prepare()
        self.prepare()
        copied = self.runtime / self.primary.name
        self.assertEqual(copied.read_bytes(), self.primary.read_bytes())
        self.assertEqual(stat.S_IMODE(copied.stat().st_mode), 0o600)
        self.assertEqual(copied.stat().st_uid, os.geteuid())

    def test_reject_source_modes(self):
        for mode in (0o444, 0o640, 0o660, 0o700, 0o777):
            with self.subTest(mode=mode):
                self.primary.chmod(mode)
                self.assert_refused()

    def test_reject_oversize(self):
        self.write(self.primary, b'x' * 65537)
        self.assert_refused()

    def test_reject_source_symlink(self):
        target = self.root / 'target'
        self.primary.rename(target)
        self.primary.symlink_to(target)
        self.assert_refused()

    def test_reject_source_hardlink(self):
        os.link(self.primary, self.root / 'alias')
        self.assert_refused()

    def test_reject_source_fifo_without_blocking(self):
        self.primary.unlink()
        os.mkfifo(self.primary, 0o400)
        self.assert_refused()

    def test_reject_directory_symlinks(self):
        for name in ('source', 'runtime'):
            with self.subTest(name=name):
                directory = getattr(self, name)
                moved = self.root / (name + '-real')
                directory.rename(moved)
                directory.symlink_to(moved, target_is_directory=True)
                self.assert_refused()
                directory.unlink()
                moved.rename(directory)

    def test_reject_non_private_runtime(self):
        self.runtime.chmod(0o750)
        self.assert_refused()

    def test_reject_writable_source_directory(self):
        self.source.chmod(0o770)
        self.assert_refused()

    def test_reject_foreign_owner(self):
        original = os.fstat
        for selected in ('file', 'runtime', 'source'):
            with self.subTest(selected=selected):
                def fstat(fd):
                    info = original(fd)
                    match = (stat.S_ISREG(info.st_mode) if selected == 'file'
                             else info.st_ino == getattr(self, selected).stat().st_ino)
                    if match:
                        fields = list(info)
                        fields[4] = 123456789
                        return os.stat_result(fields)
                    return info
                with patch.object(self.preparer.os, 'fstat', side_effect=fstat):
                    self.assert_refused()

    def test_reject_unrelated_group_for_group_readable_file(self):
        with patch.object(self.preparer.os, 'getgroups', return_value=[]), patch.object(
                self.preparer.os, 'getegid', return_value=123456789):
            self.assert_refused()

    def test_reject_destination_symlink_without_touching_target(self):
        target = self.root / 'target'
        target.write_bytes(b'unchanged')
        destination = self.runtime / self.primary.name
        destination.symlink_to(target)
        with self.assertRaises(self.preparer.CredentialError):
            self.prepare()
        self.assertEqual(target.read_bytes(), b'unchanged')
        self.assertTrue(destination.is_symlink())

    def test_missing_credential_refuses_before_output(self):
        self.primary.unlink()
        self.assert_refused()

    def test_failure_diagnostics_never_contain_inputs(self):
        with patch.dict(os.environ, {'CREDENTIALS_DIRECTORY': 'SECRET_CANARY'}):
            with self.assertRaises(SystemExit) as caught:
                self.preparer.main()
        self.assertEqual(str(caught.exception), 'Credential preparation refused')


class GatewayCredentialsTests(WorkerCredentialsTests):
    preparer = gateway

    def test_root_readonly_systemd_acl_credentials_are_copied_privately(self):
        original = os.fstat
        def root_credentials(fd):
            info = original(fd)
            if stat.S_ISREG(info.st_mode):
                fields = list(info)
                fields[4], fields[5] = 0, 987654321
                return os.stat_result(fields)
            return info
        with patch.object(self.preparer.os, 'fstat', side_effect=root_credentials), patch.object(
                self.preparer.os, 'getgroups', return_value=[]), patch.object(
                self.preparer.os, 'getegid', return_value=123456789), patch.object(
                self.preparer.os, 'fstatvfs', return_value=SimpleNamespace(f_flag=os.ST_RDONLY)):
            self.prepare()
        self.assertEqual((self.runtime / self.primary.name).read_bytes(), self.primary.read_bytes())
        self.assertEqual(stat.S_IMODE((self.runtime / self.primary.name).stat().st_mode), 0o600)

    def test_readonly_mount_never_allows_world_readable_or_group_writable_source(self):
        for mode in (0o444, 0o640, 0o660):
            with self.subTest(mode=mode):
                self.primary.chmod(mode)
                with patch.object(self.preparer.os, 'fstatvfs', return_value=SimpleNamespace(f_flag=os.ST_RDONLY)):
                    self.assert_refused()

    def setUp(self):
        super().setUp()
        self.primary.unlink()
        self.primary = self.source / 'gateway-config.json'
        self.config = dict(project_id='fixture-project', registrations=[],
                           service_account_file=str(self.runtime / 'fcm-service-account.json'),
                           state_directory=str(self.root / 'state'))
        self.write_config()
        self.write(self.source / 'fcm-service-account.json', b'{"synthetic":true}')

    def write_config(self):
        self.write(self.primary, json.dumps(self.config).encode())

    def enable_reminder(self):
        self.config['reminder_credential_file'] = str(self.runtime / 'reminder-relay.json')
        self.write_config()
        self.write(self.source / 'reminder-relay.json', json.dumps({'token': 'r' * 43}).encode())

    def test_gateway_initializes_without_reminder(self):
        self.prepare()
        config = app.Config.load(self.runtime / 'gateway-config.json')
        initialized = app.Gateway(config, object())
        self.assertIsNone(initialized.reminder_token)
        self.assertFalse((self.runtime / 'reminder-relay.json').exists())
        app.private_json(config.service_account_file)

    def test_gateway_initializes_with_private_reminder(self):
        self.enable_reminder()
        self.prepare()
        config = app.Config.load(self.runtime / 'gateway-config.json')
        initialized = app.Gateway(config, object())
        self.assertEqual(initialized.reminder_token, 'r' * 43)
        self.assertEqual(stat.S_IMODE((self.runtime / 'reminder-relay.json').stat().st_mode), 0o600)

    def test_enabled_missing_reminder_refuses_before_output(self):
        self.enable_reminder()
        (self.source / 'reminder-relay.json').unlink()
        self.assert_refused()

    def test_reminder_symlink_mode_size_are_rejected(self):
        self.enable_reminder()
        reminder = self.source / 'reminder-relay.json'
        reminder.chmod(0o444)
        self.assert_refused()
        self.write(reminder, b'x' * 65537)
        self.assert_refused()
        reminder.unlink()
        reminder.symlink_to(self.primary)
        self.assert_refused()

    def test_mismatched_runtime_paths_refuse(self):
        for field in ('service_account_file', 'reminder_credential_file'):
            with self.subTest(field=field):
                self.config[field] = '/run/credentials/wrong/source.json'
                self.write_config()
                self.assert_refused()
                if field == 'service_account_file':
                    self.config[field] = str(self.runtime / 'fcm-service-account.json')

    def test_malformed_enabled_reminder_refuses_gateway_start(self):
        self.enable_reminder()
        self.write(self.source / 'reminder-relay.json', b'{"token":"short"}')
        self.prepare()
        with self.assertRaises(app.ConfigError):
            app.Gateway(app.Config.load(self.runtime / 'gateway-config.json'), object())

    def test_templates_use_runtime_copy_paths(self):
        config = json.loads((ROOT / 'push-gateway/config.example.json').read_text())
        self.assertEqual(config['service_account_file'], '/run/personal-push-gateway/fcm-service-account.json')
        config = json.loads((ROOT / 'worker/config.example.json').read_text())
        self.assertEqual(config['credentialsPath'], '/run/personal-worker/credentials.json')
        unit = (ROOT / 'worker/deploy/personal-worker.service').read_text()
        self.assertIn('ExecStartPre=/usr/bin/python3 /opt/personal-worker/prepare_credentials.py', unit)
        self.assertIn('RuntimeDirectoryMode=0700', unit)
