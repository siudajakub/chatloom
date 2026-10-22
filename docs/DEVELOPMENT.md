# Development environment

This is the generic setup for building and testing ChatLoom. Paths and hosts
are placeholders; keep your own machine names, signing material and service
credentials outside the repository.

## Toolchain

- Flutter 3.47.4 / Dart 3.13 (pinned; `pubspec.lock` is enforced). Install it
  in a directory of your choice, for example `$PERSONAL_CHAT_ROOT/spikes/toolchains/flutter-3.47.4`.
- JDK 17 and the Android SDK/NDK for Android; full Xcode for macOS builds.
- `scripts/devbox-env.sh` exports the Flutter, Android, Gradle and pub cache
  locations from `PERSONAL_CHAT_ROOT` and `PERSONAL_CHAT_RUNTIME`. Set both before
  sourcing it.

```sh
export PERSONAL_CHAT_ROOT=/path/to/project          # contains spikes/toolchains/
export PERSONAL_CHAT_RUNTIME=/path/to/runtime-cache  # SDKs, caches, build temp
source scripts/devbox-env.sh
flutter pub get --enforce-lockfile
flutter analyze lib
python3 scripts/verify-personal.py --dart "$(command -v dart)"
```

Run only one Flutter job (analyze, test, pub get, build) at a time per checkout.
`scripts/flutter-queue.py` serialises them; on a shared machine you can also wrap
heavy jobs in a lock, for example `flock -w 5400 /tmp/chatloom-heavy.lock nice -n 10 ...`.

## Build-time configuration

| Setting | How to provide it |
|---|---|
| Push gateway | `--dart-define=CHATLOOM_PUSH_GATEWAY=https://push.example.org` (origin of your `push-gateway/` deployment). No default: without it the build has no automatic push setup. |
| Firebase (Android FCM) | Your own ignored `android/app/google-services.json`. A release build without it stops unless `-Pchatloom.allowNoFirebase=true` is given. |
| Release signing | Your own ignored `android/key.properties` pointing at a keystore outside the repository (for example under `~/.local/share/personal-chat/signing/`). Back the key up privately; a lost key blocks upgrades. |
| Web crypto | `scripts/prepare-web.sh` builds the vodozemac web assets. |

Example release build:

```sh
python3 scripts/android/build.py --preflight-only
CHATLOOM_PUSH_GATEWAY=https://push.example.org python3 scripts/android/build.py
# or directly:
flutter build apk --release --target-platform android-arm64 \
  --dart-define=CHATLOOM_PUSH_GATEWAY=https://push.example.org
```

## Services

- `push-gateway/` — FCM push gateway with OpenID-verified registration; see its README.
- `worker/` — optional sync, reminders and transcription worker; see its README.
  Deploy both only to infrastructure you control, with credentials kept in
  systemd credentials or private files, never in Git.

## Tests and evidence

Unit, widget and golden tests use fictional fixtures only. They do not prove
end-to-end encryption, push delivery or native behaviour on a real account;
record those checks separately for each device and network.
