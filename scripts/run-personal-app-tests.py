#!/usr/bin/env python3
"""Run the real Flutter application graph with a command-scoped Apple SDK.

hooks_runner filters SDK environment variables. On macOS a temporary CMake
launcher passes the actual CLT SDK as supported toolchain defines instead. All
native hooks, libraries and test assertions remain enabled. No package, global
toolchain selection or existing CMake cache is deleted or patched.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


DEFAULT_TESTS = [
    'test/client_manager_startup_regression_test.dart',
    'test/client_startup_widget_test.dart',
    'test/personal/personal_diagnostics_test.dart',
    'test/personal/error_reporter_network_test.dart',
    'test/personal/personal_client_startup_test.dart',
    'test/personal/sdk_startup_preservation_test.dart',
    'test/personal/bridge_conversation_identity_test.dart',
    'test/notion/conversation_controller_test.dart',
    'test/notion/settings_controller_test.dart',
    'test/notion/settings_routes_controller_test.dart',
    'test/notion/settings_widgets_test.dart',
    'test/notion/inbox_controller_test.dart',
    'test/notion/chat_preferences_controller_test.dart',
    'test/notion/push_preferences_controller_test.dart',
    'test/notion/details_adapter_test.dart',
    'test/notion/inbox_widgets_test.dart',
    'test/notion/conversation_widgets_test.dart',
    'test/notion/two_column_accessibility_test.dart',
    'test/personal/bridged_message_content_test.dart',
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter', required=True, type=Path)
    parser.add_argument('--cmake', type=Path, help='Actual isolated CMake executable, required on macOS')
    parser.add_argument('--sdk', type=Path, help='Actual installed Apple SDK (default: xcrun macosx SDK)')
    parser.add_argument('--preflight-only', action='store_true')
    parser.add_argument('--log', type=Path, help='New synthetic test log (refuses to overwrite an existing file)')
    parser.add_argument('tests', nargs='*', default=DEFAULT_TESTS)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    flutter = args.flutter.absolute()
    if not flutter.is_file() or not os.access(flutter, os.X_OK):
        parser.error('Flutter executable is unavailable')
    env = os.environ.copy()
    sdk = None
    cmake = None
    make = None
    if sys.platform == 'darwin':
        if args.cmake is None:
            parser.error('--cmake must identify the real isolated CMake executable on macOS')
        cmake = args.cmake.absolute()
        if not cmake.is_file() or not os.access(cmake, os.X_OK):
            parser.error('CMake executable is unavailable')
        sdk = args.sdk or Path(subprocess.check_output(
            ['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip())
        sdk = sdk.resolve(strict=True)
        if not (sdk / 'SDKSettings.json').is_file():
            parser.error('Expected a real installed SDK with SDKSettings.json')
        make_path = shutil.which('make')
        if make_path is None:
            parser.error('Actual make executable is unavailable')
        make = Path(make_path).resolve(strict=True)
    tests = args.tests or DEFAULT_TESTS
    if any(not (root / path).is_file() for path in tests):
        parser.error('A selected suite does not exist')
    print(json.dumps({'native_hooks': 'enabled', 'test_suites': tests,
                      'sdk': str(sdk) if sdk else None,
                      'cmake': str(cmake) if cmake else None,
                      'execution': 'NOT RUN' if args.preflight_only else 'starting'}), flush=True)
    if args.preflight_only:
        return 0
    tool_root = root / '.dart_tool'
    tool_root.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='personal-app-test-toolchain-', dir=tool_root) as temporary:
        if sdk is not None:
            # This launcher forwards to real CMake; it never supplies fake output.
            # Keep the hook's existing Unix Makefiles generator/cache compatible.
            launcher = Path(temporary) / 'cmake'
            launcher.write_text(
                '#!' + sys.executable + '\n'
                'import os, sys\n'
                'args = sys.argv[1:]\n'
                'if "-S" in args:\n'
                '    args += ' + repr([
                    '-DCMAKE_OSX_SYSROOT_INT=' + str(sdk),
                    '-DSDK_VERSION=' + str(json.loads((sdk / 'SDKSettings.json').read_text())['Version']),
                    '-DCMAKE_MAKE_PROGRAM=' + str(make),
                ]) + '\n'
                'os.execv(' + repr(str(cmake)) + ', [' + repr(str(cmake)) + '] + args)\n'
            )
            launcher.chmod(0o700)
            env['PATH'] = temporary + os.pathsep + str(cmake.parent) + os.pathsep + env.get('PATH', '')
        command = [str(flutter), 'test', '--no-pub', *tests]
        if args.log is None:
            return subprocess.run(command, cwd=root, env=env).returncode
        # Test fixtures are synthetic; account/browser logging is not supported.
        # Exclusive creation preserves prior evidence, including failed runs.
        with args.log.open('xb') as log:
            with subprocess.Popen(command, cwd=root, env=env, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT) as process:
                for chunk in iter(lambda: process.stdout.read1(65536), b''):
                    log.write(chunk)
                    log.flush()
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                return process.wait()


if __name__ == '__main__':
    sys.exit(main())
