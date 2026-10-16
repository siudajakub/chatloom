#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Run exact production push/readiness policy sources without native app hooks."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--dart', default='dart')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
paths = ['lib/personal/push_registration.dart', 'lib/personal/worker_readiness.dart',
         'test/personal/integration/push_readiness_test.dart']
with tempfile.TemporaryDirectory(prefix='personal_push_checks_') as directory:
    target = Path(directory)
    for path in paths:
        data = (root / path).read_bytes()
        copied = target / path
        copied.parent.mkdir(parents=True, exist_ok=True)
        copied.write_bytes(data)
        assert hashlib.sha256(copied.read_bytes()).digest() == hashlib.sha256(data).digest()
    subprocess.run([args.dart, str(target / paths[-1])], check=True, cwd=target)
print('PASS exact-source push/readiness policy fixture; native plugin delivery remains NOT RUN')
