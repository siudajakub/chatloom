"""Regression checks for the cgroup boundary of deployed worker tools.

These validate templates only; Linux systemd acceptance remains a runtime gate.
"""
import configparser
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parent


def unit(name):
    document = configparser.ConfigParser(interpolation=None)
    document.optionxform = str
    document.read(ROOT / name)
    return document


class ResourcePolicyTests(unittest.TestCase):
    def test_daemon_cgroup_cleans_all_children_and_bounds_restart_storms(self):
        for name in ('personal-worker.service', 'personal-worker-source.service'):
            with self.subTest(unit=name):
                document = unit(name)
                service = document['Service']
                self.assertEqual(service['KillMode'], 'control-group')
                self.assertEqual(service['OOMPolicy'], 'kill')
                self.assertEqual(service['MemorySwapMax'], '0')
                self.assertEqual(service['CPUQuota'], '100%')
                self.assertLessEqual(int(service['TasksMax']), 128)
                self.assertGreater(int(service['TasksMax']), 0)
                self.assertEqual(document['Unit']['StartLimitIntervalSec'], '300')
                self.assertEqual(document['Unit']['StartLimitBurst'], '5')

    def test_adapter_budget_is_separate_from_the_worker_and_beeper_server(self):
        adapter = unit('personal-worker-source.service')['Service']
        worker = unit('personal-worker.service')['Service']
        self.assertEqual(adapter['MemoryHigh'], '256M')
        self.assertEqual(adapter['MemoryMax'], '512M')
        self.assertEqual(adapter['TasksMax'], '32')
        self.assertEqual(worker['MemoryHigh'], '768M')
        self.assertEqual(worker['MemoryMax'], '1536M')
        self.assertEqual(worker['TasksMax'], '128')
        self.assertEqual(adapter['IPAddressDeny'], 'any')
        self.assertEqual(adapter['IPAddressAllow'], 'localhost')
        self.assertNotIn('beeper serve', adapter['ExecStart'])
        self.assertEqual(adapter['User'], 'eouser')
        self.assertEqual(adapter['Group'], 'personalworker')

    def test_offline_commands_cannot_escape_the_worker_resource_boundary(self):
        service = unit('personal-worker.service')['Service']
        for name in ('admin.sh', 'session.sh'):
            with self.subTest(script=name):
                script = (ROOT / name).read_text()
                for key in ('KillMode', 'OOMPolicy', 'MemoryHigh', 'MemoryMax',
                            'MemorySwapMax', 'TasksMax', 'CPUQuota', 'TimeoutStopSec'):
                    self.assertIn(f'--property={key}={service[key]}', script)


if __name__ == '__main__':
    unittest.main()
