# Shared reels and iOS: upstream integration

The integration combines beta `e6f5471` with upstream `26199cd` (common base
`78e0640`). The only textual merge conflict was
`lib/pages/chat/events/instagram_share_preview.dart`.

## What differed

The beta added explicit inline playback, a Matrix-provided poster, captions
that link to the original post, full-screen playback using the same decoder,
and inbox previews that do not mark messages as read. Its Instagram widget
also implemented metadata caching and its own local media Event adapter.

Upstream moved Instagram I/O into `personal/media/instagram_media.dart`.
It shares concurrent loads, scopes them to the database/account/homeserver,
enforces access and disappearing-media policy, rejects stale results after
cache clearing, and releases completed futures. Its cache has an absolute
one-day lifetime; reopening does not renew it. Its UI opened the native viewer
instead of the beta's inline player and did not expose the caption metadata.

The competing metadata paths were effectively:

```dart
// Beta widget: read/write its own envelope, extract caption, build local assets.
response ??= await request(false, 0);
metadata = ReelMetadata.fromInstagramResponse(share, response);

// Upstream widget: use the guarded shared loader, then its shared asset adapter.
items = await loadInstagramMetadata(original: original, url: url, request: request);
```

## Resolution

There is one I/O path, using upstream's loader and `InstagramMediaAsset`.
`loadInstagramPost` preserves the full validated metadata response and asset
list together, so captions use the same guarded cache as the media metadata.
The existing `loadInstagramMetadata` API delegates to it for compatibility.
Reading captions never rewrites the cache timestamp. The widget's duplicate
cache and `_InstagramAsset` implementation have been removed.

The shared widget keeps the beta's explicit inline player, linked caption,
poster, full-screen position and album handling. It also retains upstream's
widget reset on room or client replacement. No iOS-specific reel UI or
alternate Android download implementation is introduced.

The other upstream changes, including resource budgets, read-marker fixes,
startup hydration, attachment destination and WhatsApp rich messages, are
retained by the merge.

## One application, platform runners

Use one repository and one shared Flutter application:

```text
lib/ + packages/    conversation behavior, models, media policy and UI
android/           Android runner and Android system integrations
ios/               iOS runner and Apple signing/system integrations
macos/             macOS runner and system integrations
windows/           Windows runner, when its separate port is complete
```

Platform work belongs behind capabilities/adapters, not copied feature code.
Feature branches are temporary review branches, not permanent platform forks.
The Windows/Web work in progress is not included in this integration PR.
This PR does not claim Windows readiness or complete system-feature parity:
iOS notification delivery and incoming share-extension support still require
their own native integration. Reels and inbox-preview behavior remain shared.

## Verification scope

The regression tests cover caption/permalink handling, metadata/media cache
reuse and expiry, concurrent loads, revoked access, inline playback lifecycle,
and local-history inbox previews without read receipts. They use fictional
fixtures and a fake decoder; they do not establish real-account delivery or
physical decoder behavior on every OS. Native build/device checks must be
reported separately from these tests.

On 2026-11-09, Flutter 3.47.4 on the Windows host passed 167 application-graph
tests: 38 reel/cache/preview cases and 129 encrypted-cache, hydration,
sync/read-marker, hidden/kept-message, merge, layout/golden and iOS-key cases.
The 38 reel/cache/preview cases were rerun after analyzer cleanup and passed.
Full `flutter analyze --no-pub --no-fatal-infos lib` completed with no errors
or warnings (70 informational notices). Design-token lint passed at its
existing 181-hit baseline. The compact Instagram golden is unchanged by the
integration.

The separate `verify-notion-ui.py` harness could not prepare because its
required `docs/notion-ui/SOURCE-SNAPSHOT.json` is absent. No native crypto hook
was disabled for the application-graph tests. The pre-integration release was
installed on a physical iPhone; this integrated revision has not been rerun
on physical iOS/Android hardware or built with standard Mac/Xcode.
