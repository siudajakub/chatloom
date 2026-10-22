#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Build a new personal Android release without replacing prior release artifacts.

The coordinator must finish source edits and run Flutter jobs sequentially before
using this script. It preserves both conventional APK outputs, builds with pub,
then publishes a new artifact directory only after source/signature/package checks.
No signing config, Firebase config, credential or raw build output is copied into
evidence. This is artifact validation; phone/account/bridge acceptance is NOT RUN.
"""

import argparse
from contextlib import contextmanager
import ctypes
from datetime import datetime, timezone
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[2]
EXPECTED_PACKAGE = "pl.personal.chat"
# Public certificate of the established personal release, never its private key.
EXPECTED_CERTIFICATE = "ef9a14157544adc28fa167724858e35c526cf805c11e14bcf30e4e53614867ef"
MINIMUM_FREE_BYTES = 1024 ** 3
SCRATCH_HEADROOM_BYTES = 512 * 1024 ** 2
DEFAULT_APK_BYTES = 128 * 1024 ** 2
CONVENTIONAL_APKS = (
    ("flutter", "build/app/outputs/flutter-apk/app-release.apk"),
    ("gradle", "build/app/outputs/apk/release/app-release.apk"),
)
SOURCE_FILES = (
    "pubspec.yaml", "pubspec.lock", "analysis_options.yaml", "l10n.yaml",
    "android/build.gradle.kts", "android/settings.gradle.kts",
    "android/gradle.properties", "android/gradlew", "android/gradlew.bat",
    "android/gradle/wrapper/gradle-wrapper.properties",
    "android/gradle/wrapper/gradle-wrapper.jar", "android/app/build.gradle.kts",
    "android/app/proguard-rules.pro", "packages/matrix/pubspec.yaml",
    "packages/matrix/pubspec.lock", "packages/personal_core/pubspec.yaml",
    "packages/personal_core/pubspec.lock", "worker/pubspec.yaml", "worker/pubspec.lock",
    "push-gateway/gateway.py", "push-gateway/setup.py",
    "push-gateway/prepare_credentials.py", "push-gateway/requirements.txt",
)
SOURCE_TREES = (
    "lib", "assets", "android/app/src", "packages/matrix/lib",
    "packages/matrix/hook", "packages/personal_core/lib", "scripts", "test",
    "worker/lib", "worker/bin", "worker/test", "worker/scripts", "worker/deploy",
    "push-gateway/tests", ".github/workflows",
)
EXCLUDED_NAMES = {
    "google-services.json", "key.properties", "local.properties", "keys.json",
    "credentials.json", "gateway.local.json", "config.local.json",
    "config.json", "service-account.json", "fcm-service-account.json",
    "GeneratedPluginRegistrant.java",
}
EXCLUDED_DIRS = {".git", ".dart_tool", ".runtime", "__pycache__", "build", "node_modules"}
SECRET_SUFFIXES = {".jks", ".keystore", ".pem", ".p12", ".pfx", ".key"}


class ReleaseError(RuntimeError):
    pass


def digest(path):
    with path.open("rb") as stream:
        result = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
        return result.hexdigest()


def reject_symlinks(path, root):
    """Reject existing symlinks before reading or writing a managed path."""
    path = Path(path)
    if not path.is_relative_to(root):
        raise ReleaseError("Managed path is outside its expected root")
    for candidate in (path, *path.parents):
        if candidate.is_symlink():
            raise ReleaseError("Refusing a symlink in a managed source/output path")
        if candidate == root:
            break


def excluded(path):
    return (any(part in EXCLUDED_DIRS for part in path.parts)
            or path.name in EXCLUDED_NAMES or path.name.startswith(".env")
            or (path.suffix.lower() == ".json" and any(
                word in path.name.lower() for word in ("credential", "token", "service-account", "firebase-adminsdk")))
            or path.suffix.lower() in SECRET_SUFFIXES)


def snapshot_sources(root, include_generated=True):
    """Hash the explicit application source roots; never traverse runtime/config roots."""
    result = {}
    candidates = [root / name for name in SOURCE_FILES]
    for name in SOURCE_TREES:
        tree = root / name
        reject_symlinks(tree, root)
        if not tree.exists():
            continue
        for base, directories, files in os.walk(tree, followlinks=False):
            for directory in list(directories):
                child = Path(base) / directory
                if excluded(child.relative_to(root)):
                    directories.remove(directory)
                else:
                    reject_symlinks(child, root)
            candidates.extend(Path(base) / filename for filename in files)
    for path in sorted(set(candidates)):
        relative = path.relative_to(root)
        if excluded(relative):
            continue
        # l10n.yaml and every .arb remain authored protected inputs. These exact
        # ignored outputs may be created/replaced by normal pub/gen-l10n before
        # the final release snapshot; that snapshot includes their generated bytes.
        if not include_generated and relative.parent.as_posix() == "lib/l10n" and relative.suffix == ".dart":
            continue
        reject_symlinks(path, root)
        if path.is_file():
            result[relative.as_posix()] = digest(path)
    if "pubspec.yaml" not in result or "pubspec.lock" not in result:
        raise ReleaseError("Application manifest or lockfile is missing")
    return result


def prepare_generated_inputs(root, flutter, environment):
    authored = snapshot_sources(root, include_generated=False)
    run([flutter, "pub", "get", "--enforce-lockfile"], root, environment=environment)
    require_unchanged(authored, snapshot_sources(root, include_generated=False))
    run([flutter, "gen-l10n"], root, environment=environment)
    require_unchanged(authored, snapshot_sources(root, include_generated=False))


def require_unchanged(before, after):
    changed = sorted(name for name in before.keys() | after.keys()
                     if before.get(name) != after.get(name))
    if changed:
        raise ReleaseError("Source changed during release; no artifact published: "
                           + ", ".join(changed[:12]))


def run(argv, cwd, capture=False, environment=None):
    # Build diagnostics can contain private local config. Never persist/print them.
    completed = subprocess.run(
        ["rtk", *map(str, argv)], cwd=cwd,
        stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
        stderr=subprocess.DEVNULL, text=True, check=False, env=environment,
    )
    if completed.returncode:
        raise ReleaseError(f"{Path(str(argv[0])).name} stage failed (exit {completed.returncode}); "
                           "raw private diagnostics were not recorded")
    return completed.stdout if capture else ""


def certificate_from_output(output):
    # SDK 37 labels scheme-specific output "V2 Signer:"; earlier SDKs use
    # "Signer #1". The same pinned signer can be reported by several schemes.
    certificates = {value.lower() for value in re.findall(
        r"(?m)^[^\r\n]*certificate SHA-256 digest:\s*([0-9a-fA-F]{64})\s*$", output)}
    if certificates != {EXPECTED_CERTIFICATE}:
        raise ReleaseError("APK signing certificate differs from the established personal release")
    return EXPECTED_CERTIFICATE


def package_from_output(output):
    match = re.search(r"^package: name='([^']+)' versionCode='([^']+)' versionName='([^']*)'", output, re.M)
    if not match or match.group(1) != EXPECTED_PACKAGE:
        raise ReleaseError("APK package differs from pl.personal.chat")
    return {"name": match.group(1), "version_code": match.group(2), "version_name": match.group(3)}


def validate_apk(apk, apksigner, aapt, root, environment=None):
    signing = run([apksigner, "verify", "--verbose", "--print-certs", apk], root, capture=True, environment=environment)
    certificate = certificate_from_output(signing)
    package = package_from_output(run([aapt, "dump", "badging", apk], root, capture=True, environment=environment))
    with zipfile.ZipFile(apk) as archive:
        names = set(archive.namelist())
        abis = sorted(name.split("/")[1] for name in names
                      if re.fullmatch(r"lib/[^/]+/libflutter\.so", name))
        native_abis = sorted({name.split("/")[1] for name in names
                              if re.fullmatch(r"lib/[^/]+/[^/]+\.so", name)})
        if ("AndroidManifest.xml" not in names or "classes.dex" not in names
                or abis != ["arm64-v8a"] or native_abis != ["arm64-v8a"]):
            raise ReleaseError("APK is missing Android inputs or its Flutter ABI is not arm64-v8a")
    # Without the Google services resources FCM never issues a token: the APK
    # works but push notifications silently never register (2026-10-21).
    resources = run([aapt, "dump", "resources", apk], root, capture=True, environment=environment)
    if not firebase_configured(resources):
        raise ReleaseError("APK has no Firebase configuration (google_app_id); push would not work")
    return {"certificate_sha256": certificate, "package": package,
            "flutter_lib_abis": abis, "native_lib_abis": native_abis,
            "firebase_configured": True}


def firebase_configured(resources_dump):
    """Whether `aapt2 dump resources` lists the google-services string resources."""
    return all(re.search(rf"\bstring/{name}\b", resources_dump)
               for name in ("google_app_id", "gcm_defaultSenderId"))


@contextmanager
def preserve_build_apks(root, run_dir):
    """Retain the old standard output even when Flutter fails or sources drift."""
    states = []
    for label, relative in CONVENTIONAL_APKS:
        path = root / relative
        reject_symlinks(path, root)
        backup = run_dir / f"previous-{label}.apk"
        state = (label, path, backup, path.is_file(), None)
        if path.exists() and not path.is_file():
            raise ReleaseError("Conventional APK output is not a regular file")
        if path.is_file():
            mode = path.stat().st_mode & 0o777
            expected = digest(path)
            require_disk_space(shutil.disk_usage(run_dir).free,
                               SCRATCH_HEADROOM_BYTES + path.stat().st_size)
            shutil.copy2(path, backup)
            os.chmod(backup, 0o600)
            if digest(backup) != expected:
                raise ReleaseError("Prior APK changed while being preserved; build was not started")
            state = (label, path, backup, True, mode)
        states.append(state)
    try:
        yield root / "build/app/outputs/flutter-apk/app-release.apk"
    finally:
        for label, path, backup, existed, mode in states:
            reject_symlinks(path, root)
            if existed:
                os.chmod(backup, mode)
                os.replace(backup, path)
            elif path.is_file():
                # This output was generated by this run; retain it as unpublished evidence.
                os.replace(path, run_dir / f"generated-{label}.apk")


def rename_directory_exclusively(pending, final):
    """Atomic publication with kernel-enforced refusal to replace any destination."""
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        operation = libc.renamex_np
        operation.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
        result = operation(os.fsencode(pending), os.fsencode(final), 0x00000004)  # RENAME_EXCL
    elif sys.platform.startswith("linux") and hasattr(libc, "renameat2"):
        operation = libc.renameat2
        operation.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
        result = operation(-100, os.fsencode(pending), -100, os.fsencode(final), 1)  # AT_FDCWD, RENAME_NOREPLACE
    else:
        raise ReleaseError("Atomic no-overwrite publication is unavailable on this platform")
    if result:
        if ctypes.get_errno() in (errno.EEXIST, errno.ENOTEMPTY):
            raise ReleaseError("Artifact destination appeared during publication; nothing was overwritten")
        raise ReleaseError("Atomic artifact publication failed; directory remains unpublished")


def publish(candidate, manifest, artifacts, label, source_check=None):
    """The manifest and APK become visible together in a new directory."""
    final = artifacts / label
    pending = artifacts / (".pending-" + label)
    reject_symlinks(final, artifacts)
    reject_symlinks(pending, artifacts)
    if final.exists() or pending.exists():
        raise ReleaseError("Artifact destination already exists; nothing was overwritten")
    require_disk_space(shutil.disk_usage(artifacts).free,
                       SCRATCH_HEADROOM_BYTES + candidate.stat().st_size)
    pending.mkdir(mode=0o700)
    target = pending / "personal-chat-arm64-release.apk"
    shutil.copy2(candidate, target)
    if digest(target) != manifest["apk_sha256"]:
        raise ReleaseError("APK changed during publication; artifact remains unpublished")
    (pending / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    if source_check is not None:
        source_check()
    require_disk_space(shutil.disk_usage(artifacts).free, SCRATCH_HEADROOM_BYTES)
    rename_directory_exclusively(pending, final)
    return final


def require_disk_space(free, required=MINIMUM_FREE_BYTES):
    if free < required:
        raise ReleaseError(f"Insufficient local disk space: {free} bytes free; "
                           f"this stage requires at least {required} bytes")


def release_space_budget(root, minimum=MINIMUM_FREE_BYTES):
    sizes = []
    for _, relative in CONVENTIONAL_APKS:
        path = root / relative
        reject_symlinks(path, root)
        if path.is_file():
            sizes.append(path.stat().st_size)
    expected_apk = max(sizes, default=DEFAULT_APK_BYTES)
    # Old standard outputs are backed up; candidate and published copies both
    # coexist briefly. Native build scratch is an estimate for warm local caches.
    return max(minimum, SCRATCH_HEADROOM_BYTES + sum(sizes) + 2 * expected_apk)


def build_environment(project, sdk, jdk):
    environment = os.environ.copy()
    toolchains = project / "spikes/toolchains"
    environment["JAVA_HOME"] = str(jdk)
    environment["CARGO_HOME"] = str(toolchains / "cargo")
    environment["RUSTUP_HOME"] = str(toolchains / "rustup")
    environment["ANDROID_HOME"] = str(sdk)
    environment["ANDROID_SDK_ROOT"] = str(sdk)
    # The venv launcher can retain a pre-relocation Python shebang. Use the
    # bundled native CMake executable without changing the user's toolchain.
    cmake_bins = sorted((toolchains / "native-tools/lib").glob(
        "python*/site-packages/cmake/data/bin"))
    cmake_path = [str(path) for path in cmake_bins if (path / "cmake").is_file()]
    environment["PATH"] = os.pathsep.join([
        str(jdk / "bin"), str(toolchains / "cargo/bin"),
        *cmake_path,
        str(toolchains / "native-tools/bin"), environment.get("PATH", "/usr/bin:/bin"),
    ])
    return environment


def preflight(root, sdk, minimum=MINIMUM_FREE_BYTES):
    project = root.parent
    if root.name != "client" or not (project / "AGENTS.md").is_file():
        raise ReleaseError("This release wrapper requires the canonical project client checkout")
    flutter = project / "spikes/toolchains/flutter-3.47.4/bin/flutter"
    reject_symlinks(root / "build", root)
    reject_symlinks(project / "artifacts", project)
    if not flutter.is_file() or not os.access(flutter, os.X_OK) or not shutil.which("rtk"):
        raise ReleaseError("Isolated Flutter 3.47.4 or rtk is unavailable")
    jdk = Path("/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home")
    if not (jdk / "bin/java").is_file() or not os.access(jdk / "bin/java", os.X_OK):
        raise ReleaseError("The scoped OpenJDK 17 toolchain is unavailable")
    for relative in ("android/key.properties", "android/app/google-services.json"):
        if not (root / relative).is_file():
            raise ReleaseError("Canonical signing/Firebase build configuration is absent")
        if (root / relative).stat().st_mode & 0o077:
            raise ReleaseError("Private signing/Firebase configuration must be owner-only")
        run(["git", "check-ignore", "-q", relative], root)
    tools = sorted((sdk / "build-tools").glob("*/apksigner"),
                   key=lambda path: tuple(int(piece) for piece in re.findall(r"\d+", path.parent.name)), reverse=True)
    pair = next(((path, path.with_name("aapt2")) for path in tools
                 if os.access(path, os.X_OK) and os.access(path.with_name("aapt2"), os.X_OK)), None)
    if pair is None:
        raise ReleaseError("Android apksigner and aapt2 are unavailable in the selected SDK")
    free = shutil.disk_usage(root).free
    required = release_space_budget(root, minimum)
    require_disk_space(free, required)
    return flutter, pair[0], pair[1], free, required, build_environment(project, sdk, jdk)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--android-sdk", type=Path,
                        default=Path(os.environ.get("ANDROID_SDK_ROOT", os.environ.get(
                            "ANDROID_HOME", "/opt/homebrew/share/android-commandlinetools"))))
    parser.add_argument("--preflight-only", action="store_true", help="Check inputs without a build or file writes")
    parser.add_argument("--min-free-mib", type=int, default=1024,
                        help="Initial free-space floor (default 1024); raise for cold native builds. Calculated copy/scratch budget always applies.")
    args = parser.parse_args()
    if args.min_free_mib < 0:
        parser.error("--min-free-mib must be nonnegative")
    flutter, signer, aapt, free, required, environment = preflight(ROOT, args.android_sdk, args.min_free_mib * 1024 ** 2)
    if args.preflight_only:
        before = snapshot_sources(ROOT)
        print(f"PASS release preflight; {len(before)} source files; {free} bytes free; "
              f"{required} byte warm-cache budget; build/runtime NOT RUN")
        return
    baseline = run(["git", "rev-parse", "HEAD"], ROOT, capture=True).strip()
    if not re.fullmatch(r"[0-9a-f]{40}", baseline):
        raise ReleaseError("Canonical Git baseline could not be established")
    label = "personal-chat-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
    build_root = ROOT / "build/personal-release"
    reject_symlinks(build_root, ROOT)
    build_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock_path = build_root / ".release.lock"
    reject_symlinks(lock_path, ROOT)
    with lock_path.open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ReleaseError("Another personal release wrapper is running") from error
        run_dir = build_root / label
        run_dir.mkdir(mode=0o700)
        print("Preparing locked dependencies and generated locales; keep Flutter jobs/source edits sequential.", flush=True)
        prepare_generated_inputs(ROOT, flutter, environment)
        before = snapshot_sources(ROOT)
        (run_dir / "source-before.json").write_text(json.dumps(before, indent=2) + "\n")
        candidate = run_dir / "candidate.apk"
        print("Building with pub; keep all Flutter jobs and source edits sequential.", flush=True)
        with preserve_build_apks(ROOT, run_dir) as output:
            # Push gateway origin (lib/personal/automatic_push.dart); no default.
            gateway = os.environ.get("CHATLOOM_PUSH_GATEWAY", "").strip()
            defines = [f"--dart-define=CHATLOOM_PUSH_GATEWAY={gateway}"] if gateway else []
            run([flutter, "build", "apk", "--release", "--target-platform", "android-arm64", *defines], ROOT, environment=environment)
            require_unchanged(before, snapshot_sources(ROOT))
            if not output.is_file() or output.is_symlink():
                raise ReleaseError("Expected freshly built APK is unavailable")
            require_disk_space(shutil.disk_usage(run_dir).free,
                               SCRATCH_HEADROOM_BYTES + 2 * output.stat().st_size)
            shutil.copy2(output, candidate)
            os.chmod(candidate, 0o600)
        validation = validate_apk(candidate, signer, aapt, ROOT, environment=environment)
        after = snapshot_sources(ROOT)
        require_unchanged(before, after)
        manifest = {
            "schema": 1, "created_at": datetime.now(timezone.utc).isoformat(),
            "source_scope": "Explicit code/assets/native source roots; private configuration and runtime excluded",
            "baseline_commit": baseline,
            "source_state": "Local tracked and untracked source hashes; no commit or deployment claim",
            "source_before": before, "source_after": after,
            "source_check": "Equal at before-build, after-build and before-publication checkpoints; not an atomic snapshot",
            "apk_sha256": digest(candidate), "apk_bytes": candidate.stat().st_size,
            "flutter_toolchain": "isolated Flutter 3.47.4", "pub_enabled": True,
            "preparation": ["pub get --enforce-lockfile", "gen-l10n"],
            "runtime_acceptance": "NOT RUN", **validation,
        }
        artifacts = ROOT.parent / "artifacts"
        artifacts.mkdir(exist_ok=True)
        require_unchanged(before, snapshot_sources(ROOT))
        artifact = publish(candidate, manifest, artifacts, label,
                           source_check=lambda: require_unchanged(before, snapshot_sources(ROOT)))
        print(f"PASS validated signed artifact: {artifact}; phone/account/bridge runtime NOT RUN")


if __name__ == "__main__":
    try:
        main()
    except (ReleaseError, OSError, zipfile.BadZipFile) as error:
        # OSError paths can identify local private config; keep the public failure generic.
        print(str(error) if isinstance(error, ReleaseError) else "Release file operation failed; no runtime claim", file=sys.stderr)
        sys.exit(1)
