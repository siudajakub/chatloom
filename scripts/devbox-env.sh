# SPDX-License-Identifier: AGPL-3.0-or-later
# Source this file before Flutter, Dart or Gradle commands on a Linux dev box.
# Set PERSONAL_CHAT_ROOT (project with spikes/toolchains/) and
# PERSONAL_CHAT_RUNTIME (SDKs, caches and build temp) first; see docs/DEVELOPMENT.md.
if [ -z "${PERSONAL_CHAT_ROOT:-}" ] || [ -z "${PERSONAL_CHAT_RUNTIME:-}" ]; then
  printf '%s\n' 'Set PERSONAL_CHAT_ROOT and PERSONAL_CHAT_RUNTIME first.' >&2
  return 1
fi
export PUB_CACHE="$PERSONAL_CHAT_RUNTIME/pub-cache"
export GRADLE_USER_HOME="$PERSONAL_CHAT_RUNTIME/gradle"
export ANDROID_HOME="${ANDROID_HOME:-$PERSONAL_CHAT_RUNTIME/android}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_USER_HOME="$PERSONAL_CHAT_RUNTIME/android-home"
export CARGO_HOME="${CARGO_HOME:-$PERSONAL_CHAT_RUNTIME/cargo}"
export CARGO_TARGET_DIR="$PERSONAL_CHAT_RUNTIME/cargo-target"
export XDG_CACHE_HOME="$PERSONAL_CHAT_RUNTIME/cache"
export TMPDIR="$PERSONAL_CHAT_RUNTIME/tmp"
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-2}"
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
export FLUTTER_SUPPRESS_ANALYTICS=true
export PLAYWRIGHT_BROWSERS_PATH="$PERSONAL_CHAT_RUNTIME/browsers"
for personal_chat_browser in "$PLAYWRIGHT_BROWSERS_PATH"/chromium-*/chrome-linux*/chrome; do
  if [ -x "$personal_chat_browser" ]; then
    export CHROME_EXECUTABLE="$personal_chat_browser"
    break
  fi
done
unset personal_chat_browser
export PATH="$PERSONAL_CHAT_ROOT/spikes/toolchains/flutter-3.47.4/bin:$CARGO_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
