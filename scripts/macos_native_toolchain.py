#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Scope the pinned webcrypto Apple/Intel source-list fix to this build."""
import os
import hashlib
from pathlib import Path
import platform
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]


def prepare_native_environment(environment=None):
    env = dict(os.environ if environment is None else environment)
    if sys.platform != 'darwin' or platform.machine() != 'x86_64':
        return env
    hook = ROOT / 'scripts/macos-webcrypto.cmake'
    tools_root = ROOT / 'build/macos-native-tools'
    tools = tools_root / hashlib.sha256(hook.read_bytes()).hexdigest()[:12]
    tools.mkdir(parents=True, exist_ok=True)
    search = os.pathsep.join(
        entry for entry in env.get('PATH', '').split(os.pathsep)
        if Path(entry).resolve() != tools_root.resolve()
        and tools_root.resolve() not in Path(entry).resolve().parents
    )
    cmake = shutil.which('cmake', path=search)
    if not cmake:
        raise SystemExit('CMake is required for the macOS Intel native build')
    wrapper = tools / 'cmake'
    wrapper.write_text(
        '#!/usr/bin/env python3\n'
        'import os, sys\nfrom pathlib import Path\n'
        'args = sys.argv[1:]\n'
        'if "-S" in args:\n'
        '    source = Path(args[args.index("-S") + 1])\n'
        '    if source.name == "src" and source.parent.name == "webcrypto-0.6.1":\n'
        '        args.append(' + repr('-DCMAKE_PROJECT_INCLUDE=' + str(hook)) + ')\n'
        'os.execv(' + repr(cmake) + ', [' + repr(cmake) + '] + args)\n'
    )
    wrapper.chmod(0o700)
    env['PATH'] = str(tools) + os.pathsep + search
    return env


if __name__ == '__main__':
    result = prepare_native_environment()
    if result['PATH'] != os.environ.get('PATH'):
        with open(os.environ['GITHUB_PATH'], 'a') as handle:
            handle.write(result['PATH'].split(os.pathsep)[0] + '\n')
        print('Prepared scoped Apple x86_64 webcrypto source-list fix')
