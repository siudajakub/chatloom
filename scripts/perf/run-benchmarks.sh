#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Frame-timing benchmark on a real device, in profile mode, with fictional
# fixtures only (no account, no network, no real storage).
#
#   scripts/perf/run-benchmarks.sh android [adb-serial]
#   scripts/perf/run-benchmarks.sh macos
#
# FLUTTER selects the toolchain (default: flutter on PATH). Results:
# build/perf/chatloom_smoothness.json and PERSONAL_BENCH lines in the output.
#
# Android: builds a separate app, pl.personal.chat.perf, and refuses to
# continue unless the APK really has that id. `flutter drive` uninstalls an
# installed app whose signature differs, so running it against the real
# pl.personal.chat would delete ChatLoom's data, keys and history.
set -euo pipefail
cd "$(dirname "$0")/../.."

platform=${1:?usage: run-benchmarks.sh android [serial] | macos}
flutter=${FLUTTER:-flutter}
target=integration_test/perf/smoothness_test.dart
driver=test_driver/perf_driver.dart

case "$platform" in
  android)
    export ORG_GRADLE_PROJECT_chatloomPerfBenchmark=true
    device=${2:-$(adb devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')}
    [ -n "$device" ] || { echo "No Android device connected." >&2; exit 1; }
    "$flutter" build apk --profile --target="$target"
    apk=build/app/outputs/flutter-apk/app-profile.apk
    sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
    aapt2=$(ls "$sdk"/build-tools/*/aapt2 2>/dev/null | sort -V | tail -1 || true)
    [ -x "$aapt2" ] || { echo "aapt2 not found under ANDROID_HOME." >&2; exit 1; }
    package=$("$aapt2" dump packagename "$apk")
    if [ "$package" != "pl.personal.chat.perf" ]; then
      echo "Refusing to install $package: the benchmark must not replace ChatLoom." >&2
      exit 1
    fi
    "$flutter" drive --profile -d "$device" --use-application-binary="$apk" \
      --driver="$driver" --target="$target"
    ;;
  macos)
    # A separate .app under build/; quit ChatLoom first (same bundle id).
    # The fixtures never open the Keychain or the app's databases.
    "$flutter" drive --profile -d macos --driver="$driver" --target="$target"
    ;;
  *)
    echo "usage: run-benchmarks.sh android [serial] | macos" >&2
    exit 2
    ;;
esac
