# ChatLoom screenshots

Generated 21 October 2026 from hashed production presentation sources using
`test/notion/capture_production_test.dart` in the isolated presentation harness.
All contacts, messages and counts are fictional. Avatars use initials; no account,
credentials or private media were loaded. PNGs are 780 × 1688 (390 × 844 at 2×).

The Flutter test renderer uses the opaque glass fallback. These fixtures show
presentation states; they do not establish native blur, live voice playback,
transport, encryption, notification delivery or device acceptance. The conversation
fixture uses its own voice preview; full runtime media controls have separate tests.

Reproduce from the client directory on the devbox, one Flutter job at a time:

```sh
source scripts/devbox-env.sh
rtk python3 scripts/flutter-queue.py run -- python3 scripts/verify-notion-ui.py --prepare-only
rtk python3 scripts/flutter-queue.py run --cwd build/notion_widget_harness -- rtk "$PERSONAL_CHAT_ROOT/spikes/toolchains/flutter-3.47.4/bin/flutter" pub get --offline
export NOTION_CAPTURE_DIR="$PWD/build/readme-captures"
rtk python3 scripts/flutter-queue.py run --cwd build/notion_widget_harness -- rtk "$PERSONAL_CHAT_ROOT/spikes/toolchains/flutter-3.47.4/bin/flutter" test --no-pub --concurrency=1 test/notion/capture_production_test.dart
```

Keep `NOTION_APPROVED_PHOTOS` unset for these initials-only previews. Copy the
`inbox-390`, `conversation-390` and `settings-390` PNGs to the corresponding
README filenames after inspecting them. `manifest.json` records PNG hashes;
`SOURCE-MANIFEST.json` records the exact input hashes and dependency pins.
Existing visual-regression baselines are unchanged by this capture run.
