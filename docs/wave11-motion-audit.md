# Wave 11 motion audit (2026-10-27)

Scope: the paths a user hits daily, read in code (no device). Most of the app
already runs on the Notion motion primitives (waves 5–10: page transitions,
predictive back, message arrival, reply preview, typing row, jump buttons,
delivery ticks, inbox badges and rows, skeletons, delayed loaders, dialogs,
popovers, sheets, media viewer, lock screen, startup). This table lists only
what was still wrong or worth noting. Priority: H = daily and visibly janky,
M = visible hard cut, L = rare or cosmetic.

| Place | Current behaviour | Problem | Fix | Prio | Status |
|---|---|---|---|---|---|
| Inbox row swipe (`NotionSwipeAction`) | builder returned the bare row at offset 0 and a `Stack` otherwise | the element tree changed shape on every swipe start and end, so the whole row (avatar image, press/highlight state) remounted twice per swipe: a flicker at the moment the finger starts moving | one tree shape at rest and in motion (`Stack(passthrough)` + `Transform.translate`, empty background slot at rest) | H | fixed |
| Inbox swipe → Archive / Unarchive | row springs back to rest, then vanishes when the list drops it; rows below jump up | Telegram/iOS carry the row off and close the gap | `NotionSwipeActionSide(dismisses:)`: fly off (snappy spring, keeps release velocity), close the slot (`short`), then commit; comes back after a 700 ms controller hold if the row is still there (refused action). Only in views the chat really leaves | H | fixed |
| Conversation search open/close (composer ↔ search bar) | `Offstage` + `if (searching) bar` | hard cut in the bottom bar | `NotionReappear(trigger: searching)`: the incoming state rises and fades in; the composer stays mounted | M | fixed |
| Conversation search results overlay | `if (searching) Positioned.fill(results)` | the results list vanished with the search instead of using its own fade-out | always mounted behind `IgnorePointer`; its `NotionFadeThrough` plays the close | M | fixed (chat + merged chat) |
| Voice recorder ↔ composer | recorder rose in (`NotionEntrance`), composer came back with a hard cut | asymmetric, the composer popped | both branches return one `NotionReappear(trigger: recording)` | M | fixed |
| Inbox "Unread"/"Requests" chip counts | plain `Text` | numbers jumped; a new unread badge cut in | `NotionAnimatedCount` rolls, `NotionPop` pulses on change and pops in after the first frame (first screen stays calm) | M | fixed |
| Network wizard (Add network) | `body` switched by phase; "Advanced" fallback and field errors via `if` | hard cuts and height jumps between loading → options → step → done | `NotionAnimatedSize` + `NotionFadeThrough` keyed by phase and step id; `NotionSizeReveal` for fallback and field error | M | fixed |
| Sending-account picker (`showMenu`) | Material default menu motion | not the Notion menu timing | `popUpAnimationStyle: NotionMotion.menuStyleOf(context)` | L | fixed |
| Drop-files hint over a chat (desktop) | `if (dragging) Container` | hard cut | `NotionFadeThrough`, `IgnorePointer` | L | fixed |
| App bar bottom (undecryptable hint, thread bar) | `if` inside a `PreferredSize` | hard cut, height jump of the header | would need an animated `preferredSize` (relayout of the whole scaffold per frame); rare states | L | left |
| Snackbars (134 call sites) | Material 3 floating snackbar: 250 ms height wipe + late fade; exit collapses at the end | Material timing, not Notion; but consistent and swipe-dismissable | a Notion toast would mean replacing every call site; not worth the churn now | L | left |
| Inbox chip selection tint | switches at once | could tween | chips are pills drawn by `NotionGlassPill` (glass in other places): no tint tween on glass surfaces | L | left (house rule) |
| Undo after archive | the row comes back with a hard cut | could grow in | needs list-level insert detection; the row already flashes via `NotionRowHighlight` where wired | L | left |
| Composer ↔ keyboard ↔ sticker/emoji panel | `ComposerPanelSlot` already keyboard-synced (`composer_panel.dart`) | — | stickers lane owns the file | — | not touched |
| Message menu, reaction bar, emoji picker | — | — | emoji lane owns the files | — | not touched |

Already good (checked, no change): page push/pop and predictive back,
message arrival (`ConversationMessageEntrance`), jump-to-bottom / mention /
first-unread pills, date chip and unread divider, typing row, seen-by
avatars, reply/edit preview (`ReplyDisplay`), composer tray and `+` rotation,
field growth (`AnimatedSize` quick), send button morph and pop, inbox rows
(lazy switchers, highlight, badges), skeleton → list fade, empty states,
lock screen (entrance, shake, delayed spinner), startup fade-through,
dialogs/popovers/sheets, media viewer (hero, drag-dismiss, zoom), voice
bubble loading morph, chat details tabs, delayed progress lines.

Needs a device check (Pixel): swipe start (no flicker), archive fly-off and
gap close while the list re-sorts, search bar ↔ composer with the keyboard
open, recorder → composer after a locked recording.
