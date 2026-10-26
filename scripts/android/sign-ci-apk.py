#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Download the APK built by `personal-android-release.yml`, re-sign it with
the personal release key and publish it under a new artifact directory.

The workflow signs with a throwaway key and encrypts the APK to the devbox's
GPG key; the release key never leaves this machine. Run after
`source scripts/devbox-env.sh`:

  python3 scripts/android/sign-ci-apk.py --run-id 123456789 --out ../artifacts/ci-apk
  python3 scripts/android/sign-ci-apk.py --setup-gpg   # once: create the key, print its public half

Environment: CHATLOOM_CI_GNUPGHOME (default $PERSONAL_CHAT_RUNTIME/ci-gnupg).
Passwords are read from android/key.properties and passed to apksigner through
the environment, never on the command line or in the output.
"""
import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXPECTED_PACKAGE = "pl.personal.chat"
# Public certificate of the established personal release (same as build.py).
EXPECTED_CERTIFICATE = "ef9a14157544adc28fa167724858e35c526cf805c11e14bcf30e4e53614867ef"
WORKFLOW = "personal-android-release.yml"
GPG_UID = "ChatLoom devbox CI artifacts"


def fail(message):
    print(f"sign-ci-apk: {message}", file=sys.stderr)
    sys.exit(1)


def run(argv, env=None, capture=True):
    result = subprocess.run(argv, env=env, text=True, check=False,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    if result.returncode != 0:
        detail = (result.stderr or "").strip().splitlines()[-1:] if capture else []
        fail(f"{Path(argv[0]).name} failed (exit {result.returncode}) {' '.join(detail)}")
    return result.stdout or ""


def gnupg_home():
    default = Path(os.environ.get("PERSONAL_CHAT_RUNTIME", ROOT / ".dart_tool")) / "ci-gnupg"
    home = Path(os.environ.get("CHATLOOM_CI_GNUPGHOME", default))
    home.mkdir(mode=0o700, parents=True, exist_ok=True)
    return home


def gpg_env():
    env = dict(os.environ)
    env["GNUPGHOME"] = str(gnupg_home())
    return env


def setup_gpg():
    env = gpg_env()
    listed = run(["gpg", "--batch", "--list-secret-keys", "--with-colons"], env=env)
    if GPG_UID not in listed:
        run(["gpg", "--batch", "--passphrase", "", "--quick-generate-key", GPG_UID,
             "rsa3072", "encr", "never"], env=env)
    print(run(["gpg", "--batch", "--armor", "--export", GPG_UID], env=env), end="")


def build_tool(name):
    sdk = Path(os.environ.get("ANDROID_HOME", ""))
    tools = sorted((sdk / "build-tools").glob(f"*/{name}"))
    if not tools:
        fail(f"{name} not found under $ANDROID_HOME/build-tools; source scripts/devbox-env.sh")
    return str(tools[-1])


def key_properties():
    path = ROOT / "android" / "key.properties"
    if not path.is_file():
        fail("android/key.properties is missing")
    values = {}
    for line in path.read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    for key in ("storeFile", "storePassword", "keyPassword", "keyAlias"):
        if not values.get(key):
            fail(f"android/key.properties has no {key}")
    store = Path(values["storeFile"])
    if not store.is_absolute():
        store = ROOT / "android" / "app" / store
    if not store.is_file():
        fail("the keystore named in android/key.properties is missing")
    values["storeFile"] = str(store)
    return values


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def origin_repo():
    url = run(["git", "-C", str(ROOT), "remote", "get-url", "origin"]).strip()
    match = re.search(r"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$", url)
    if not match:
        fail("origin is not a GitHub repository")
    return match.group(1)


def download(run_id, work):
    # The checkout also has an upstream remote; gh must not guess between them.
    repo = ["--repo", origin_repo()]
    if run_id is None:
        listed = run(["gh", "run", "list", *repo, "--workflow", WORKFLOW, "--status", "success",
                      "--limit", "1", "--json", "databaseId", "--jq", ".[0].databaseId"])
        run_id = listed.strip()
        if not run_id:
            fail(f"no successful run of {WORKFLOW}")
    run(["gh", "run", "download", str(run_id), *repo, "--dir", str(work)])
    encrypted = list(work.rglob("*.apk.gpg"))
    commits = list(work.rglob("COMMIT"))
    if len(encrypted) != 1 or len(commits) != 1:
        fail("the run artifact does not hold exactly one encrypted APK and COMMIT")
    commit = commits[0].read_text().strip()
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        fail("COMMIT in the artifact is not a commit id")
    return str(run_id), encrypted[0], commit


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--setup-gpg", action="store_true",
                        help="create the devbox GPG key once and print its public key")
    parser.add_argument("--run-id", help="workflow run id (default: latest successful run)")
    parser.add_argument("--out", type=Path, help="new directory for the signed APK")
    args = parser.parse_args()
    if args.setup_gpg:
        setup_gpg()
        return
    if args.out is None:
        fail("--out is required")
    if args.out.exists():
        fail(f"{args.out} exists; choose a new directory")

    apksigner, aapt, zipalign = build_tool("apksigner"), build_tool("aapt"), build_tool("zipalign")
    keys = key_properties()
    with tempfile.TemporaryDirectory(prefix="sign-ci-apk-") as temp:
        work = Path(temp)
        run_id, encrypted, commit = download(args.run_id, work / "download")
        unsigned = work / "unsigned.apk"
        run(["gpg", "--batch", "--yes", "--quiet", "--output", str(unsigned),
             "--decrypt", str(encrypted)], env=gpg_env())
        run([zipalign, "-c", "-P", "16", "4", str(unsigned)])

        signed = work / "signed.apk"
        env = dict(os.environ, CHATLOOM_KS_PASS=keys["storePassword"],
                   CHATLOOM_KEY_PASS=keys["keyPassword"])
        # apksigner drops the throwaway signature and writes v1-v3 with the real key.
        run([apksigner, "sign", "--ks", keys["storeFile"], "--ks-key-alias", keys["keyAlias"],
             "--ks-pass", "env:CHATLOOM_KS_PASS", "--key-pass", "env:CHATLOOM_KEY_PASS",
             "--out", str(signed), str(unsigned)], env=env)

        certs = run([apksigner, "verify", "--verbose", "--print-certs", str(signed)])
        digests = set(re.findall(r"(?m)certificate SHA-256 digest:\s*([0-9a-fA-F]{64})\s*$", certs))
        if digests != {EXPECTED_CERTIFICATE}:
            fail("the signed APK does not carry exactly the personal release certificate")
        badging = run([aapt, "dump", "badging", str(signed)])
        package = re.search(r"package: name='([^']+)'.*versionName='([^']*)'", badging)
        if not package or package.group(1) != EXPECTED_PACKAGE:
            fail("unexpected package name in the APK")

        args.out.mkdir(parents=True)
        target = args.out / "chatloom-arm64-release.apk"
        shutil.copy2(signed, target)
        digest = sha256(target)
        (args.out / "SHA256SUMS").write_text(f"{digest}  {target.name}\n")
        (args.out / "BUILD.txt").write_text(
            f"commit {commit}\nworkflow run {run_id}\nversion {package.group(2)}\n"
            f"certificate {EXPECTED_CERTIFICATE}\nsha256 {digest}\n")
    print(f"Signed {target} (commit {commit[:9]}, version {package.group(2)}, sha256 {digest[:16]}…)")


if __name__ == "__main__":
    main()
