#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
task_dart="${DART:-dart}"
task_cargo="${CARGO:-cargo}"
task_native_checkout="$(pwd)/.runtime/dart-vodozemac"
task_native_pin=1902d5ded6a3d8c2fc120168f0e08d60d71f58b5
mkdir -p .runtime
if [[ ! -d "$task_native_checkout/.git" ]]; then
  git clone --depth 1 --branch 0.8.0 https://github.com/famedly/dart-vodozemac.git "$task_native_checkout"
fi
test "$(git -C "$task_native_checkout" rev-parse HEAD)" = "$task_native_pin"
"$task_cargo" build --locked --release --manifest-path "$task_native_checkout/rust/Cargo.toml"
"$task_dart" pub get --enforce-lockfile
"$task_dart" build cli --target bin/worker.dart --output build/native
"$task_dart" build cli --target bin/migrate.dart --output build/migration
case "$(uname -s)" in
  Linux) task_native_lib=libvodozemac_bindings_dart.so ;;
  Darwin) task_native_lib=libvodozemac_bindings_dart.dylib ;;
  *) echo 'Unsupported platform' >&2; exit 1 ;;
esac
cp "$task_native_checkout/rust/target/release/$task_native_lib" build/native/bundle/lib/
printf '%s\n' 'Bundle built. No account enrolled and no service installed.'
