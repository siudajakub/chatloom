import importlib.util
import os
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('prepare', Path(__file__).with_name('prepare_credentials.py'))
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class SystemdMountTests(unittest.TestCase):
    def test_root_group_exception_requires_real_read_only_systemd_mount(self):
        root = SimpleNamespace(st_uid=0, st_gid=0, st_mode=0o40550)
        with patch.object(prepare.sys, 'platform', 'linux'), patch.object(
                prepare.os, 'fstatvfs', return_value=SimpleNamespace(f_flag=os.ST_RDONLY)):
            self.assertTrue(prepare.is_systemd_root_group_source(Path('/run/credentials/unit'), 0, root))
            self.assertFalse(prepare.is_systemd_root_group_source(Path('/tmp/unit'), 0, root))
            self.assertFalse(prepare.is_systemd_root_group_source(Path('/run/credentials/unit'), 0,
                             SimpleNamespace(st_uid=42, st_gid=0, st_mode=0o40550)))
            self.assertFalse(prepare.is_systemd_root_group_source(Path('/run/credentials/unit'), 0,
                             SimpleNamespace(st_uid=0, st_gid=42, st_mode=0o40550)))
            self.assertFalse(prepare.is_systemd_root_group_source(Path('/run/credentials/unit'), 0,
                             SimpleNamespace(st_uid=0, st_gid=0, st_mode=0o40750)))
        with patch.object(prepare.sys, 'platform', 'linux'), patch.object(
                prepare.os, 'fstatvfs', return_value=SimpleNamespace(f_flag=0)):
            self.assertFalse(prepare.is_systemd_root_group_source(Path('/run/credentials/unit'), 0, root))


if __name__ == '__main__':
    unittest.main()
