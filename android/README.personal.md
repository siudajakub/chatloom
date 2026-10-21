# ChatLoom — Android

This is the native Android project of the shared Flutter application on `main`.
Application screens and domain/storage logic live in `../lib/` and `../packages/`.
Android Kotlin code, manifest, Gradle configuration and permissions stay here.

From the Flutter project root, after selecting the isolated toolchain:

```sh
rtk python3 scripts/android/build.py --preflight-only
rtk python3 scripts/android/build.py
```

On the Linux devbox, source `scripts/devbox-env.sh` first and serialize heavy
commands with `scripts/flutter-queue.py`. Release signing needs the existing
private configuration on the owner's Mac. Do not copy signing keys into Git or
generate replacement keys. The wrapper preserves existing APKs and checks the
package, signer and architecture before publishing a new artifact directory.
It does not install the app or deploy a service.

`personal-checks.yml` runs account-free shared tests and an Android debug compile
from `main`; that CI build does not use the private release key. Push/Firebase
setup is described in [the shared client guide](../README.personal.md#konfiguracja-push).

The old `scripts/build-personal-release.py` command delegates to the same builder.
Native macOS files and tools are in `../macos/` and `../scripts/macos/`.
