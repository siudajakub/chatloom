# SPDX-License-Identifier: AGPL-3.0-or-later
"""Pure file/protocol tests; no Flutter, credentials, device or network calls."""
import importlib.util
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SPEC = importlib.util.spec_from_file_location("personal_release", Path(__file__).parent / "android/build.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


FIREBASE_RESOURCES = ('    resource 0x7f110060 string/gcm_defaultSenderId\n'
                      '    resource 0x7f110063 string/google_app_id\n')


class ReleaseSafetyTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.write("pubspec.yaml", "name: fixture\n")
        self.write("pubspec.lock", "packages: {}\n")

    def write(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def test_source_inventory_excludes_private_config_runtime_and_key_files(self):
        self.write("lib/production.dart", "void main() {}\n")
        for name in ("android/key.properties", "android/app/src/google-services.json",
                     "assets/credentials.json", "assets/private.pem", "assets/.env.local",
                     "assets/fcm-service-account.json", "push-gateway/credentials.json",
                     "push-gateway/operator-chosen-config.json",
                     "lib/.runtime/state.db", "worker/credentials.json", "build/candidate.apk"):
            self.write(name, "synthetic marker")
        snapshot = release.snapshot_sources(self.root)
        self.assertEqual(set(snapshot), {"pubspec.yaml", "pubspec.lock", "lib/production.dart"})

    def test_code_symlink_cannot_read_outside_the_source_roots(self):
        outside = self.write("outside.txt", "synthetic data")
        (self.root / "lib").mkdir()
        (self.root / "lib/source.dart").symlink_to(outside)
        with self.assertRaises(release.ReleaseError):
            release.snapshot_sources(self.root)

    def test_directory_symlink_is_rejected(self):
        (self.root / "outside").mkdir()
        (self.root / "lib").symlink_to(self.root / "outside", target_is_directory=True)
        with self.assertRaises(release.ReleaseError):
            release.snapshot_sources(self.root)

    def test_source_changes_additions_and_deletions_fail_closed(self):
        for after in ({"a.dart": "new"}, {}, {"a.dart": "old", "b.dart": "new"}):
            with self.subTest(after=after), self.assertRaises(release.ReleaseError):
                release.require_unchanged({"a.dart": "old"}, after)

    def test_insufficient_disk_space_blocks_release(self):
        with self.assertRaises(release.ReleaseError):
            release.require_disk_space(release.MINIMUM_FREE_BYTES - 1)
        release.require_disk_space(release.MINIMUM_FREE_BYTES)

    def test_space_budget_accounts_for_backups_candidate_and_publication(self):
        for _, relative in release.CONVENTIONAL_APKS:
            self.write(relative, "x" * 100)
        self.assertEqual(release.release_space_budget(self.root, minimum=0),
                         release.SCRATCH_HEADROOM_BYTES + 400)
        self.assertEqual(release.release_space_budget(self.root), release.MINIMUM_FREE_BYTES)

    def test_publication_with_insufficient_space_stays_unpublished(self):
        candidate = self.write("candidate.apk", "new output")
        artifacts = self.root / "artifacts"
        artifacts.mkdir()
        with patch.object(release.shutil, "disk_usage") as usage:
            usage.return_value.free = release.SCRATCH_HEADROOM_BYTES
            with self.assertRaises(release.ReleaseError):
                release.publish(candidate, {"apk_sha256": release.digest(candidate)}, artifacts, "fixture")
        self.assertFalse((artifacts / "fixture").exists())

    def test_java_and_native_toolchains_are_scoped_to_child_environment(self):
        with patch.dict(os.environ, {"JAVA_HOME": "original-jdk", "PATH": "/original"}, clear=True):
            environment = release.build_environment(Path("/fixture/project"), Path("/fixture/sdk"), Path("/fixture/jdk17"))
            self.assertEqual(environment["JAVA_HOME"], "/fixture/jdk17")
            self.assertTrue(environment["PATH"].startswith("/fixture/jdk17/bin:"))
            self.assertEqual(environment["CARGO_HOME"], "/fixture/project/spikes/toolchains/cargo")
            self.assertEqual(os.environ["JAVA_HOME"], "original-jdk")
            self.assertEqual(os.environ["PATH"], "/original")

    def test_preparation_generates_locales_before_final_release_snapshot(self):
        self.write("l10n.yaml", "arb-dir: lib/l10n\noutput-localization-file: l10n.dart\n")
        self.write("lib/l10n/intl_en.arb", "{}")
        calls = []
        def preparation(argv, *_args, **_kwargs):
            calls.append(argv[1:])
            self.write("lib/l10n/l10n.dart", "generated " + argv[1])
        with patch.object(release, "run", side_effect=preparation):
            release.prepare_generated_inputs(self.root, Path("/fixture/flutter"), {})
        final = release.snapshot_sources(self.root)
        self.assertIn("lib/l10n/l10n.dart", final)
        self.assertIn("lib/l10n/intl_en.arb", final)
        self.assertIn("l10n.yaml", final)
        self.assertEqual(calls, [["pub", "get", "--enforce-lockfile"], ["gen-l10n"]])

    def test_preparation_rejects_lockfile_drift_before_generation(self):
        with patch.object(release, "run", side_effect=lambda *_args, **_kwargs: self.write("pubspec.lock", "changed")) as runner:
            with self.assertRaises(release.ReleaseError):
                release.prepare_generated_inputs(self.root, Path("/fixture/flutter"), {})
        self.assertEqual(runner.call_count, 1)

    def test_preparation_rejects_arb_template_drift(self):
        self.write("lib/l10n/intl_en.arb", "{}")
        def preparation(argv, *_args, **_kwargs):
            if argv[1] == "gen-l10n":
                self.write("lib/l10n/intl_en.arb", "changed authored template")
        with patch.object(release, "run", side_effect=preparation), self.assertRaises(release.ReleaseError):
            release.prepare_generated_inputs(self.root, Path("/fixture/flutter"), {})

    def test_preflight_only_never_prepares_or_writes_inputs(self):
        before = sorted(str(path.relative_to(self.root)) for path in self.root.rglob("*"))
        preflight = (Path("/fixture/flutter"), Path("/fixture/apksigner"), Path("/fixture/aapt2"),
                     release.MINIMUM_FREE_BYTES, release.MINIMUM_FREE_BYTES, {})
        with patch.object(release, "ROOT", self.root), patch.object(release, "preflight", return_value=preflight), \
             patch.object(release, "prepare_generated_inputs") as preparation, \
             patch.object(release.sys, "argv", ["build-personal-release.py", "--preflight-only"]), redirect_stdout(io.StringIO()):
            release.main()
        preparation.assert_not_called()
        self.assertEqual(before, sorted(str(path.relative_to(self.root)) for path in self.root.rglob("*")))

    def test_apk_validators_receive_the_scoped_jdk_environment(self):
        apk = self.root / 'candidate.apk'
        with zipfile.ZipFile(apk, 'w') as archive:
            for name in ('AndroidManifest.xml', 'classes.dex', 'lib/arm64-v8a/libflutter.so'):
                archive.writestr(name, b'synthetic')
        environment = {'JAVA_HOME': '/fixture/jdk17', 'PATH': '/fixture/jdk17/bin'}
        with patch.object(release, 'run', side_effect=[
            'V2 Signer: certificate SHA-256 digest: ' + release.EXPECTED_CERTIFICATE,
            "package: name='pl.personal.chat' versionCode='3568' versionName='2.10.0'",
            FIREBASE_RESOURCES,
        ]) as runner:
            release.validate_apk(apk, '/fixture/apksigner', '/fixture/aapt2', self.root,
                                 environment=environment)
        self.assertEqual(len(runner.call_args_list), 3)
        for call in runner.call_args_list:
            self.assertIs(call.kwargs['environment'], environment)

    def test_apk_without_firebase_configuration_is_rejected(self):
        apk = self.root / 'no-firebase.apk'
        with zipfile.ZipFile(apk, 'w') as archive:
            for name in ('AndroidManifest.xml', 'classes.dex', 'lib/arm64-v8a/libflutter.so'):
                archive.writestr(name, b'synthetic')
        signed = ['Signer #1 certificate SHA-256 digest: ' + release.EXPECTED_CERTIFICATE,
                  "package: name='pl.personal.chat' versionCode='3568' versionName='2.10.0'"]
        without = '    resource 0x7f110001 string/abc_action_bar_up_description\n'
        with patch.object(release, 'run', side_effect=[*signed, without]), \
                self.assertRaises(release.ReleaseError) as raised:
            release.validate_apk(apk, 'apksigner', 'aapt2', self.root)
        self.assertIn('Firebase', str(raised.exception))
        with patch.object(release, 'run', side_effect=[*signed, FIREBASE_RESOURCES]):
            result = release.validate_apk(apk, 'apksigner', 'aapt2', self.root)
        self.assertTrue(result['firebase_configured'])
        self.assertFalse(release.firebase_configured('string/google_app_id_extra'))

    def test_certificate_requires_exact_personal_signer(self):
        valid = f"Signer #1 certificate SHA-256 digest: {release.EXPECTED_CERTIFICATE}\n"
        self.assertEqual(release.certificate_from_output(valid), release.EXPECTED_CERTIFICATE)
        self.assertEqual(release.certificate_from_output(valid + valid), release.EXPECTED_CERTIFICATE)
        self.assertEqual(release.certificate_from_output(valid.replace("Signer #1", "V2 Signer:")), release.EXPECTED_CERTIFICATE)
        for output in ("", valid.replace(release.EXPECTED_CERTIFICATE, "0" * 64),
                       valid + valid.replace(release.EXPECTED_CERTIFICATE, "0" * 64)):
            with self.assertRaises(release.ReleaseError):
                release.certificate_from_output(output)

    def test_package_requires_personal_application_id(self):
        output = "package: name='pl.personal.chat' versionCode='3568' versionName='2.10.0' platformBuildVersionName=''"
        self.assertEqual(release.package_from_output(output)["version_code"], "3568")
        with self.assertRaises(release.ReleaseError):
            release.package_from_output(output.replace("pl.personal.chat", "chat.fluffy.fluffychat"))

    def test_failed_build_restores_both_previous_standard_apks(self):
        paths = [self.write(path, "previous " + str(index)) for index, path in enumerate((
            "build/app/outputs/flutter-apk/app-release.apk", "build/app/outputs/apk/release/app-release.apk"))]
        run_dir = self.root / "run"
        run_dir.mkdir()
        with self.assertRaises(release.ReleaseError):
            with release.preserve_build_apks(self.root, run_dir):
                for path in paths:
                    path.write_text("new output")
                raise release.ReleaseError("synthetic source drift")
        self.assertEqual([path.read_text() for path in paths], ["previous 0", "previous 1"])

    def test_new_standard_output_is_retained_as_unpublished(self):
        run_dir = self.root / "run"
        run_dir.mkdir()
        with release.preserve_build_apks(self.root, run_dir) as output:
            output.parent.mkdir(parents=True)
            output.write_text("new output")
        self.assertFalse(output.exists())
        self.assertEqual((run_dir / "generated-flutter.apk").read_text(), "new output")

    def test_publication_does_not_overwrite_existing_artifact(self):
        candidate = self.write("candidate.apk", "new output")
        artifacts = self.root / "artifacts"
        (artifacts / "fixture").mkdir(parents=True)
        with self.assertRaises(release.ReleaseError):
            release.publish(candidate, {"apk_sha256": release.digest(candidate)}, artifacts, "fixture")
        self.assertEqual(list((artifacts / "fixture").iterdir()), [])

    def test_publication_with_wrong_hash_stays_unpublished(self):
        candidate = self.write("candidate.apk", "new output")
        artifacts = self.root / "artifacts"
        artifacts.mkdir()
        with self.assertRaises(release.ReleaseError):
            release.publish(candidate, {"apk_sha256": "0" * 64}, artifacts, "fixture")
        self.assertFalse((artifacts / "fixture").exists())

    def test_publication_contains_apk_and_manifest_together(self):
        candidate = self.write("candidate.apk", "new output")
        artifacts = self.root / "artifacts"
        artifacts.mkdir()
        manifest = {"apk_sha256": release.digest(candidate), "runtime_acceptance": "NOT RUN"}
        final = release.publish(candidate, manifest, artifacts, "fixture")
        self.assertEqual(json.loads((final / "source-manifest.json").read_text()), manifest)
        self.assertEqual((final / "personal-chat-arm64-release.apk").read_bytes(), candidate.read_bytes())

    def test_last_source_guard_prevents_artifact_publication(self):
        candidate = self.write("candidate.apk", "new output")
        artifacts = self.root / "artifacts"
        artifacts.mkdir()
        def source_changed():
            raise release.ReleaseError("synthetic source drift during copy")
        with self.assertRaises(release.ReleaseError):
            release.publish(candidate, {"apk_sha256": release.digest(candidate)}, artifacts,
                            "fixture", source_check=source_changed)
        self.assertFalse((artifacts / "fixture").exists())

    def test_atomic_publication_refuses_existing_empty_directory(self):
        pending = self.root / "pending"
        final = self.root / "final"
        pending.mkdir()
        final.mkdir()
        with self.assertRaises(release.ReleaseError):
            release.rename_directory_exclusively(pending, final)
        self.assertTrue(pending.exists())
        self.assertEqual(list(final.iterdir()), [])

    def test_apk_with_extra_flutter_abi_is_rejected(self):
        apk = self.root / "fixture.apk"
        with zipfile.ZipFile(apk, "w") as archive:
            for name in ("AndroidManifest.xml", "classes.dex", "lib/arm64-v8a/libflutter.so", "lib/x86_64/libflutter.so"):
                archive.writestr(name, b"synthetic fixture")
        results = [f"Signer #1 certificate SHA-256 digest: {release.EXPECTED_CERTIFICATE}",
                   "package: name='pl.personal.chat' versionCode='3568' versionName='2.10.0'"]
        with patch.object(release, "run", side_effect=results), self.assertRaises(release.ReleaseError):
            release.validate_apk(apk, "apksigner", "aapt2", self.root)


    def test_foreign_plugin_abi_is_rejected_even_with_arm64_flutter(self):
        for abi in ("x86", "x86_64", "armeabi-v7a"):
            with self.subTest(abi=abi):
                apk = self.root / "mixed.apk"
                with zipfile.ZipFile(apk, "w") as archive:
                    for name in ("AndroidManifest.xml", "classes.dex",
                                 "lib/arm64-v8a/libflutter.so",
                                 f"lib/{abi}/libplugin.so"):
                        archive.writestr(name, b"synthetic")
                results = [f"Signer #1 certificate SHA-256 digest: {release.EXPECTED_CERTIFICATE}",
                           "package: name='pl.personal.chat' versionCode='3568' versionName='2.10.0'"]
                with patch.object(release, "run", side_effect=results), self.assertRaises(release.ReleaseError):
                    release.validate_apk(apk, "apksigner", "aapt2", self.root)


if __name__ == "__main__":
    unittest.main()
