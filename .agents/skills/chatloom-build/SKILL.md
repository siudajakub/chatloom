---
name: chatloom-build
description: Build or retrieve a ChatLoom Android arm64 APK or Apple Silicon macOS DMG and provide install commands. Use for “zrób build na Maca”, “APK na telefon”, “pobierz i zainstaluj”, release build, or download an existing ChatLoom build.
---

# Build and deliver ChatLoom

Work from the client checkout. Resolve the requested revision and platforms first. For a download request, find an existing successful run for that revision. When a new hosted build is requested, use a published ref containing the requested code. Commit or publish local edits only when the user asked for those actions. The public checkout uses `siudajakub/chatloom`; pass the repository explicitly to GitHub CLI.

## Dispatch and identify the build

Run the matching command for each requested platform, substituting the requested published ref when it differs from main.

```sh
gh workflow run personal-android-release.yml -R siudajakub/chatloom --ref main
gh workflow run personal-macos.yml -R siudajakub/chatloom --ref main
```

Capture the new run ID from the dispatch response when available. Otherwise use `gh run list` with the workflow, dispatch event, commit and dispatch time to identify it. Verify `headSha` for each ID. Wait for each run to complete and inspect the failed step before retrying. A push starts separate synthetic checks.

## Android

The CI artifact contains an encrypted APK with a temporary signature. Use the configured signing host to produce the installable APK. On Linux, load the project and runtime paths before sourcing `scripts/devbox-env.sh`, as described in `docs/DEVELOPMENT.md`. Use the run ID and a fresh private artifact directory on the project volume.

```sh
python3 scripts/android/sign-ci-apk.py --run-id "$ANDROID_RUN" --out "$APK_DIR"
(cd "$APK_DIR" && sha256sum -c SHA256SUMS)
```

The signer checks the package and release certificate. Match the commit and run in `BUILD.txt` to the intended revision and workflow. To deliver, give the exact `scp` command for the signed APK using the configured host alias and verified path. On the receiving machine use `adb devices -l`, then `adb -s SERIAL install -r ~/Downloads/chatloom-arm64-release.apk` once per intended phone. Preserve app data and existing keys when troubleshooting an update.

## macOS

Download into a fresh directory on the project volume. Use the full commit SHA in the artifact name.

```sh
gh run download "$MAC_RUN" -R siudajakub/chatloom -n "ChatLoom-macos-ARM64-$SHA" -D "$MAC_DIR"
(cd "$MAC_DIR" && shasum -a 256 -c SHA256SUMS)
```

Read `manifest.json` to confirm revision, architecture, signing identity, notarization and the native smoke result. Provide a download command for the verified DMG and `open` with its actual filename. Quit the previous app before replacing ChatLoom in Applications. Report install and live-account acceptance only when actually performed.
