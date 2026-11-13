#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Inspect hashed, pinned pub archives for iOS packaging without Flutter.

Writes JSON to stdout; does not extract packages or modify the lockfile.
Manifest presence is not evidence that xcross can build or run a plugin.
"""

import concurrent.futures
import hashlib
import io
import json
from pathlib import Path
import re
import sys
import tarfile
import urllib.request


def pinned_packages(lockfile):
    text = lockfile.read_text(encoding="utf-8")
    for name, block in re.findall(
        r"^  ([a-zA-Z0-9_]+):\n(.*?)(?=^  [a-zA-Z0-9_]+:|^sdks:|\Z)",
        text,
        re.MULTILINE | re.DOTALL,
    ):
        if 'source: hosted' not in block:
            continue
        version = re.search(r'^    version: "([^"]+)"', block, re.MULTILINE)
        checksum = re.search(r'^      sha256: "?([a-f0-9]{64})"?', block, re.MULTILINE)
        host = re.search(r'^      url: "([^"]+)"', block, re.MULTILINE)
        if not all((version, checksum, host)) or host.group(1) != 'https://pub.dev':
            raise ValueError(f"Unsupported or incomplete hosted dependency: {name}")
        yield name, version.group(1), checksum.group(1)


def inspect(package):
    name, version, checksum = package
    result = {"package": name, "version": version}
    try:
        url = f"https://pub.dev/api/archives/{name}-{version}.tar.gz"
        with urllib.request.urlopen(url, timeout=60) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != checksum:
            raise ValueError("Archive SHA-256 differs from pubspec.lock")
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
            paths = archive.getnames()
            manifests = sorted(p for p in paths if p.endswith('Package.swift')
                               and p.startswith(('ios/', 'darwin/')))
            pods = sorted(p for p in paths if p.endswith('.podspec')
                          and p.startswith(('ios/', 'darwin/')))
            result.update(sha256_verified=True, swiftpm=manifests, cocoapods=pods,
                          native_hook='hook/build.dart' in paths)
            result['packaging'] = ('swiftpm' if manifests else 'podspec-only'
                                   if pods else 'native-hook' if result['native_hook']
                                   else 'no-ios-manifest')
    except Exception as error:
        result['error'] = str(error)
    return result


def main():
    root = Path(__file__).resolve().parents[2]
    packages = list(pinned_packages(root / 'pubspec.lock'))
    if len(sys.argv) > 1:
        selected = set(sys.argv[1:])
        packages = [p for p in packages if p[0] in selected]
        missing = selected - {p[0] for p in packages}
        if missing:
            raise ValueError(f"Packages not found in lockfile: {sorted(missing)}")
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        results = list(pool.map(inspect, packages))
    print(json.dumps({"scope": "packaging only; no compilation or runtime test",
                      "packages": results}, indent=2))
    return int(any('error' in result for result in results))


if __name__ == '__main__':
    sys.exit(main())
