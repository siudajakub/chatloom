# ChatLoom — macOS

This is the native macOS project of the shared Flutter application on `main`.
Swift window/menu/capture code, Xcode configuration, permissions and entitlements
stay here. Shared screens and domain/storage logic live in `../lib/` and
`../packages/`; build helpers live in `../scripts/macos/`.

From the Flutter project root on a Mac with the isolated Flutter SDK and full Xcode:

```sh
rtk python3 scripts/macos/build.py --smoke-test
rtk python3 scripts/macos/build.py
```

`personal-macos.yml` builds Apple Silicon (arm64) only; Intel Macs are not
supported. It checks native storage/crypto/media, signatures and embedded
architectures.
Linux can run shared tests and trigger Actions; it cannot compile this target.

System notifications, push, notification sounds and Dock badges are disabled.
Voice and video calls are not supported. Artifacts are ad-hoc signed and
not Apple notarized. Real-account and physical-device acceptance is separate.

[Full macOS behavior, artifacts, storage and acceptance guide](../docs/macos-client.md).
The old `scripts/build-personal-macos.py` command delegates to the same builder.
