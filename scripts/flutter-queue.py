#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Serialize Flutter analyze/test jobs in this checkout with a stable environment.

Several agents or terminals may edit client/ at once, but Flutter jobs share
.dart_tool and build/ and must not run concurrently. Every job takes an
exclusive lock on .dart_tool/personal-flutter-queue.lock and waits its turn.

Native build hooks (webcrypto, sqlite3/SQLCipher, objective_c) key their cache
on PATH, TMPDIR, HOME and ANDROID_HOME. A random PATH entry per run (the old
temporary CMake launcher, or per-shell tool directories) forced a full native
rebuild on every `flutter test`. This runner uses one fixed environment and a
fixed CMake launcher, so warm runs reuse the native cache.

Examples (from client/):
  python3 scripts/flutter-queue.py analyze lib/personal/round_video
  python3 scripts/flutter-queue.py test test/notion/compact_composer_test.dart test/personal/round_video
  python3 scripts/flutter-queue.py flutter gen-l10n
  python3 scripts/flutter-queue.py run --cwd worker -- ../../spikes/toolchains/flutter-3.47.4/bin/dart test test/engine_test.dart

Batch several test files into one `test` call: the app-graph compile is paid
once per invocation, additional files in the same call are cheap.
"""
import argparse
import fcntl
import glob
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT.parent
DEFAULT_FLUTTER = PROJECT / 'spikes/toolchains/flutter-3.47.4/bin/flutter'
TOOL_ROOT = ROOT / '.dart_tool'
LOCK = TOOL_ROOT / 'personal-flutter-queue.lock'
HOLDER = TOOL_ROOT / 'personal-flutter-queue.holder.json'
TOOLS_BIN = TOOL_ROOT / 'personal-tools' / 'bin'
STABLE_TMP = TOOL_ROOT / 'personal-tmp'


def resolve_cmake():
    configured = os.environ.get('PERSONAL_CMAKE')
    if configured:
        return Path(configured)
    # The isolated venv's console script may point at a removed interpreter;
    # the wheel's real binary does not depend on Python.
    pattern = str(PROJECT / 'spikes/toolchains/native-tools/lib/python*/site-packages/cmake/data/bin/cmake')
    for candidate in sorted(glob.glob(pattern)):
        if os.access(candidate, os.X_OK):
            return Path(candidate)
    found = shutil.which('cmake')
    return Path(found) if found else None


def write_if_changed(path, text, mode):
    if not path.exists() or path.read_text() != text:
        path.write_text(text)
    path.chmod(mode)


def stable_env(flutter):
    """One fixed environment for every job so native hook caches stay valid."""
    TOOLS_BIN.mkdir(parents=True, exist_ok=True)
    STABLE_TMP.mkdir(parents=True, exist_ok=True)
    path = [str(TOOLS_BIN), str(flutter.parent)]
    if os.environ.get('CARGO_HOME'):
        path.append(str(Path(os.environ['CARGO_HOME']) / 'bin'))
    if sys.platform == 'darwin':
        cmake = resolve_cmake()
        if cmake is None:
            raise SystemExit('No usable CMake; set PERSONAL_CMAKE')
        sdk = Path(subprocess.check_output(
            ['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()).resolve(strict=True)
        version = json.loads((sdk / 'SDKSettings.json').read_text())['Version']
        make = Path(shutil.which('make') or '/usr/bin/make').resolve(strict=True)
        # Forwards to the real CMake; hooks_runner filters SDK variables, so the
        # actual CLT SDK is passed as toolchain defines (see run-personal-app-tests.py).
        write_if_changed(TOOLS_BIN / 'cmake', (
            '#!/usr/bin/python3\n'
            'import os, sys\n'
            'args = sys.argv[1:]\n'
            'if "-S" in args:\n'
            '    args += ' + repr([
                '-DCMAKE_OSX_SYSROOT_INT=' + str(sdk),
                '-DSDK_VERSION=' + str(version),
                '-DCMAKE_MAKE_PROGRAM=' + str(make),
            ]) + '\n'
            'os.execv(' + repr(str(cmake)) + ', [' + repr(str(cmake)) + '] + args)\n'
        ), 0o700)
        path.append(str(cmake.parent))
    path += ['/usr/bin', '/bin', '/usr/sbin', '/sbin']
    env = {
        'PATH': os.pathsep.join(path),
        'HOME': os.environ.get('HOME', str(Path.home())),
        'TMPDIR': str(STABLE_TMP) + '/',
        'LANG': 'en_US.UTF-8',
        'LC_ALL': 'en_US.UTF-8',
        'USER': os.environ.get('USER', ''),
        'PUB_CACHE': os.environ.get('PUB_CACHE', str(Path.home() / '.pub-cache')),
        'FLUTTER_SUPPRESS_ANALYTICS': 'true',
    }
    # Capture directories only tell tests where to write screenshots; native
    # hooks do not key on them.
    for key in ('ANDROID_HOME', 'ANDROID_SDK_ROOT', 'ANDROID_USER_HOME',
                'JAVA_HOME', 'GRADLE_USER_HOME', 'CARGO_HOME', 'RUSTUP_HOME',
                'CARGO_TARGET_DIR', 'XDG_CACHE_HOME', 'CMAKE_BUILD_PARALLEL_LEVEL',
                'FFMPEG_PATH', 'FFPROBE_PATH', 'CHROME_EXECUTABLE',
                'PLAYWRIGHT_BROWSERS_PATH',
                'CONVERSATION_CAPTURE_DIR', 'NOTION_CAPTURE_DIR'):
        if os.environ.get(key):
            env[key] = os.environ[key]
    return env


def acquire(label):
    LOCK.parent.mkdir(exist_ok=True)
    handle = LOCK.open('a+')
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        try:
            holder = json.loads(HOLDER.read_text())
            print(f'[flutter-queue] waiting for: {holder.get("label")} '
                  f'(pid {holder.get("pid")}, since {holder.get("since")})', flush=True)
        except (OSError, ValueError):
            print('[flutter-queue] waiting for another Flutter job', flush=True)
        fcntl.flock(handle, fcntl.LOCK_EX)
    HOLDER.write_text(json.dumps({'label': label, 'pid': os.getpid(),
                                  'since': time.strftime('%H:%M:%S')}))
    return handle


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--flutter', type=Path, default=DEFAULT_FLUTTER)
    parser.add_argument('--label', help='Who is running this job (shown to waiting jobs)')
    parser.add_argument('--timeout', type=int, default=None,
                        help='Hard limit in seconds once the lock is held (default: test 900, run 1800, other 600). '
                             'The whole process group is killed on timeout so a hung test cannot block the queue.')
    sub = parser.add_subparsers(dest='mode', required=True)
    analyze = sub.add_parser('analyze', help='flutter analyze --no-pub <paths> (default: lib)')
    analyze.add_argument('paths', nargs='*')
    test = sub.add_parser('test', help='flutter test --no-pub with native hooks enabled')
    test.add_argument('--plain-name', help='Only run tests whose name contains this text')
    test.add_argument('tests', nargs='+', help='Test files or directories')
    raw = sub.add_parser('flutter', help='Any other flutter command, e.g. gen-l10n or pub get')
    raw.add_argument('args', nargs=argparse.REMAINDER)
    run = sub.add_parser('run', help='Any heavy command under the same lock, e.g. worker dart test')
    run.add_argument('--cwd', type=Path, default=ROOT, help='Working directory (relative to client/)')
    run.add_argument('args', nargs=argparse.REMAINDER, help='Command after --')
    args = parser.parse_args()

    flutter = args.flutter.absolute()
    cwd = ROOT
    if args.mode == 'analyze':
        command = [str(flutter), 'analyze', '--no-pub', *(args.paths or ['lib'])]
    elif args.mode == 'test':
        tests = []
        for item in args.tests:
            path = ROOT / item
            if path.is_dir():
                tests.extend(sorted(str(p.relative_to(ROOT)) for p in path.rglob('*_test.dart')))
            elif path.is_file():
                tests.append(item)
            else:
                parser.error(f'Missing test path: {item}')
        command = [str(flutter), 'test', '--no-pub']
        if args.plain_name:
            command += ['--plain-name', args.plain_name]
        command += tests
    elif args.mode == 'run':
        command = list(args.args)
        if command[:1] == ['--']:
            command = command[1:]
        if not command:
            parser.error('run needs a command after --')
        cwd = args.cwd if args.cwd.is_absolute() else ROOT / args.cwd
    else:
        command = [str(flutter), *args.args]

    label = args.label or ' '.join(command[:4])
    handle = acquire(label)
    started = time.time()
    try:
        env = stable_env(flutter) if args.mode != 'run' else {**os.environ, **{
            k: v for k, v in stable_env(flutter).items() if k in ('TMPDIR',)}}
        limit = args.timeout or {'test': 900, 'run': 1800}.get(args.mode, 600)
        process = subprocess.Popen(command, cwd=cwd, env=env, start_new_session=True)
        try:
            returncode = process.wait(timeout=limit)
        except subprocess.TimeoutExpired:
            print(f'[flutter-queue] TIMEOUT after {limit}s: killing {label}', flush=True)
            try:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=15)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
            returncode = 124
        result = subprocess.CompletedProcess(command, returncode)
    finally:
        try:
            HOLDER.unlink()
        except OSError:
            pass
        fcntl.flock(handle, fcntl.LOCK_UN)
        handle.close()
    print(f'[flutter-queue] {args.mode} exit={result.returncode} in {time.time() - started:.0f}s', flush=True)
    return result.returncode


if __name__ == '__main__':
    sys.exit(main())
