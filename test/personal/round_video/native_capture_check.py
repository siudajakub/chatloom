#!/usr/bin/env python3
"""Compile Android native sources; execute pure production helper fixtures.

Run only after native edits settle. This never runs Camera2, EGL, a codec, an
Android account or a device. The temporary compiler inputs are immutable copies
and the production sources must still match their hashes after execution.
"""
from pathlib import Path
import hashlib
import os
import subprocess
import tempfile

CLIENT = Path(__file__).resolve().parents[3]
CACHE = Path.home() / '.gradle/caches/modules-2/files-2.1'
FIXTURES = {
    'capture_codec_native_test.kt': 'Capture_codec_native_testKt',
    'capture_controls_native_test.kt': 'Capture_controls_native_testKt',
    'capture_trim_native_test.kt': 'Capture_trim_native_testKt',
    'capture_quality_native_test.kt': 'Capture_quality_native_testKt',
}


def jar(group, module, version):
    return next((CACHE / group / module / version).glob('*/*.jar'))


def main():
    compiler = [
        jar('org.jetbrains.kotlin', 'kotlin-compiler-embeddable', '2.2.20'),
        jar('org.jetbrains.kotlin', 'kotlin-stdlib', '2.2.20'),
        jar('org.jetbrains.kotlin', 'kotlin-script-runtime', '2.2.20'),
        jar('org.jetbrains.kotlin', 'kotlin-reflect', '1.6.10'),
        jar('org.jetbrains.kotlin', 'kotlin-daemon-embeddable', '2.2.20'),
        jar('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.8.0'),
        jar('org.jetbrains', 'annotations', '23.0.0'),
    ]
    java = Path(os.environ.get('JAVA_HOME', '/opt/homebrew/opt/openjdk@17')) / 'bin/java'
    sdk = dict(line.split('=', 1) for line in (CLIENT / 'android/local.properties').read_text().splitlines() if '=' in line)['sdk.dir']
    android = Path(sdk) / 'platforms/android-37.0/android.jar'
    flutter = next((CACHE / 'io.flutter/flutter_embedding_release').glob('*/*/*.jar'))
    compile_classpath = os.pathsep.join(map(str, [compiler[1], compiler[-1], flutter, android]))
    sources = sorted((CLIENT / 'android/app/src/main/kotlin/pl/personal/chatloom/round').glob('*.kt'))
    sources.extend(Path(__file__).with_name(name) for name in FIXTURES)
    snapshot = {}
    for source in sources:
        if not source.is_file() or source.is_symlink():
            raise RuntimeError(f'Expected native source/fixture absent or symlinked: {source.name}')
        snapshot[source] = source.read_bytes()
    manifest = {str(path.relative_to(CLIENT)): hashlib.sha256(data).hexdigest()
                for path, data in snapshot.items()}
    manifest_hash = hashlib.sha256('\n'.join(f'{path} {digest}' for path, digest in sorted(manifest.items())).encode()).hexdigest()
    with tempfile.TemporaryDirectory(prefix='round-native-check-') as temp:
        inputs = Path(temp) / 'inputs'
        classes = Path(temp) / 'classes'
        inputs.mkdir()
        copied = []
        for index, (source, data) in enumerate(snapshot.items()):
            directory = inputs / str(index)
            directory.mkdir()
            target = directory / source.name
            target.write_bytes(data)
            copied.append(target)
        try:
            subprocess.run(['rtk', str(java), '-cp', os.pathsep.join(map(str, compiler)),
                            'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect',
                            '-jvm-target', '11', '-classpath', compile_classpath, '-d', str(classes),
                            *map(str, copied)], check=True)
            for entrypoint in FIXTURES.values():
                subprocess.run(['rtk', str(java), '-cp', str(classes) + os.pathsep + str(compiler[1]),
                                f'pl.personal.chatloom.round.{entrypoint}'], check=True)
        finally:
            if any(not path.is_file() or path.is_symlink() or path.read_bytes() != data
                   for path, data in snapshot.items()):
                raise RuntimeError('Native source/fixture changed during verification; result is invalid')
        print(f'PASS native source guard: {len(manifest)} immutable sources/fixtures, manifest SHA256 {manifest_hash}')


if __name__ == '__main__':
    main()
